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
#   sudo ./bootstrap.sh --start <pkgs>  # also start anything the install left ready and stopped
#
# Idempotent and re-runnable: it adds the repository only if absent, imports the key only if the
# keyring lacks it, and pacman handles an already-installed package.
#
# Enabling and starting are the PACKAGES' job, not this script's: each one applies kgsm-base's
# preset policy to its own units in its scriptlet, and a post-transaction hook starts what is ready.
# --start re-runs that same hook logic afterwards, which covers a host where the transaction ran
# with no systemd to act on.
#
# It deliberately does NOT seed credentials. A package ships its env file with the secrets blank,
# and kgsm-node-status reports which ones a person still has to fill in — inventing a value there
# would produce a node that starts and is wrong, which is worse than one that has not started yet.
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

NODE_STATUS="/usr/bin/kgsm-node-status"
APPLY_STATE="/usr/lib/kgsm-base/apply-node-state"

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

# ---------------------------------------------------------------------- what the node now is
#
# Reported by kgsm-node-status, which every package pulls in through kgsm-base. It derives
# everything from what pacman actually installed, so a leaf added to the ecosystem later is
# reported with no change here — and the answer a person reads is the same one the hook acted on.

if (( START )) && [[ -x "$APPLY_STATE" ]]; then
    # The same logic the post-transaction hook runs, with no changed paths on stdin: start what is
    # ready and stopped, restart nothing. It covers the one case the hook cannot — a transaction
    # that ran before this host had a systemd to act on.
    log "starting what the install left ready"
    systemctl daemon-reload || true
    "$APPLY_STATE" </dev/null
elif [[ -x "$NODE_STATUS" ]]; then
    "$NODE_STATUS"
else
    # kgsm-base is a dependency of every package that ships a unit, so reaching this means the
    # transaction did not do what it said. Report what is on disk rather than deriving a second
    # opinion here.
    warn "${NODE_STATUS} is missing — kgsm-base did not install"
    note "installed:"
    pacman -Qq 2>/dev/null | grep -E '^kgsm(-|$)' | sed 's/^/       /' || true
fi

echo
log "done. Upgrades from here are: pacman -Syu"
