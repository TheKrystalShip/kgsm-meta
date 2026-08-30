#!/usr/bin/env bash
#
# aggregate.sh — fold what every project has published into the pacman repository nodes install from.
#
#   ci/aggregate.sh              # collect the delta, rebuild, upload if anything moved
#   ci/aggregate.sh --dry-run    # work out what would change, download and upload nothing
#   ci/aggregate.sh --rebuild    # rebuild the database from every package rather than the delta
#
# Run by .github/workflows/aggregate.yml on a dispatch from a sibling's release, on a schedule, and
# by hand. Nothing here is specific to a runner: given `gh` credentials and the packaging key's
# secret half it does the same thing from a workstation.
#
# ---------------------------------------------------------------------------------------------
#
# What the fleet is served is decided from FILE NAMES first and bytes only afterwards. An Arch
# package file is `<name>-<pkgver>-<pkgrel>-<arch>.pkg.tar.zst`, so listing the assets on the `repo`
# tag and on each sibling's newest release is enough to know which version of every package should
# be in the database — without fetching a single one of them. That matters because the schedule runs
# this every fifteen minutes whether or not anything happened, and the full set is well over a
# gigabyte: a run with no work must cost a dozen API calls, not a download.
#
# Three sources feed that decision, in order:
#
#   1. the `repo` tag's current assets, which is what carries a package no per-repo release
#      supersedes — libdave is built by hand and published from where it sits, and has no release
#      of its own to collect from
#   2. the newest release of every sibling, across each of its tag families
#   3. nothing else. No package is built here.
#
# The database is then updated by DELTA: the served `kgsm.db` is the base, and `repo-add` is given
# only the packages whose version it does not already name. The outcome is identical to a rebuild —
# an entry is derived from its package file alone, so an entry that is already right is already
# right — while the download is the one package that moved rather than all of them. `--rebuild`
# takes the long way when the served database is not to be trusted.
#
# Superseded package files stay in the release deliberately: pacman only ever fetches what the
# database names, and the older assets are the rollback path.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

META_REPO="TheKrystalShip/kgsm-meta"
META_TAG="repo"
DB_NAME="kgsm"
RELEASE_URL="https://github.com/${META_REPO}/releases/download/${META_TAG}"
SIGN_KEY="${KGSM_PACKAGING_KEY:-B7624435FAC1A8280B280CFBA6FBDB3B724DED1B}"

log()  { printf '\033[1;34m>> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m** %s\033[0m\n' "$*" >&2; }
err()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; }

DRY_RUN=0
REBUILD=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        --rebuild) REBUILD=1 ;;
        *)         err "unknown option: $a"; exit 1 ;;
    esac
done

# Every repo that publishes a package, and the tag prefixes it publishes under. A repo publishing
# under one prefix needs only `v`; two publish under two and must name both, because a package
# collected from only one of them would leave the fleet with a dependency nothing satisfies.
#
#   <repo>:<prefix>[,<prefix>...]
#
REPOS=(
    'kgsm:v'
    'kgsm-api:v'
    'kgsm-auth:v'
    'kgsm-bot:v'
    'kgsm-firewall:v'
    'kgsm-llm:v'
    'kgsm-meta:v,keyring-v'
    'kgsm-monitor:v'
    'kgsm-reactor:v'
    'kgsm-scheduler:v'
    'kgsm-speech:v,models-v'
    'kgsm-watchdog:v'
    'kgsm-web:v'
)

for tool in repo-add repo-remove vercmp gpg gh curl bsdtar diff cmp; do
    command -v "$tool" >/dev/null || { err "missing required tool: $tool"; exit 1; }
done

gpg --list-secret-keys "$SIGN_KEY" >/dev/null 2>&1 || {
    err "no secret key for ${SIGN_KEY}"
    err "the packaging key signs the database; without it nothing can be published"
    exit 1
}

STAGE="$(mktemp -d)"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$STAGE" "$WORK"; }
trap cleanup EXIT

# `<name> <pkgver>-<pkgrel>` out of a package file name or a database entry. The last fields are
# fixed in number, so strip from the right and whatever remains is the name, hyphens and all
# (kgsm-monitor-net-meter). `drop` says how many trailing fields are not part of the version: one
# for a database entry, two for a file name, which also carries the architecture.
split_nv() {
    awk -F- -v drop="$2" '{
        v = $(NF - drop) "-" $(NF - drop + 1)
        name = $1
        for (i = 2; i <= NF - drop - 1; i++) name = name "-" $i
        print name, v
    }' <<< "$1"
}

# ------------------------------------------------------------------------ what exists, by name only

assets_of() {
    gh release view "$2" --repo "TheKrystalShip/$1" --json assets \
        --jq '.assets[].name | select(endswith(".pkg.tar.zst"))' 2>/dev/null
}

# The newest release carrying a given tag prefix. `gh release list` is newest-first, so the first
# match is the answer; a repo with no release under that prefix yields nothing and is skipped.
newest_tag() {
    gh release list --repo "TheKrystalShip/$1" --limit 100 --json tagName --jq \
        "[.[] | select(.tagName | startswith(\"$2\"))] | .[0].tagName" 2>/dev/null
}

declare -A newest=()     # package name -> "<version>|<file>"
declare -A source_of=()  # file -> "<repo>|<tag>"
declare -A served_here=()  # file -> 1, for everything the repo tag already carries

consider() {
    local file="$1" repo="$2" tag="$3" name version
    read -r name version < <(split_nv "${file%.pkg.tar.zst}" 2)
    [[ -n "$name" && -n "$version" ]] || return 0
    source_of["$file"]="${repo}|${tag}"
    if [[ -n "${newest[$name]:-}" ]]; then
        # A glob and a release listing are both ordered as text, and `kgsm-api-0.97.0` sorts after
        # `kgsm-api-0.106.0` because `9` is greater than `1`. vercmp is the comparison pacman makes.
        [[ "$(vercmp "$version" "${newest[$name]%%|*}")" -gt 0 ]] || return 0
    fi
    newest["$name"]="${version}|${file}"
}

log "listing what the ${META_TAG} tag already carries"
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    served_here["$f"]=1
    consider "$f" "${META_REPO#*/}" "$META_TAG"
done < <(assets_of "${META_REPO#*/}" "$META_TAG")
printf '   %d package file(s) published\n' "${#served_here[@]}"

COLLECTED=() MISSING=()
for entry in "${REPOS[@]}"; do
    repo="${entry%%:*}"
    IFS=',' read -ra prefixes <<< "${entry#*:}"
    for prefix in "${prefixes[@]}"; do
        tag="$(newest_tag "$repo" "$prefix")"
        if [[ -z "$tag" || "$tag" == "null" ]]; then
            MISSING+=("${repo} (${prefix}*)")
            continue
        fi
        found=0
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            consider "$f" "$repo" "$tag"
            found=1
        done < <(assets_of "$repo" "$tag")
        if (( found )); then
            COLLECTED+=("${repo} @ ${tag}")
        else
            # A tag whose release predates the packaging workflow has nothing to give. That is not a
            # failure: the database keeps whatever is already published for that package.
            MISSING+=("${repo} @ ${tag} (no package assets)")
        fi
    done
done

(( ${#newest[@]} )) || { err "nothing to aggregate — neither the release nor any sibling has a package"; exit 1; }

for name in "${!newest[@]}"; do printf '%s %s\n' "$name" "${newest[$name]%%|*}"; done \
    | sort > "${WORK}/wanted"

# ------------------------------------------------------------------------------- what is served now

# Read the database pacman is being served rather than deriving a second opinion: it is the only
# statement of what a node can actually install today.
have_db=0
if curl -fsSL "${RELEASE_URL}/${DB_NAME}.db" -o "${STAGE}/${DB_NAME}.db.tar.zst" 2>/dev/null; then
    bsdtar -tf "${STAGE}/${DB_NAME}.db.tar.zst" 2>/dev/null | sed -n 's|^\([^/]*\)/$|\1|p' \
        | while IFS= read -r e; do split_nv "$e" 1; done | sort > "${WORK}/served"
    [[ -s "${WORK}/served" ]] && have_db=1
fi
if (( ! have_db )); then
    warn "no database is served yet — building the first one"
    : > "${WORK}/served"
    rm -f "${STAGE}/${DB_NAME}.db.tar.zst"
    REBUILD=1
fi

# The public half travels with the repository, and it is the committed armored key rather than an
# export of the secret one: what a node trusts is then exactly what is readable in this repo's diff.
cp "${ROOT}/keyring/${DB_NAME}.asc" "${STAGE}/${DB_NAME}.gpg"
key_changed=1
if curl -fsSL "${RELEASE_URL}/${DB_NAME}.gpg" -o "${WORK}/served.gpg" 2>/dev/null \
   && cmp -s "${WORK}/served.gpg" "${STAGE}/${DB_NAME}.gpg"; then
    key_changed=0
fi

if diff -q "${WORK}/served" "${WORK}/wanted" >/dev/null && (( ! REBUILD )); then
    if (( ! key_changed )); then
        log "the fleet already serves this exact set — nothing to do"
        printf '   %d package(s), %d release(s) checked\n' "${#newest[@]}" "${#COLLECTED[@]}"
        exit 0
    fi
    log "the package set is unchanged but the published key is not"
    if (( DRY_RUN )); then
        log "dry run — would upload ${DB_NAME}.gpg"
    else
        gh release upload "$META_TAG" --repo "$META_REPO" --clobber "${STAGE}/${DB_NAME}.gpg"
        log "${DB_NAME}.gpg republished"
    fi
    exit 0
fi

# ------------------------------------------------------------------------------------ the delta

# Which packages repo-add has to be given: the ones the served database names at a different version
# or does not name at all. Everything else is already described correctly, and an entry derived from
# a package file cannot change while that file does not.
add_files=()
add_names=()
for name in "${!newest[@]}"; do
    version="${newest[$name]%%|*}"
    file="${newest[$name]#*|}"
    if (( ! REBUILD )) && grep -qxF "${name} ${version}" "${WORK}/served"; then
        continue
    fi
    add_files+=("$file")
    add_names+=("$name")
done

# A name the served database still carries that nothing publishes any more. Rare — a package
# renamed or retired — but leaving it would keep pacman offering a file the release may not hold.
drop_names=()
while read -r name _; do
    [[ -n "${newest[$name]:-}" ]] || drop_names+=("$name")
done < "${WORK}/served"

log "${#add_files[@]} package(s) to (re)describe, ${#drop_names[@]} to drop, out of ${#newest[@]}"
for n in "${add_names[@]}"; do printf '     + %s %s\n' "$n" "${newest[$n]%%|*}"; done
for n in "${drop_names[@]}"; do printf '     - %s\n' "$n"; done

if (( DRY_RUN )); then
    log "dry run — nothing downloaded and nothing uploaded"
    exit 0
fi

# ------------------------------------------------------------------------------------- fetch them

for file in "${add_files[@]}"; do
    IFS='|' read -r repo tag <<< "${source_of[$file]}"
    gh release download "$tag" --repo "TheKrystalShip/${repo}" --dir "$STAGE" --clobber \
        --pattern "$file" --pattern "${file}.sig" \
        || { err "could not download ${file} from ${repo} @ ${tag}"; exit 1; }
    [[ -f "${STAGE}/${file}" && -f "${STAGE}/${file}.sig" ]] || {
        err "${file}: the release carries the package or its signature but not both"
        exit 1
    }
done

if (( REBUILD )); then
    # The long way, for a served database that cannot be trusted to describe itself: every package
    # the fleet serves is fetched and the database is built from nothing.
    rm -f "${STAGE}/${DB_NAME}.db.tar.zst" "${STAGE}/${DB_NAME}.files.tar.zst"
    for name in "${!newest[@]}"; do
        file="${newest[$name]#*|}"
        [[ -f "${STAGE}/${file}" ]] && continue
        IFS='|' read -r repo tag <<< "${source_of[$file]}"
        gh release download "$tag" --repo "TheKrystalShip/${repo}" --dir "$STAGE" --clobber \
            --pattern "$file" --pattern "${file}.sig" \
            || { err "could not download ${file} from ${repo} @ ${tag}"; exit 1; }
    done
else
    # repo-add maintains the .files database alongside the .db and will start a fresh one if the
    # existing bytes are not beside it — which would serve a `pacman -F` index naming this run's
    # packages and nothing else.
    curl -fsSL "${RELEASE_URL}/${DB_NAME}.files" -o "${STAGE}/${DB_NAME}.files.tar.zst" 2>/dev/null \
        || warn "no ${DB_NAME}.files is served — repo-add will start one"
fi

# ------------------------------------------------------------------------------------ rebuild the db

selected=()
if (( REBUILD )); then
    for name in "${!newest[@]}"; do selected+=("${newest[$name]#*|}"); done
else
    selected=("${add_files[@]}")
fi

cd "$STAGE"
(( ${#drop_names[@]} )) && GPGKEY="$SIGN_KEY" repo-remove -s -q "${DB_NAME}.db.tar.zst" "${drop_names[@]}"
(( ${#selected[@]} ))   && GPGKEY="$SIGN_KEY" repo-add    -s -q "${DB_NAME}.db.tar.zst" "${selected[@]}"

# repo-add writes kgsm.db and kgsm.files as symlinks to the tarballs. A release asset cannot be a
# symlink, and pacman requests exactly these plain names — so publish the bytes, not the links.
for link in "${DB_NAME}.db" "${DB_NAME}.db.sig" "${DB_NAME}.files" "${DB_NAME}.files.sig"; do
    [[ -L "$link" ]] || continue
    target="$(readlink "$link")"
    rm -f "$link"
    cp "$target" "$link"
done

# The rebuilt database has to name what this run decided it would, or something upstream of here is
# wrong and uploading it would serve that mistake to every node.
bsdtar -tf "${DB_NAME}.db.tar.zst" | sed -n 's|^\([^/]*\)/$|\1|p' \
    | while IFS= read -r e; do split_nv "$e" 1; done | sort > "${WORK}/built"
diff -q "${WORK}/built" "${WORK}/wanted" >/dev/null || {
    err "the rebuilt database does not name the set this run selected"
    diff "${WORK}/built" "${WORK}/wanted" >&2
    exit 1
}

# --------------------------------------------------------------------------------------- publish

# The database, its signature and the key go up every time this point is reached. A package file
# goes up only if the release does not already carry it.
uploads=(
    "${STAGE}/${DB_NAME}.db" "${STAGE}/${DB_NAME}.db.sig"
    "${STAGE}/${DB_NAME}.files" "${STAGE}/${DB_NAME}.files.sig"
    "${STAGE}/${DB_NAME}.gpg"
)
new_packages=0
for file in "${add_files[@]}"; do
    [[ -n "${served_here[$file]:-}" ]] && continue
    uploads+=("${STAGE}/${file}" "${STAGE}/${file}.sig")
    new_packages=$((new_packages+1))
done

log "uploading ${#uploads[@]} asset(s) to ${META_REPO} @ ${META_TAG}"
gh release upload "$META_TAG" --repo "$META_REPO" --clobber "${uploads[@]}"

# ----------------------------------------------------------------------------------------- report

echo
(( ${#COLLECTED[@]} )) && { log "releases checked (${#COLLECTED[@]}):"; printf '     %s\n' "${COLLECTED[@]}"; }
(( ${#MISSING[@]} ))   && { warn "nothing to collect (${#MISSING[@]}): ${MISSING[*]}"; }
log "${DB_NAME}.db names ${#newest[@]} package(s); ${new_packages} package file(s) newly published"
printf '   https://github.com/%s/releases/tag/%s\n' "$META_REPO" "$META_TAG"
