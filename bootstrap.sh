#!/usr/bin/env bash
#
# bootstrap.sh — take a fresh Arch host to a running KGSM node.
#
#   curl -fsSL https://github.com/TheKrystalShip/kgsm-meta/releases/download/repo/bootstrap.sh \
#     | sudo bash -s -- kgsm kgsm-watchdog kgsm-scheduler kgsm-monitor kgsm-firewall kgsm-api
#
#   sudo ./bootstrap.sh                 # show what is on offer and pick interactively
#   sudo ./bootstrap.sh --all           # every package in the kgsm-node group
#   sudo ./bootstrap.sh --repo-only     # wire the repository and the key, install nothing
#   sudo ./bootstrap.sh --start <pkgs>  # also enable and start what is ready to run
#
# Idempotent and re-runnable: it adds the repository only if absent, imports the key only if the
# keyring lacks it, and pacman handles an already-installed package.
#
# It deliberately does NOT seed credentials. A package ships its env file with the secrets blank,
# and this script reports which ones a person still has to fill in — inventing a value there would
# produce a node that starts and is wrong, which is worse than one that has not started yet.
#
set -euo pipefail

REPO_URL="https://github.com/TheKrystalShip/kgsm-meta/releases/download/repo"
REPO_NAME="kgsm"
GROUP="kgsm-node"
KEY_FPR="B7624435FAC1A8280B280CFBA6FBDB3B724DED1B"
PACMAN_CONF="/etc/pacman.conf"

log()  { printf '\033[1;34m>> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m** %s\033[0m\n' "$*" >&2; }
err()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; }
note() { printf '   %s\n' "$*"; }

# A unit each package's own post-install message says to enable deliberately. Neither is a default:
# the indexer starts building a corpus, and the meter attaches BPF to a cgroup the watchdog must
# have created. --start therefore installs them and leaves them alone.
OPT_IN_UNITS=(kgsm-rag-indexer.service kgsm-net-meter.service)

START=0
ALL=0
REPO_ONLY=0
SELECTION=()
for a in "$@"; do
    case "$a" in
        --start)     START=1 ;;
        --all)       ALL=1 ;;
        --repo-only) REPO_ONLY=1 ;;
        -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
        -*)          err "unknown option: $a"; exit 1 ;;
        *)           SELECTION+=("$a") ;;
    esac
done

[[ $EUID -eq 0 ]] || { err "run as root — this installs packages and writes ${PACMAN_CONF}"; exit 1; }
command -v pacman >/dev/null || { err "no pacman: this is an Arch-only bootstrap"; exit 1; }

# ------------------------------------------------------------------------------------- the key

# An ISO install arrives with an initialised keyring, but a minimal or container-built root may
# not, and --lsign-key needs pacman's own local signing key to exist. Both calls are idempotent.
pacman-key --init >/dev/null 2>&1
pacman-key --populate archlinux >/dev/null 2>&1 || true

if pacman-key --list-keys "$KEY_FPR" >/dev/null 2>&1; then
    log "packaging key already trusted"
else
    log "trusting the packaging key"
    tmpkey="$(mktemp)"
    trap 'rm -f "$tmpkey"' EXIT
    curl -fsSL "${REPO_URL}/${REPO_NAME}.gpg" -o "$tmpkey"
    pacman-key --add "$tmpkey"
    # Locally signed, not merely imported: pacman refuses a package whose key it has no trust path
    # to, and this key is on no keyserver, so --recv-keys does not apply.
    pacman-key --lsign-key "$KEY_FPR"
fi

# ------------------------------------------------------------------------------ the repository

if grep -q "^\[${REPO_NAME}\]" "$PACMAN_CONF"; then
    log "[${REPO_NAME}] already in ${PACMAN_CONF}"
else
    log "adding [${REPO_NAME}] to ${PACMAN_CONF}"
    cp -a "$PACMAN_CONF" "${PACMAN_CONF}.bak-$(date +%Y%m%d-%H%M%S)"
    cat >> "$PACMAN_CONF" <<EOF

# The KGSM fleet repository. Packages are release assets on a rolling tag, so this URL is stable.
# Required, not Optional: an unsigned or wrongly-signed package is refused rather than warned about.
[${REPO_NAME}]
SigLevel = Required DatabaseRequired
Server = ${REPO_URL}
EOF
fi

log "refreshing package databases"
pacman -Sy --noconfirm >/dev/null

if (( REPO_ONLY )); then
    log "repository wired. Available:"
    pacman -Sg "$GROUP" | awk '{print "     " $2}'
    exit 0
fi

# -------------------------------------------------------------------------------- the selection

mapfile -t AVAILABLE < <(pacman -Sg "$GROUP" | awk '{print $2}')
(( ${#AVAILABLE[@]} )) || { err "group ${GROUP} is empty — the repository may not have synced"; exit 1; }

if (( ALL )); then
    SELECTION=("${AVAILABLE[@]}")
elif (( ${#SELECTION[@]} == 0 )); then
    echo
    log "packages in ${GROUP}:"
    for i in "${!AVAILABLE[@]}"; do printf '     %2d) %s\n' "$((i+1))" "${AVAILABLE[$i]}"; done
    echo
    read -rp "   Numbers to install (space separated, blank = all): " picks
    if [[ -z "${picks// }" ]]; then
        SELECTION=("${AVAILABLE[@]}")
    else
        for n in $picks; do
            if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#AVAILABLE[@]} )); then
                err "not a listed number: $n"; exit 1
            fi
            SELECTION+=("${AVAILABLE[$((n-1))]}")
        done
    fi
fi

log "installing: ${SELECTION[*]}"
pacman -S --needed --noconfirm "${SELECTION[@]}"

# ------------------------------------------------------------------ what still needs a person
#
# Everything below is derived from what pacman actually installed rather than from a list kept in
# this script, so a leaf added to the ecosystem later is reported without touching this file.

needs_config=()
ready_units=()
blocked_units=()
optin_units=()

is_opt_in() { local u; for u in "${OPT_IN_UNITS[@]}"; do [[ "$u" == "$1" ]] && return 0; done; return 1; }

for pkg in "${SELECTION[@]}"; do
    pacman -Qq "$pkg" >/dev/null 2>&1 || continue

    # A blank value or a YOUR_..._HERE placeholder is a credential the package deliberately ships
    # unset. Anything else is a real default and needs no attention.
    pkg_incomplete=0
    while IFS= read -r envfile; do
        [[ -f "$envfile" ]] || continue
        if grep -qE '^[A-Za-z_][A-Za-z0-9_]*=$|YOUR_[A-Z_]*_HERE' "$envfile"; then
            needs_config+=("${envfile}")
            pkg_incomplete=1
        fi
    done < <(pacman -Qlq "$pkg" | grep -E '^/etc/.*\.env$' || true)

    # A socket and a service of the same name are one socket-activated unit: enabling the socket is
    # what starts it on demand, and enabling both would defeat the activation.
    mapfile -t units < <(pacman -Qlq "$pkg" | grep -oP '/usr/lib/systemd/system/\K[^/]+\.(service|socket|timer)$' || true)
    for u in "${units[@]}"; do
        if [[ "$u" == *.service ]] && printf '%s\n' "${units[@]}" | grep -qx "${u%.service}.socket"; then
            continue
        fi
        if is_opt_in "$u";        then optin_units+=("$u")
        elif (( pkg_incomplete )); then blocked_units+=("$u")
        else                            ready_units+=("$u")
        fi
    done
done

echo
if (( ${#needs_config[@]} )); then
    warn "these hold blank credentials and must be filled in before their service runs:"
    printf '     %s\n' "${needs_config[@]}"
    note ""
    note "If this host signs people in, the shared provider credentials go in /etc/kgsm/kgsm-auth.env,"
    note "which every unit loads before its own file. No package ships those, deliberately."
    echo
fi

if (( START )); then
    if (( ${#ready_units[@]} )); then
        log "enabling: ${ready_units[*]}"
        systemctl daemon-reload
        systemctl enable --now "${ready_units[@]}"
    fi
    (( ${#blocked_units[@]} )) && warn "not started, configuration incomplete: ${blocked_units[*]}"
else
    (( ${#ready_units[@]} )) && { log "ready to run:"; note "systemctl enable --now ${ready_units[*]}"; }
    (( ${#blocked_units[@]} )) && { warn "ready once configured:"; note "systemctl enable --now ${blocked_units[*]}"; }
fi

if (( ${#optin_units[@]} )); then
    echo
    log "installed but deliberately not started — each is a decision, not a default:"
    for u in "${optin_units[@]}"; do
        case "$u" in
            kgsm-rag-indexer.service) note "${u}   builds the assistant's retrieval index" ;;
            kgsm-net-meter.service)   note "${u}     attaches the per-server network meter to kgsm.slice" ;;
            *)                        note "${u}" ;;
        esac
    done
fi

echo
log "done. Upgrades from here are: pacman -Syu"
