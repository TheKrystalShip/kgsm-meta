#!/usr/bin/env bash
#
# setup-node.sh — point pacman at the KGSM repository and trust the key that signs it.
#
#   curl -fsSL https://raw.githubusercontent.com/TheKrystalShip/kgsm-meta/main/setup-node.sh | sudo bash
#
# Afterwards the host installs KGSM the way it installs anything else:
#
#   pacman -S kgsm-node
#
# It configures pacman and nothing more. No unit is written, no component is chosen, no credential
# is invented; the group prompt behind `pacman -S kgsm-node` stays the node's package selector.
#
#   --no-upgrade   write the configuration and stop, syncing nothing
#
# Piped into a shell, flags need `-s --` so bash hands them to the script rather than reading them
# as its own:  curl -fsSL <url> | sudo bash -s -- --no-upgrade
#
# WHAT THIS DOES NOT PROTECT AGAINST. Everything pacman fetches afterwards is verified against the
# key trusted here, and the fingerprint below is what makes that trust mean something — a substituted
# key is refused rather than trusted quietly. But a script fetched over the network cannot vouch for
# itself: whoever could serve you a different key could serve you a different copy of this file, with
# a different fingerprint written into it. Reading it before running it, or comparing the fingerprint
# against a copy obtained some other way, is what closes that gap. The README sets out the same steps
# by hand for exactly that reason.
#
set -euo pipefail

# The packaging key. Compare it against a copy obtained some other way.
KEY_FINGERPRINT='B7624435FAC1A8280B280CFBA6FBDB3B724DED1B'

# The tag never moves, so this URL is stable for the life of the fleet. KGSM_REPO_URL points the
# whole script at a different repository — a file:// directory under test, or a mirror.
REPO_URL="${KGSM_REPO_URL:-https://github.com/TheKrystalShip/kgsm-meta/releases/download/repo}"

# Printed rather than read back out of this file: piped into a shell, $0 is "bash" and there is no
# file to read.
usage() {
    cat <<'USAGE'
setup-node.sh — point pacman at the KGSM repository and trust the key that signs it.

  curl -fsSL https://raw.githubusercontent.com/TheKrystalShip/kgsm-meta/main/setup-node.sh | sudo bash

Then:  pacman -S kgsm-node

  --no-upgrade   write the configuration and stop, syncing nothing

Piped into a shell, flags need `-s --`:
  curl -fsSL <url> | sudo bash -s -- --no-upgrade

KGSM_REPO_URL points the whole script at a different repository.
USAGE
}

UPGRADE=1
while (( $# )); do
    case "$1" in
        --no-upgrade) UPGRADE=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            printf 'setup-node.sh: unknown argument %s\n' "$1" >&2; exit 2 ;;
    esac
done

log()  { printf '\033[1;34m>> %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
err()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; }

(( EUID == 0 )) || {
    err "this needs root — it writes /etc/pacman.conf and pacman's keyring"
    note "curl -fsSL <this url> | sudo bash"
    exit 1
}
command -v pacman >/dev/null || { err "no pacman on this host; KGSM's packages are pacman packages"; exit 1; }

# Piped into bash this script IS stdin, so a command that reads stdin eats the rest of it. The key
# therefore goes to a file and never to `pacman-key --add -`, and every command that could read a
# prompt is given /dev/null explicitly. Redirecting fd 0 for the whole script would be worse than
# the problem: bash is still reading the script from it.

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------------------- the key

# An ISO install arrives with an initialised keyring. A container or a minimal root may not, and
# --lsign-key needs pacman's own local signing key to exist. Idempotent either way.
log "initialising pacman's keyring"
pacman-key --init </dev/null

log "fetching the packaging key"
curl -fsSL "${REPO_URL}/kgsm.gpg" -o "${TMP}/kgsm.gpg" </dev/null || { err "could not fetch ${REPO_URL}/kgsm.gpg"; exit 1; }

# curl reporting success proves a file arrived, not which one. Read the fingerprints out of the file
# and refuse before importing, so a substituted key never enters the keyring at all.
mapfile -t fetched < <(gpg --with-colons --show-keys "${TMP}/kgsm.gpg" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }')
printf '%s\n' "${fetched[@]}" | grep -qx "$KEY_FINGERPRINT" || {
    err "the fetched key is not the one this script pins"
    note "wanted:  ${KEY_FINGERPRINT}"
    note "arrived: ${fetched[*]:-nothing readable as a key}"
    exit 1
}
note "fingerprint matches: ${KEY_FINGERPRINT}"

log "trusting it"
pacman-key --add "${TMP}/kgsm.gpg" </dev/null
# Naming the fingerprint is the assertion: signing by any other name fails rather than trusting
# whatever happened to be imported.
pacman-key --lsign-key "$KEY_FINGERPRINT" </dev/null

# --------------------------------------------------------------------------------- the repository

# Required, not Optional: an unsigned or wrongly-signed package is refused rather than warned about.
STANZA=$(printf '\n[kgsm]\nSigLevel = Required DatabaseRequired\nServer = %s\n' "$REPO_URL")

if grep -qE '^\[kgsm\]' /etc/pacman.conf; then
    current="$(awk '/^\[kgsm\]/{f=1;next} /^\[/{f=0} f && /^Server *=/{sub(/^Server *= */,"");print;exit}' /etc/pacman.conf)"
    if [[ "$current" == "$REPO_URL" ]]; then
        log "[kgsm] is already configured"
    else
        log "pointing the existing [kgsm] section at ${REPO_URL}"
        note "was: ${current:-no Server line}"
        cp /etc/pacman.conf /etc/pacman.conf.bak
        awk -v url="$REPO_URL" '
            /^\[kgsm\]/ { f=1 } /^\[/ && !/^\[kgsm\]/ { f=0 }
            f && /^Server *=/ { print "Server = " url; next }
            { print }
        ' /etc/pacman.conf.bak > /etc/pacman.conf
    fi
else
    log "adding [kgsm] to /etc/pacman.conf"
    printf '%s\n' "$STANZA" >> /etc/pacman.conf
fi

# ------------------------------------------------------------------------------------- the sync

if (( UPGRADE )); then
    # -Syu rather than -Sy: refreshing the databases and then installing against them without
    # upgrading is the partial upgrade Arch breaks under. --noconfirm because piped into bash there
    # is nobody able to answer a prompt.
    log "synchronising and upgrading"
    pacman -Syu --noconfirm </dev/null
else
    log "not synchronising (--no-upgrade); run pacman -Syu before installing anything"
fi

echo
log "pacman is configured for KGSM"
note "install this node's components with:  pacman -S kgsm-node"
note "that prompt is the selector — press enter for all of them, or give a range like 1 2 5 6"
