#!/usr/bin/env bash
#
# acceptance.sh — prove that a fresh Arch host becomes a running KGSM node with no command but
# bootstrap.sh.
#
#   test/acceptance.sh                  # build the workspace's packages, then test
#   test/acceptance.sh --repo <dir>     # test a repository directory that already exists
#   test/acceptance.sh --keep           # leave the container up for inspection
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
KEEP=0
while (( $# )); do
    case "$1" in
        --repo) REPO_DIR="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '3,25p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) err "unknown option: $1"; exit 1 ;;
    esac
done

docker info >/dev/null 2>&1 || {
    err "docker is not usable by this account"
    err "this test needs a container running real systemd; there is no unprivileged substitute"
    exit 1
}

# ------------------------------------------------------------------------------- the repository

if [[ -z "$REPO_DIR" ]]; then
    log "building the workspace's packages into a local repository"
    out="$("${WORKSPACE}/scripts/publish-repo.sh" --dry-run --keep 2>&1)" || {
        printf '%s\n' "$out" | tail -30 >&2
        err "the package build failed"
        exit 1
    }
    REPO_DIR="$(printf '%s\n' "$out" | sed -n 's/.*staging kept at \(.*\)\x1b.*/\1/p' | tail -1)"
    [[ -d "$REPO_DIR" ]] || { err "could not find the staging directory publish-repo.sh kept"; exit 1; }
fi

[[ -f "${REPO_DIR}/kgsm.db" ]] || { err "${REPO_DIR} holds no kgsm.db"; exit 1; }
log "repository: ${REPO_DIR}"

# pacman downloads as an unprivileged user (`alpm`), even over file://. A directory mktemp made is
# 0700 and owned by a uid the container does not have, so the sync fails with "Could not open file"
# and nothing says why. World-readable is what a served repository is anyway.
chmod -R a+rX "$REPO_DIR"

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
docker run -d --name "$CONTAINER" \
    --privileged --cgroupns=private --stop-signal SIGRTMIN+3 \
    --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
    -v "${REPO_DIR}:/srv/kgsm:ro" \
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

# ------------------------------------------------------------------------------------- bootstrap

log "running bootstrap.sh against the local repository"
docker exec -e KGSM_REPO_URL=file:///srv/kgsm "$CONTAINER" \
    bash /srv/kgsm/bootstrap.sh --all --start >"${REPO_DIR}/../acceptance-bootstrap.log" 2>&1
boot_rc=$?
BOOTLOG="${REPO_DIR}/../acceptance-bootstrap.log"
[[ -f "$BOOTLOG" ]] || BOOTLOG=/dev/null

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

expect "$boot_rc" 0 "bootstrap.sh exits 0"

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
    reason="$(docker exec "$CONTAINER" journalctl -u kgsm-net-meter.service --no-pager -o cat 2>/dev/null \
        | grep '!!' | tail -1 | sed 's/^!! *//')"
    info "kgsm-net-meter.service is ${s:-unknown}${reason:+ — ${reason}}"
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
    [[ "$BOOTLOG" != /dev/null ]] && note "bootstrap output: ${BOOTLOG}"
    exit 1
fi
log "all ${PASS} checks passed"
