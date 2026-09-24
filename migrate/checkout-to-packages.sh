#!/usr/bin/env bash
#
# checkout-to-packages.sh — move a host deployed from the workspace's checkouts onto the [kgsm] packages,
# carrying every instance, backup, account, session, key, journal and setting across once.
#
#   sudo migrate/checkout-to-packages.sh --from-user heisen plan
#   sudo migrate/checkout-to-packages.sh --from-user heisen all
#   sudo migrate/checkout-to-packages.sh --from-user heisen <phase>
#
# Phases, in order: preflight, stop, snapshot, clear, base, carry, install, library, start, verify.
# `all` runs them in order and stops at the first that fails; re-running a phase is safe. `plan` runs
# preflight and prints what every later phase would do, changing nothing.
#
# A checkout deploy runs every unit and every game server as the person who deployed it, from units
# symlinked out of /etc/<project>/systemd and binaries rsynced into /opt/kgsm-*. A package node runs them
# as the `kgsm` service account from /usr/lib/systemd/system, with the engine's data in that account's
# home. The binaries and units are replaced wholesale; the data is moved — a rename on one filesystem —
# and re-owned, never copied, and nothing is deleted: what the packages replace is moved under
# $STATE_DIR/moved/, mirroring its original path, so the migration can be undone.
#
# Needs the [kgsm] repository configured (setup-node.sh) and root. Every game server is stopped for the
# duration and started again at the end if it was running at the start.
#
set -euo pipefail

STATE_DIR="${KGSM_MIGRATION_DIR:-/var/lib/kgsm-migration}"
FROM_USER=""
PACKAGES=()
PHASE=""

log()  { printf '\033[1;34m>> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m** %s\033[0m\n' "$*" >&2; }
err()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; }
note() { printf '   %s\n' "$*"; }
die()  { err "$*"; exit 1; }

usage() { sed -n '3,21p' "$0" | sed 's/^# \?//'; exit "${1:-1}"; }

while (( $# )); do
    case "$1" in
        --from-user) FROM_USER="$2"; shift 2 ;;
        --package)   PACKAGES+=("$2"); shift 2 ;;
        -h|--help)   usage 0 ;;
        -*)          die "unknown option: $1" ;;
        *)           PHASE="$1"; shift ;;
    esac
done
[[ -n "$FROM_USER" && -n "$PHASE" ]] || usage
[[ $EUID -eq 0 ]] || die "run as root"

FROM_HOME="$(getent passwd "$FROM_USER" | cut -d: -f6)" || true
[[ -n "$FROM_HOME" && -d "$FROM_HOME" ]] || die "no user '${FROM_USER}' with a home directory"

MOVED="${STATE_DIR}/moved"
SNAPSHOT="${STATE_DIR}/snapshot"
install -d -m 0700 "$STATE_DIR" "$MOVED" "$SNAPSHOT"

# The engine as the account that owns its data at the time. Before the packages, that is the deploying
# user with the deployed engine; after, the service account with the packaged one.
as_from() { runuser -u "$FROM_USER" -- env HOME="$FROM_HOME" "$@"; }
kgsm_home() { getent passwd kgsm | cut -d: -f6; }
as_kgsm() { runuser -u kgsm -- env HOME="$(kgsm_home)" "$@"; }

# Move a path aside under $MOVED, keeping its absolute path, so undoing is `mv` back. A path already
# moved is left where it went.
move_aside() {
    local path="$1"
    [[ -e "$path" || -L "$path" ]] || return 0
    local dest="${MOVED}${path}"
    install -d -m 0755 "$(dirname "$dest")"
    [[ -e "$dest" || -L "$dest" ]] && { warn "already moved aside, leaving: ${path}"; return 0; }
    mv "$path" "$dest"
    note "moved aside: ${path}"
}

# ── What the checkout deploy put here, and which packages replace it ──────────────────────────────

declare -A PREFIX_PACKAGE=(
    [kgsm]=kgsm
    [kgsm-api]=kgsm-api
    [kgsm-auth-anchor]=kgsm-auth-anchor
    [kgsm-watchdog]=kgsm-watchdog
    [kgsm-monitor]=kgsm-monitor
    [kgsm-dns]=kgsm-dns
    [kgsm-assistant]=kgsm-llm
    [kgsm-bot]=kgsm-bot
    [kgsm-speech]=kgsm-speech
    [kgsm-reactor]=kgsm-reactor
    [kgsm-scheduler]=kgsm-scheduler
    [kgsm-firewall]=kgsm-firewall
)

derive_packages() {
    local prefix
    for prefix in "${!PREFIX_PACKAGE[@]}"; do
        [[ -d "/opt/${prefix}" ]] && printf '%s\n' "${PREFIX_PACKAGE[$prefix]}"
    done
    [[ -e /etc/systemd/system/kgsm-net-meter.service ]] && echo kgsm-monitor-net-meter
    [[ -e /etc/systemd/system/kgsm-rag-indexer.service ]] && echo kgsm-rag-indexer
    compgen -G '/etc/systemd/system/kgsm-llama-*' >/dev/null && echo kgsm-llm-llamacpp
    if [[ -d /opt/kgsm-api ]]; then echo kgsm-web; fi
    if [[ -d /opt/kgsm-auth-anchor ]]; then echo kgsm-web-auth; fi
    return 0
}

if (( ${#PACKAGES[@]} == 0 )); then
    mapfile -t PACKAGES < <(derive_packages | sort -u)
fi

# The checkout deploy's own units: every kgsm-* unit systemd reads from /etc that no package owns.
checkout_units() {
    local f
    for f in /etc/systemd/system/kgsm-*.service /etc/systemd/system/kgsm-*.socket /etc/systemd/system/kgsm-*.timer; do
        [[ -e "$f" || -L "$f" ]] || continue
        pacman -Qoq "$f" >/dev/null 2>&1 && continue
        basename "$f"
    done
}

# Every instance the engine knows, as `name<TAB>config file`, read through the engine that owns them.
# The engine answers with its registry's path, a symlink under its data directory, which moves with that
# directory; resolved, the path is the config inside the instance's own working directory, which stays
# where it is until the library phase moves the instance.
instances_with_configs() {
    local runner=("$@") name cfg
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        cfg="$("${runner[@]}" /usr/bin/kgsm instances find "$name" 2>/dev/null | tail -n1)"
        printf '%s\t%s\n' "$name" "$(readlink -f "$cfg")"
    done < <("${runner[@]}" /usr/bin/kgsm instances list 2>/dev/null)
}

config_value() { sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$1" | tail -n1; }

# The instances as the deployed engine listed them, recorded while it is still here: clear moves it
# aside, and every later phase reads this file instead. Config paths inside it stay valid until the
# library phase, which moves the instances through the packaged engine.
INSTANCES="${STATE_DIR}/instances"
recorded_instances() {
    [[ -f "$INSTANCES" ]] || die "no instance record — run the stop phase first"
    cat "$INSTANCES"
}

# ── Phases ────────────────────────────────────────────────────────────────────────────────────────

phase_preflight() {
    log "preflight"
    pacman -Sl kgsm >/dev/null 2>&1 || die "the [kgsm] repository is not configured — run setup-node.sh first"
    note "packages: ${PACKAGES[*]}"
    local missing=()
    local p
    for p in kgsm-base "${PACKAGES[@]}"; do
        pacman -Si "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    (( ${#missing[@]} == 0 )) || die "not in the repository: ${missing[*]}"

    [[ -x /usr/bin/kgsm || -x /opt/kgsm/kgsm.sh ]] || die "no engine to read the instances through"
    [[ -f /etc/kgsm/kgsm-cluster.env ]] || die "/etc/kgsm/kgsm-cluster.env is missing"

    local units
    units="$(checkout_units | tr '\n' ' ')"
    note "checkout units: ${units:-none}"
    note "instances:"
    instances_with_configs as_from | while IFS=$'\t' read -r name cfg; do
        note "  ${name}  $(config_value "$cfg" working_dir)"
    done
    log "downloading the packages"
    pacman -Sw --noconfirm --needed kgsm-base "${PACKAGES[@]}" >/dev/null
}

phase_stop() {
    log "stopping every game server and every KGSM unit"
    if [[ ! -f "$INSTANCES" ]]; then
        instances_with_configs as_from > "${INSTANCES}.tmp"
        mv "${INSTANCES}.tmp" "$INSTANCES"
    fi
    local running="${STATE_DIR}/running-instances"
    if [[ ! -f "$running" ]]; then
        : > "$running.tmp"
        local name
        while IFS=$'\t' read -r name _; do
            if as_from /usr/bin/kgsm instances status "$name" 2>/dev/null | grep -q 'Status:.*Active'; then
                echo "$name" >> "$running.tmp"
            fi
        done < "$INSTANCES"
        mv "$running.tmp" "$running"
    fi
    note "running at the start: $(tr '\n' ' ' < "$running")"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        as_from /usr/bin/kgsm stop "$name" >/dev/null 2>&1 || warn "could not stop ${name} through the engine"
    done < "$running"

    local units
    mapfile -t units < <(systemctl list-units --all --plain --no-legend 'kgsm-*' | awk '{print $1}')
    (( ${#units[@]} == 0 )) || systemctl stop "${units[@]}" 2>/dev/null || true
    note "stopped: ${units[*]:-none}"
}

phase_snapshot() {
    log "snapshotting what the migration changes, into ${SNAPSHOT}"
    [[ -f "${SNAPSHOT}/etc.tar" ]] || tar -cpf "${SNAPSHOT}/etc.tar" --ignore-failed-read \
        /etc/kgsm /etc/kgsm-* /etc/systemd/system/kgsm-* /etc/polkit-1/rules.d /etc/nginx 2>/dev/null
    local state=()
    local d
    for d in /var/lib/kgsm /var/lib/kgsm-*; do
        [[ -e "$d" && "$d" != "$STATE_DIR" ]] && state+=("$d")
    done
    [[ -f "${SNAPSHOT}/state.tar" ]] || tar -cpf "${SNAPSHOT}/state.tar" --ignore-failed-read "${state[@]}" 2>/dev/null
    [[ -f "${SNAPSHOT}/engine.tar" ]] || tar -cpf "${SNAPSHOT}/engine.tar" --ignore-failed-read \
        --exclude="${FROM_HOME}/.local/share/kgsm/backups" \
        "${FROM_HOME}/.local/share/kgsm" "${FROM_HOME}/.config/kgsm" "${FROM_HOME}/.steam" 2>/dev/null
    sha256sum /etc/kgsm/kgsm-cluster.env > "${SNAPSHOT}/cluster-env.sha256"
    du -sh "$SNAPSHOT"/* | sed 's/^/   /'
}

phase_clear() {
    log "moving the checkout deploy aside"
    local unit
    while IFS= read -r unit; do
        systemctl disable "$unit" >/dev/null 2>&1 || true
        move_aside "/etc/systemd/system/${unit}"
    done < <(checkout_units)
    local d
    for d in /etc/systemd/system/kgsm-*.d; do
        [[ -d "$d" ]] && move_aside "$d"
    done
    for d in /etc/kgsm*/systemd; do
        [[ -d "$d" ]] && move_aside "$d"
    done
    for d in /etc/polkit-1/rules.d/4?-kgsm-*.rules; do
        [[ -e "$d" ]] && move_aside "$d"
    done
    local prefix
    for prefix in "${!PREFIX_PACKAGE[@]}"; do
        [[ -d "/opt/${prefix}" ]] && ! pacman -Qoq "/opt/${prefix}" >/dev/null 2>&1 && move_aside "/opt/${prefix}"
    done
    for d in /usr/bin/kgsm /usr/local/bin/kgsm /usr/local/bin/kgsm-*; do
        [[ -L "$d" ]] && ! pacman -Qoq "$d" >/dev/null 2>&1 && move_aside "$d"
    done

    # Game-server units a legacy engine wrote for the deploying user. Native servers run under the
    # watchdog; a unit left behind here names a user and a path that no longer hold the server.
    local cfg name
    while IFS=$'\t' read -r name cfg; do
        for unit in "/etc/systemd/system/${name}.service" "/etc/systemd/system/${name}.socket"; do
            [[ -f "$unit" ]] && grep -q "^User=${FROM_USER}$" "/etc/systemd/system/${name}.service" 2>/dev/null \
                && move_aside "$unit"
        done
    done < <(recorded_instances)

    # Whatever else a package ships that is already on disk and belongs to no package: a file the
    # deploy put where the package now puts its own. The env files stay — --overwrite lets pacman keep
    # them and write the package's version beside them as .pacnew.
    log "clearing paths the packages ship"
    local pkgfile path
    while IFS= read -r pkgfile; do
        while IFS= read -r path; do
            [[ "$path" == */ ]] && continue
            path="/${path}"
            [[ "$path" == /etc/kgsm*/*.env ]] && continue
            [[ -e "$path" || -L "$path" ]] || continue
            pacman -Qoq "$path" >/dev/null 2>&1 && continue
            move_aside "$path"
        done < <(pacman -Qlpq "$pkgfile" 2>/dev/null | sed 's|^/||')
    done < <(pacman -Sp --print-format '%l' kgsm-base "${PACKAGES[@]}" 2>/dev/null | sed 's|^file://||;s|.*/|/var/cache/pacman/pkg/|')

    systemctl daemon-reload
}

phase_base() {
    log "installing kgsm-base: the service account and the shared state tree"
    pacman -S --noconfirm --needed --overwrite '/etc/kgsm/*' kgsm-base
    getent passwd kgsm >/dev/null || die "kgsm-base installed no kgsm account"
    if ! sha256sum -c --quiet "${SNAPSHOT}/cluster-env.sha256" >/dev/null 2>&1; then
        err "kgsm-base changed /etc/kgsm/kgsm-cluster.env — restoring it from the snapshot"
        tar -xpf "${SNAPSHOT}/etc.tar" -C / etc/kgsm/kgsm-cluster.env etc/kgsm/cluster-founded 2>/dev/null || true
        die "stopping: the cluster secret has to be this host's before anything starts"
    fi
    note "the cluster secret is unchanged"
}

phase_carry() {
    local home
    home="$(kgsm_home)"
    [[ -n "$home" ]] || die "no kgsm account yet — run the base phase"
    log "carrying the engine's data into ${home}"

    install -d -o kgsm -g kgsm -m 0755 "${home}/.local" "${home}/.local/share" "${home}/.local/bin" "${home}/.config"
    local rel
    for rel in .local/share/kgsm .config/kgsm .steam Steam .local/share/Steam; do
        [[ -e "${FROM_HOME}/${rel}" ]] || continue
        if [[ -e "${home}/${rel}" ]]; then
            if [[ -z "$(ls -A "${home}/${rel}" 2>/dev/null)" ]]; then
                rmdir "${home}/${rel}"
            else
                move_aside "${home}/${rel}"
            fi
        fi
        mv "${FROM_HOME}/${rel}" "${home}/${rel}"
        note "moved ${FROM_HOME}/${rel} → ${home}/${rel}"
    done

    # Every instance, read through its registry entry. Its command shortcut moves with it, and every
    # path its config or the engine's own files hold under the old home is rewritten to the new one.
    local name cfg shortcut
    while IFS=$'\t' read -r name cfg; do
        [[ -f "$cfg" ]] || { warn "${name}: no config at '${cfg}'"; continue; }
        shortcut="$(config_value "$cfg" command_shortcut_file)"
        if [[ "$shortcut" == "${FROM_HOME}"/* && -e "$shortcut" ]]; then
            mv "$shortcut" "${home}${shortcut#"${FROM_HOME}"}"
        fi
        if grep -qF "${FROM_HOME}/" "$cfg"; then
            sed -i "s|${FROM_HOME}/|${home}/|g" "$cfg"
            note "${name}: paths under ${FROM_HOME} now under ${home}"
        fi
        # The instance and the directory it sits in: moving it out renames it inside that directory.
        chown -R kgsm:kgsm "$(config_value "$cfg" working_dir)"
        chown kgsm:kgsm "$(dirname "$(config_value "$cfg" working_dir)")"
    done < <(recorded_instances)

    local f
    while IFS= read -r f; do
        sed -i "s|${FROM_HOME}/|${home}/|g" "$f"
        note "rewrote ${f}"
    done < <(grep -rlIF "${FROM_HOME}/" "${home}/.config/kgsm" "${home}/.local/share/kgsm" \
                --exclude-dir=backups --exclude-dir=logs 2>/dev/null || true)

    log "re-owning the state"
    chown -R kgsm:kgsm "$home"
    local d
    for d in /var/lib/kgsm-* /var/lib/llama /var/lib/kgsm/*; do
        [[ -e "$d" ]] || continue
        [[ "$d" == "$STATE_DIR" ]] && continue
        [[ "$(stat -c %U "$d")" == "$FROM_USER" ]] || continue
        chown -R kgsm:kgsm "$d"
        note "re-owned ${d}"
    done
    chown kgsm:kgsm /var/lib/kgsm
}

phase_install() {
    log "installing ${PACKAGES[*]}"
    pacman -S --noconfirm --needed --overwrite '/etc/kgsm*/*' "${PACKAGES[@]}"
    local pacnew
    pacnew="$(find /etc/kgsm /etc/kgsm-* -name '*.pacnew' 2>/dev/null | tr '\n' ' ')"
    [[ -z "$pacnew" ]] || note "kept this host's settings; the packages' versions are beside them: ${pacnew}"
}

phase_library() {
    local home new name root
    home="$(kgsm_home)"
    new="${home}/.local/share/kgsm/library"
    log "moving every instance into ${new}"
    root="$(as_kgsm /usr/bin/kgsm libraries list --json 2>/dev/null | sed -n 's/.*"name": *"default".*"path": *"\([^"]*\)".*/\1/p' | head -n1)"
    if [[ -z "$root" ]]; then
        root="$(sed -n '/^\[default\]/,/^\[/{s/^path=//p}' "${home}/.local/share/kgsm/libraries.ini" | head -n1)"
    fi
    [[ -n "$root" ]] || die "the engine names no default library"
    if [[ "$(realpath -m "$root")" == "$(realpath -m "$new")" ]]; then
        note "the default library is already ${new}"
        return 0
    fi

    install -d -o kgsm -g kgsm -m 0755 "$new"
    # The drain takes the library's marker off its root, which the old root's owner holds.
    setfacl -m u:kgsm:rwx "$root"
    as_kgsm /usr/bin/kgsm libraries list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx moved \
        || as_kgsm /usr/bin/kgsm libraries add "$new" --name moved
    as_kgsm /usr/bin/kgsm libraries remove default --drain moved
    as_kgsm /usr/bin/kgsm libraries rename moved default
    as_kgsm /usr/bin/kgsm config set default_library=default >/dev/null 2>&1 || true
    setfacl -x u:kgsm "$root"
    as_kgsm /usr/bin/kgsm libraries list | sed 's/^/   /'
}

phase_start() {
    log "starting what was running"
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if as_kgsm /usr/bin/kgsm start "$name" >/dev/null 2>&1; then
            note "started ${name}"
        else
            warn "could not start ${name}"
        fi
    done < "${STATE_DIR}/running-instances"
}

phase_verify() {
    log "verifying"
    local failed=0 unit user
    for unit in $(systemctl list-units --all --plain --no-legend 'kgsm-*' | awk '{print $1}'); do
        [[ "$unit" == *.service ]] || continue
        user="$(systemctl show "$unit" -p User --value)"
        [[ -z "$user" || "$user" == kgsm || "$user" == root ]] || { err "${unit} runs as ${user}"; failed=1; }
        [[ "$(systemctl show "$unit" -p FragmentPath --value)" == /usr/lib/* ]] \
            || { err "${unit} is not the packaged unit"; failed=1; }
    done
    local failed_units
    failed_units="$(systemctl list-units --failed --plain --no-legend 'kgsm-*' | awk '{print $1}' | tr '\n' ' ')"
    [[ -z "$failed_units" ]] || { err "failed units: ${failed_units}"; failed=1; }
    local home
    home="$(kgsm_home)"
    note "instances:"
    as_kgsm /usr/bin/kgsm instances list | sed 's/^/     /'
    [[ -e "${FROM_HOME}/.local/share/kgsm" ]] && { err "${FROM_HOME}/.local/share/kgsm still exists"; failed=1; }
    (( failed == 0 )) || die "verification failed"
    log "verified"
}

case "$PHASE" in
    plan)      phase_preflight
               log "phases that would run: stop snapshot clear base carry install library start verify" ;;
    preflight|stop|snapshot|clear|base|carry|install|library|start|verify) "phase_${PHASE}" ;;
    all)       for p in preflight stop snapshot clear base carry install library start verify; do "phase_${p}"; done ;;
    *)         usage ;;
esac
