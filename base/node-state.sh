# shellcheck shell=bash
#
# node-state.sh — what this node's KGSM packages laid down, and what still needs a person.
#
# Sourced by /usr/bin/kgsm-node-status (which reports it) and by the post-transaction hook (which
# acts on it), so the report and the action taken on it cannot be computed two different ways.
#
# Everything is derived from what pacman actually installed and what systemd was actually asked
# for. Nothing here holds a list of leaves, so a leaf added to the ecosystem later is covered with
# no edit to this file.

# Whether a unit is meant to run on this host: `on`, `off`, or empty for a unit that is not a
# decision at all. A unit the preset policy leaves disabled is not broken and not misconfigured —
# it is a choice somebody makes per host — and asking systemd is what keeps 50-kgsm.preset the
# single place that policy is written down.
kgsm_unit_policy() {
    local state
    state="$(systemctl is-enabled -- "$1" 2>/dev/null)" || true
    case "$state" in
        enabled|enabled-runtime) printf 'on' ;;
        # A unit with no [Install] section can be neither enabled nor disabled: it runs when
        # something else pulls it in — a timer firing its service, a socket activating one. Listing
        # it as opt-in would offer a choice that does not exist, and starting it would run a
        # one-shot the timer exists to schedule.
        static|indirect|generated|transient|alias) printf '' ;;
        *) printf 'off' ;;
    esac
}

kgsm_unit_is_active() {
    systemctl is-active --quiet -- "$1" 2>/dev/null
}

# What systemd says the unit is doing, verbatim, or "unknown" where there is no systemd to ask —
# a chroot or a container. Never a substituted "inactive": not running and not knowing are
# different facts.
kgsm_unit_state() {
    local state
    kgsm_have_systemd || { printf 'unknown'; return 0; }
    state="$(systemctl is-active -- "$1" 2>/dev/null)" || true
    printf '%s' "${state:-unknown}"
}

# systemd's own booted check. A package installed into a chroot, an image build or a container
# without an init has no systemd to act on, and every verb below is skipped rather than attempted.
kgsm_have_systemd() {
    [[ -d /run/systemd/system ]]
}

# Read newline-separated output into a named array, dropping blanks.
#
# ⚠ Never `mapfile < <(...)` or `while read; done < <(...)` here. Process substitution needs
# /dev/fd, which is a symlink to /proc/self/fd — and a pacman hook runs chrooted with no /proc
# mounted, so every such read silently yields nothing. Measured: the whole scan came back empty and
# the report announced that no KGSM packages were installed, on a node that had just installed ten.
# A here-string is a redirection from a temporary file and needs neither.
kgsm_read_lines() {
    local -n _out="$1"
    local _line
    _out=()
    [[ -n "$2" ]] || return 0
    while IFS= read -r _line; do
        [[ -n "$_line" ]] && _out+=("$_line")
    done <<< "$2"
}

kgsm_packages() {
    pacman -Qq 2>/dev/null | grep -E '^kgsm(-|$)' || true
}

# The units a package owns, with a socket preferred over the service of the same name: those two
# are one socket-activated unit, and enabling both defeats the activation.
kgsm_units_of() {
    local units=() u
    # The delimiter is # rather than | on purpose: with | as the delimiter, sed reads the \| of an
    # alternation as an escaped delimiter — a literal pipe — and the expression matches nothing at
    # all, silently. A drop-in directory (kgsm-api.service.d/) is excluded by [^/]+ needing the
    # whole remaining path.
    kgsm_read_lines units "$(pacman -Qlq "$1" 2>/dev/null |
        sed -nE 's#^/usr/lib/systemd/system/([^/]+\.(service|socket|timer))$#\1#p')"
    for u in "${units[@]}"; do
        if [[ "$u" == *.service ]] && printf '%s\n' "${units[@]}" | grep -qxF "${u%.service}.socket"; then
            continue
        fi
        printf '%s\n' "$u"
    done
}

kgsm_env_files_of() {
    pacman -Qlq "$1" 2>/dev/null | grep -E '^/etc/.*\.env$' || true
}

# Where a package leaves a credential it generated for a person to collect. Every unit carries
# StateDirectory=, so a package's state directory is /var/lib/<package> — the path follows from the
# name and no list of packages is kept here.
kgsm_admin_password_file() {
    printf '/var/lib/%s/initial-admin-password' "$1"
}

# The keys in an env file that only a person can supply. A bare `KEY=` or a YOUR_..._HERE
# placeholder is a value the package deliberately ships unset; anything a leaf runs perfectly well
# without — an optional setting, or a secret the leaf generates for itself on first start — is
# commented out in its example instead, so a blank key here means the leaf is waiting on a person.
kgsm_missing_keys() {
    [[ -f "$1" ]] || return 0
    sed -n \
        -e 's/^\([A-Za-z_][A-Za-z0-9_]*\)=[[:space:]]*$/\1/p' \
        -e 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*YOUR_[A-Z0-9_]*_HERE.*$/\1/p' \
        "$1"
}

# ── the scan ──────────────────────────────────────────────────────────────────
#
# kgsm_scan fills these. A unit lands in exactly one bucket:
#
#   KGSM_READY    enabled, and its package's env file holds nothing outstanding — safe to start
#   KGSM_BLOCKED  enabled, but a key in its own env file is still blank
#   KGSM_OPTIN    the preset policy leaves it disabled; installing it was not choosing to run it
#
# KGSM_WAITING holds "<envfile>|<keys>" for every file with outstanding keys, and KGSM_ADVISORY the
# same for a package that owns no unit — the shared sign-in file is the whole of that case, and
# nothing is held up by it.
#
# KGSM_HANDOFF holds "<file>|<package>" for a credential a package generated and left for a person
# to collect. It blocks nothing: the unit that wrote it is running.

KGSM_PKGS=()
KGSM_READY=()
KGSM_BLOCKED=()
KGSM_OPTIN=()
KGSM_WAITING=()
KGSM_ADVISORY=()
KGSM_HANDOFF=()
# shellcheck disable=SC2034  # read by whatever sourced this, which shellcheck cannot see
declare -A KGSM_UNIT_PKG=()

kgsm_scan() {
    KGSM_PKGS=() KGSM_READY=() KGSM_BLOCKED=() KGSM_OPTIN=() KGSM_WAITING=() KGSM_ADVISORY=()
    KGSM_HANDOFF=()
    KGSM_UNIT_PKG=()

    local pkg envfile keys unit incomplete policy pwfile
    local pkgs=() units=() envfiles=()

    kgsm_read_lines pkgs "$(kgsm_packages)"

    for pkg in "${pkgs[@]}"; do
        KGSM_PKGS+=("$pkg")

        kgsm_read_lines units "$(kgsm_units_of "$pkg")"
        kgsm_read_lines envfiles "$(kgsm_env_files_of "$pkg")"

        incomplete=0
        for envfile in "${envfiles[@]}"; do
            keys="$(kgsm_missing_keys "$envfile" | tr '\n' ' ')"
            keys="${keys%"${keys##*[![:space:]]}"}"
            [[ -n "$keys" ]] || continue
            if (( ${#units[@]} )); then
                KGSM_WAITING+=("${envfile}|${keys}")
                incomplete=1
            else
                # A package with no unit holds nothing up. /etc/kgsm/kgsm-auth.env is this case:
                # the shared sign-in application, which a host signing people in with passwords
                # alone never needs.
                KGSM_ADVISORY+=("${envfile}|${keys}")
            fi
        done

        # A password the package minted for the first person to sign in. It exists only between the
        # first start that created that account and the person collecting it, so its presence is the
        # whole signal — on a node past that point there is no file and the report says nothing.
        pwfile="$(kgsm_admin_password_file "$pkg")"
        if [[ -f "$pwfile" ]]; then
            KGSM_HANDOFF+=("${pwfile}|${pkg}")
        fi

        for unit in "${units[@]}"; do
            policy="$(kgsm_unit_policy "$unit")"
            [[ -n "$policy" ]] || continue
            # shellcheck disable=SC2034  # read by whatever sourced this, which shellcheck cannot see
            KGSM_UNIT_PKG["$unit"]="$pkg"
            if [[ "$policy" == "off" ]]; then
                KGSM_OPTIN+=("$unit")
            elif (( incomplete )); then
                KGSM_BLOCKED+=("$unit")
            else
                KGSM_READY+=("$unit")
            fi
        done
    done
}
