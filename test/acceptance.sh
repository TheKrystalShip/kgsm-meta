#!/usr/bin/env bash
#
# acceptance.sh — prove that a fresh Arch host becomes a running KGSM node with nothing but the
# commands the README gives a person.
#
#   test/acceptance.sh                  # build the workspace's packages, then test
#   test/acceptance.sh --repo <dir>     # test a repository directory that already exists
#   test/acceptance.sh --published      # test the PUBLISHED repository on GitHub Releases —
#                                       # the key and every package fetched from the release,
#                                       # exactly the path a real node takes
#   test/acceptance.sh --keep           # leave the container up for inspection
#
# The install block is EXTRACTED FROM README.md and run as it is written, so a README that drifts
# from what works fails this test rather than a copy of it kept here. `--published` runs it verbatim;
# the local modes rewrite the release URL to the file:// repository under test, which changes where
# packages come from and nothing about how they are verified.
#
# What it asserts, in an Arch container running real systemd as PID 1:
#
#   * the [kgsm] database and every package verify against the packaging key, at
#     SigLevel = Required DatabaseRequired — the same enforcement a real node runs under
#   * `pacman -S` of the whole kgsm-node group leaves the ready units ACTIVE with nothing else run
#   * exactly one unit is blocked, on exactly one key: kgsm-bot on Discord__Token
#   * kgsm-api minted its own signing key and its first administrator, both 0600
#   * that administrator can sign in with the password in the file
#
# Requirements: docker usable WITHOUT sudo, and this checkout sitting in the tks workspace so
# scripts/publish-repo.sh can build the package set. The packaging key's secret half is needed —
# the database is signed with the same key the node trusts, so this exercises signature enforcement
# rather than stepping around it with SigLevel = Never.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${HERE}/../.." && pwd)"
README="${HERE}/../README.md"
IMAGE="archlinux:base"
CONTAINER="kgsm-acceptance"

log()  { printf '\033[1;34m>> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m** %s\033[0m\n' "$*" >&2; }
err()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; }
note() { printf '   %s\n' "$*"; }

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '   \033[1;32mPASS\033[0m  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '   \033[1;31mFAIL\033[0m  %s\n' "$*"; }
info() { printf '   \033[1;36mNOTE\033[0m  %s\n' "$*"; }

# expect <measured> <wanted> <what it means>. Reporting the measurement on failure is the point:
# "kgsm-api.service is failed, wanted active" is a diagnosis; "assertion 7 failed" is not.
expect() {
    if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 — measured '${1:-nothing}', wanted '$2'"; fi
}

REPO_DIR=""
PUBLISHED=0
KEEP=0
while (( $# )); do
    case "$1" in
        --repo) REPO_DIR="$2"; shift 2 ;;
        --published) PUBLISHED=1; shift ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '3,32p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) err "unknown option: $1"; exit 1 ;;
    esac
done
(( PUBLISHED )) && [[ -n "$REPO_DIR" ]] && { err "--published and --repo are mutually exclusive"; exit 1; }

docker info >/dev/null 2>&1 || {
    err "docker is not usable by this account"
    err "this test needs a container running real systemd; there is no unprivileged substitute"
    exit 1
}

# ---------------------------------------------------------------------------- the documented block
#
# The README marks the block a person is told to run with an HTML comment, and everything between
# the next pair of fences is it. Extracting rather than restating is the whole point: the test can
# only pass against a README that still works.

RELEASE_URL="https://github.com/TheKrystalShip/kgsm-meta/releases/download/repo"
MARKER='<!-- node-install -->'

INSTALL_BLOCK="$(awk -v marker="$MARKER" '
    $0 == marker { found = 1; next }
    found && /^```/ { if (inblock) exit; inblock = 1; next }
    inblock { print }
' "$README")"

[[ -n "$INSTALL_BLOCK" ]] || {
    err "no install block in ${README} — expected a fenced block after ${MARKER}"
    exit 1
}
grep -q "$RELEASE_URL" <<< "$INSTALL_BLOCK" || {
    err "the README's install block does not name ${RELEASE_URL}"
    exit 1
}

# ------------------------------------------------------------------------------- the repository

# --published needs no repository on disk: the container fetches the key and every package from the
# release over TLS, the same way a real node does.
if (( ! PUBLISHED )) && [[ -z "$REPO_DIR" ]]; then
    log "building the workspace's packages into a local repository"
    out="$("${WORKSPACE}/scripts/publish-repo.sh" --dry-run --keep 2>&1)" || {
        printf '%s\n' "$out" | tail -30 >&2
        err "the package build failed"
        exit 1
    }
    REPO_DIR="$(printf '%s\n' "$out" | sed -n 's/.*staging kept at \(.*\)\x1b.*/\1/p' | tail -1)"
    [[ -d "$REPO_DIR" ]] || { err "could not find the staging directory publish-repo.sh kept"; exit 1; }
fi

if (( PUBLISHED )); then
    log "repository: ${RELEASE_URL} (published)"
    SOURCE_URL="$RELEASE_URL"
else
    [[ -f "${REPO_DIR}/kgsm.db" ]] || { err "${REPO_DIR} holds no kgsm.db"; exit 1; }
    log "repository: ${REPO_DIR}"
    SOURCE_URL="file:///srv/kgsm"

    # pacman downloads as an unprivileged user (`alpm`), even over file://. A directory mktemp made
    # is 0700 and owned by a uid the container does not have, so the sync fails with "Could not open
    # file" and nothing says why. World-readable is what a served repository is anyway.
    chmod -R a+rX "$REPO_DIR"
fi

# One substitution covers both places the URL appears — the key fetched with curl, which reads
# file:// too, and the Server line pacman is given.
INSTALL_SCRIPT="${INSTALL_BLOCK//${RELEASE_URL}/${SOURCE_URL}}"

# The one thing this changes about the commands themselves. pacman asks a person to confirm the
# transaction and treats an unanswerable prompt as a refusal — measured: it exits 1 with the answer
# unread — so a `pacman -S…` line needs --noconfirm to mean the same thing with nobody at the
# keyboard. Nothing else is rewritten; the block is otherwise run as it is written.
INSTALL_SCRIPT="$(sed -E 's/^(pacman -S[a-z]*)( |$)/\1 --noconfirm\2/' <<< "$INSTALL_SCRIPT")"

# ---------------------------------------------------------------------------------- the container

cleanup() {
    if (( KEEP )); then
        warn "container ${CONTAINER} left running — remove it with: docker rm -f ${CONTAINER}"
        return
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1
}
trap cleanup EXIT

docker rm -f "$CONTAINER" >/dev/null 2>&1

log "booting ${IMAGE} with systemd as PID 1"
# --cgroupns=private is not a detail: it gives the container its own cgroup root, so a privileged
# init in here cannot see or act on the host's kgsm.slice and the game servers under it.
MOUNT=()
(( ! PUBLISHED )) && MOUNT=(-v "${REPO_DIR}:/srv/kgsm:ro")
docker run -d --name "$CONTAINER" \
    --privileged --cgroupns=private --stop-signal SIGRTMIN+3 \
    --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
    "${MOUNT[@]}" \
    "$IMAGE" /usr/lib/systemd/systemd >/dev/null || { err "the container did not start"; exit 1; }

for _ in $(seq 1 60); do
    state="$(docker exec "$CONTAINER" systemctl is-system-running 2>/dev/null)"
    [[ "$state" == running || "$state" == degraded ]] && break
    sleep 1
done
[[ -n "${state:-}" ]] || { err "systemd never came up in the container"; exit 1; }
log "systemd is ${state}"
# The image's own systemd-firstboot.service fails in a container and has nothing to do with KGSM.
# Record the baseline so a later failure is read against it rather than against zero.
baseline="$(docker exec "$CONTAINER" systemctl list-units --state=failed --no-legend --plain \
    | awk '{print $1}' | paste -sd' ')"
note "failed before installing anything: ${baseline:-none}"

# ------------------------------------------------------------------------------------- the install

INSTALLLOG="$(mktemp /tmp/kgsm-acceptance-install.XXXXXX.log)"

log "running the README's install block"
# `set -euo pipefail` is the test's, not the README's: a person watching a terminal sees a failing
# command and stops, and this is how a script gets the same answer.
#
# It is written to a file and run from there rather than piped into `bash -s`, so that the block's
# own commands keep a stdin of their own — `pacman-key --add -` reads the key off a pipe, and a
# script that IS stdin leaves them reading the rest of itself.
{
    printf 'set -euo pipefail\n'
    printf '%s\n' "$INSTALL_SCRIPT"
} | docker exec -i "$CONTAINER" tee /tmp/kgsm-install.sh >/dev/null
docker exec "$CONTAINER" bash /tmp/kgsm-install.sh >"$INSTALLLOG" 2>&1
install_rc=$?

if (( install_rc == 0 )); then
    # The README's second command, with the prompt answered the only way a script can: pacman's own
    # default for a group selection is every member, so --noconfirm installs all of kgsm-node.
    log "installing the kgsm-node group"
    docker exec "$CONTAINER" pacman -S --noconfirm kgsm-node >>"$INSTALLLOG" 2>&1
    install_rc=$?
fi

# A .NET service takes a moment to bind; asserting the instant the transaction returns would measure
# start-up latency rather than whether the node works.
log "letting the units settle"
for _ in $(seq 1 45); do
    docker exec "$CONTAINER" systemctl is-active kgsm-api.service >/dev/null 2>&1 && break
    sleep 2
done

# ------------------------------------------------------------------------------------ assertions

echo
log "results"

expect "$install_rc" 0 "the README's commands exit 0"

# The signature path. A database that verified is the whole reason the packages could install.
if docker exec "$CONTAINER" grep -q 'SigLevel = Required DatabaseRequired' /etc/pacman.conf; then
    ok "[kgsm] is configured SigLevel = Required DatabaseRequired"
else
    bad "[kgsm] is not configured Required DatabaseRequired"
fi

# Every unit 50-kgsm.preset enables and no credential blocks. kgsm-net-meter is deliberately absent:
# it needs kernel facilities a container may not have, and is measured below instead of asserted.
READY=(
    kgsm-watchdog.service
    kgsm-monitor.service
    kgsm-scheduler.service
    kgsm-reactor.service
    kgsm-journal-prune.timer
    kgsm-api.service
    kgsm-assistant-service.service
    kgsm-firewall.socket
    kgsm-speech.socket
)
for u in "${READY[@]}"; do
    expect "$(docker exec "$CONTAINER" systemctl is-active "$u" 2>/dev/null)" active "${u} is active"
done

# The one unit a person still owes something to. Enabled, so it comes up on the next boot once the
# token is set; stopped, because the hook refuses to start a unit whose env file has an unset key.
expect "$(docker exec "$CONTAINER" systemctl is-active  kgsm-bot.service 2>/dev/null)" inactive \
       "kgsm-bot.service is stopped — blocked on its token"
expect "$(docker exec "$CONTAINER" systemctl is-enabled kgsm-bot.service 2>/dev/null)" enabled \
       "kgsm-bot.service is enabled — it comes up once the token is set"

# Opt-in stays off. A preset decision, not a default.
expect "$(docker exec "$CONTAINER" systemctl is-active kgsm-rag-indexer.service 2>/dev/null)" inactive \
       "kgsm-rag-indexer.service is not running — opt-in, and the group does not carry it"

# The report a person reads. It must name exactly one outstanding key, and it must be the one no
# host can invent.
status="$(docker exec "$CONTAINER" kgsm-node-status 2>&1)"
keys="$(printf '%s\n' "$status" | sed -n '/Blocked/,/Set only if/p' | grep -oE '\b[A-Za-z]+__[A-Za-z_]+\b' | sort -u | paste -sd' ')"
expect "$keys" "Discord__Token" "kgsm-node-status blocks on exactly one key"

# What the packages minted for themselves, and the modes they minted it at. A key or a password that
# exists world-readable was never secret, whatever it is used for afterwards.
check_mode() {
    local path="$1" want="$2" label="$3" mode
    mode="$(docker exec "$CONTAINER" stat -c '%a' "$path" 2>/dev/null)"
    if [[ -z "$mode" ]]; then bad "${label}: ${path} does not exist"
    elif [[ "$mode" == "$want" ]]; then ok "${label}: ${path} is ${mode}"
    else bad "${label}: ${path} is ${mode}, expected ${want}"
    fi
}
check_mode /var/lib/kgsm-api/initial-admin-password 600 "the first administrator's password"
check_mode /var/lib/kgsm-api/signing-key            600 "kgsm-api's self-minted signing key"
check_mode /var/lib/kgsm-assistant/signing-key      600 "the assistant's self-minted signing key"

# The reactor's rules, which exist nowhere in its code: the package ships them beside the binary and
# the leaf installs them into its own state directory the first time it starts. A node that came up
# judging nothing would look identical to one that came up correctly until something crashed.
shipped="$(docker exec "$CONTAINER" sh -c 'ls /opt/kgsm-reactor/rules.d/*.json 2>/dev/null | wc -l')"
running="$(docker exec "$CONTAINER" sh -c 'ls /var/lib/kgsm-reactor/rules.d/*.json 2>/dev/null | wc -l')"
if [[ "${shipped:-0}" -gt 0 && "$running" == "$shipped" ]]; then
    ok "the reactor installed its ${shipped} shipped rule(s) on first start"
else
    bad "the reactor ships ${shipped:-0} rule(s) and is running ${running:-0}"
fi

# And is actually judging by them, rather than holding files it refused. `problems` is the leaf's own
# word for a rule it could not honour, so an empty one is the only clean answer.
refused="$(docker exec "$CONTAINER" curl -s --unix-socket /run/kgsm-reactor/status.sock \
    http://localhost/status 2>/dev/null | grep -o '"problems":\[[^]]*\]')"
expect "$refused" '"problems":[]' "the reactor honoured every rule it installed"

# The handoff, end to end: the password in that file signs the account in that file in.
user="$(docker exec "$CONTAINER" sed -n 's/^username: *//p' /var/lib/kgsm-api/initial-admin-password 2>/dev/null)"
pass="$(docker exec "$CONTAINER" sed -n 's/^password: *//p' /var/lib/kgsm-api/initial-admin-password 2>/dev/null)"
if [[ -n "$user" && -n "$pass" ]]; then
    code="$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' \
        -X POST http://127.0.0.1:8080/auth/login -H 'Content-Type: application/json' \
        -d "{\"username\":\"${user}\",\"password\":\"${pass}\"}" 2>/dev/null)"
    expect "$code" 200 "'${user}' signs in with the password from the file"
else
    bad "could not read a username and password out of the initial-admin-password file"
fi

# ------------------------------------------------------------------- measured, and not asserted
#
# Where kgsm-keyring came from. Nothing installs it by name — a repository whose kgsm-base declares
# the dependency delivers it, and an older one does not — so this is reported rather than asserted,
# and the report says which of the two the run was against.
reason="$(docker exec "$CONTAINER" bash -c \
    "pacman -Qi kgsm-keyring 2>/dev/null | sed -n 's/^Install Reason *: *//p'")"
if [[ -n "$reason" ]]; then
    info "kgsm-keyring is installed (${reason}) — no command named it"
else
    info "kgsm-keyring is not installed — this repository's kgsm-base does not depend on it"
fi

# The network meter loads an eBPF program and attaches it to a cgroup. A container may or may not
# have what that needs, and forcing it to pass would turn a real prerequisite into a hidden one.
# Report what happened and why instead.
s="$(docker exec "$CONTAINER" systemctl is-active kgsm-net-meter.service 2>/dev/null)"
if [[ "$s" == active ]]; then
    # Its first pass fails: attaching needs /sys/fs/cgroup/kgsm.slice, and being ordered after
    # kgsm-watchdog.service is not the same as after the slice the watchdog creates at runtime. Say
    # how many passes it took rather than quoting that first failure as if it were the outcome.
    tries="$(docker exec "$CONTAINER" journalctl -u kgsm-net-meter.service --no-pager -o cat 2>/dev/null \
        | grep -c '^>> attaching ingress')"
    info "kgsm-net-meter.service is active — eBPF program attached (${tries:-0} successful pass(es))"
else
    nm_reason="$(docker exec "$CONTAINER" journalctl -u kgsm-net-meter.service --no-pager -o cat 2>/dev/null \
        | grep '!!' | tail -1 | sed 's/^!! *//')"
    info "kgsm-net-meter.service is ${s:-unknown}${nm_reason:+ — ${nm_reason}}"
fi

now_failed="$(docker exec "$CONTAINER" systemctl list-units --state=failed --no-legend --plain \
    | awk '{print $1}' | paste -sd' ')"
info "failed units now: ${now_failed:-none} (baseline: ${baseline:-none})"
info "packages installed: $(docker exec "$CONTAINER" bash -c "pacman -Qq | grep -cE '^(kgsm|libdave)'")"

echo
printf '%s\n' "$status"
echo
if (( FAIL )); then
    err "${FAIL} failed, ${PASS} passed"
    note "install output: ${INSTALLLOG}"
    exit 1
fi
log "all ${PASS} checks passed"
