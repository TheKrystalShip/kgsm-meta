#!/usr/bin/env bash
#
# rehearse-migration.sh — run migrate/checkout-to-packages.sh against a copy of a checkout-deployed host,
# in an Arch container under real systemd, and prove nothing established was lost.
#
#   test/rehearse-migration.sh           # build the "before" host, migrate it, assert
#   test/rehearse-migration.sh --keep    # leave the container up for inspection
#
# The "before" host is built from THIS machine's own deploy, not from a description of it: the engine
# and the components' trees under /opt, their units as setup.sh wrote them, run as a user `heisen` with
# the engine's data in that user's home and the library at /opt. It then lives a little — the anchor
# founds its cluster and makes its administrator, the node joins it, a Factorio server is installed in
# the current layout and left running, and a copy of this machine's Necesse sits in the legacy layout.
# What it proves is continuity: the same signing key, the same accounts, a session signed before still
# accepted after, the same instances in the new library and startable, and the operator's settings kept.
#
# Packages come from the published [kgsm] repository, which is what the real migration installs.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META="$(cd "${HERE}/.." && pwd)"
IMAGE="archlinux:base"
CONTAINER="kgsm-rehearsal"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

log()  { printf '\033[1;34m>> %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; }
note() { printf '   %s\n' "$*"; }
PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '   \033[1;32mPASS\033[0m  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '   \033[1;31mFAIL\033[0m  %s\n' "$*"; }
expect() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 — measured '${1:-nothing}', wanted '$2'"; fi; }

in_c()   { docker exec "$CONTAINER" "$@"; }
as_heisen() { docker exec "$CONTAINER" runuser -u heisen -- env HOME=/home/heisen "$@"; }
as_kgsm()   { docker exec "$CONTAINER" runuser -u kgsm -- env HOME=/var/lib/kgsm "$@"; }

cleanup() {
    (( KEEP )) && { printf '** container %s left running\n' "$CONTAINER"; return; }
    docker rm -f "$CONTAINER" >/dev/null 2>&1
}
trap cleanup EXIT
docker rm -f "$CONTAINER" >/dev/null 2>&1

# ── the machine ───────────────────────────────────────────────────────────────────────────────────
log "booting ${IMAGE} with systemd as PID 1"
docker run -d --name "$CONTAINER" --privileged --cgroupns=private --stop-signal SIGRTMIN+3 \
    --tmpfs /tmp --tmpfs /run --tmpfs /run/lock "$IMAGE" /usr/lib/systemd/systemd >/dev/null \
    || { err "the container did not start"; exit 1; }
for _ in $(seq 1 60); do
    state="$(in_c systemctl is-system-running 2>/dev/null)"
    [[ "$state" == running || "$state" == degraded ]] && break
    sleep 1
done

log "configuring the [kgsm] repository and the runtime the deployed binaries need"
docker exec -i "$CONTAINER" tee /tmp/setup-node.sh >/dev/null < "${META}/setup-node.sh"
in_c bash /tmp/setup-node.sh --no-upgrade </dev/null >/dev/null 2>&1 || { err "setup-node.sh failed"; exit 1; }
in_c pacman -Sy --noconfirm --needed bash grep sed gawk findutils coreutils go-yq jq curl wget tar unzip rsync \
    iproute2 lsof openssl procps-ng diffutils sqlite acl aspnet-runtime polkit sudo >/dev/null 2>&1 \
    || { err "installing the runtime failed"; exit 1; }

# ── the "before" host: this machine's checkout deploy, as the user who deployed it ─────────────────
log "copying this machine's checkout deploy in"
in_c useradd -m -u 1000 -s /bin/bash heisen
in_c install -d -o heisen -g heisen /opt
for tree in kgsm kgsm-api kgsm-auth-anchor kgsm-watchdog kgsm-monitor kgsm-scheduler kgsm-reactor; do
    docker cp "/opt/${tree}" "${CONTAINER}:/opt/${tree}" >/dev/null
    in_c chown -R heisen:heisen "/opt/${tree}"
done
in_c ln -sf /opt/kgsm/kgsm.sh /usr/bin/kgsm
for proj in kgsm-api kgsm-auth-anchor kgsm-watchdog kgsm-monitor kgsm-scheduler kgsm-reactor; do
    in_c install -d -o heisen -g heisen "/etc/${proj}/systemd"
    for unit in "/etc/${proj}/systemd"/*; do
        docker cp "$unit" "${CONTAINER}:${unit}" >/dev/null
        in_c ln -sf "$unit" "/etc/systemd/system/$(basename "$unit")"
    done
done
in_c chown -R heisen:heisen /etc/kgsm-api /etc/kgsm-auth-anchor /etc/kgsm-watchdog /etc/kgsm-monitor \
    /etc/kgsm-scheduler /etc/kgsm-reactor

# The operator's settings: a secret this machine founded its cluster with, and a sentinel value the
# migration must keep.
SECRET="rehearsal-cluster-secret-0123456789abcdef"
in_c install -d /etc/kgsm /var/lib/kgsm /var/lib/kgsm/auth /var/lib/kgsm/cluster
in_c sh -c "printf 'Cluster__Secret=%s\n' '$SECRET' > /etc/kgsm/kgsm-cluster.env; : > /etc/kgsm/kgsm-auth.env"
in_c sh -c "printf '%s\n' '$SECRET' | sha256sum | cut -d' ' -f1 > /etc/kgsm/cluster-founded"
in_c sh -c "printf 'Api__Urls=http://127.0.0.1:8080\nApi__PublicHost=rehearsal-sentinel.example\n' > /etc/kgsm-api/kgsm-api.env"
in_c sh -c "printf 'Anchor__ListenAddress=http://127.0.0.1:8098\nAnchor__Issuer=http://127.0.0.1:8098\n' > /etc/kgsm-auth-anchor/kgsm-auth-anchor.env"
in_c chown -R heisen:heisen /var/lib/kgsm/auth /var/lib/kgsm/cluster
in_c chmod 700 /var/lib/kgsm/auth

log "starting the before host"
in_c systemctl daemon-reload
in_c systemctl start kgsm-watchdog kgsm-auth-anchor kgsm-api kgsm-monitor kgsm-scheduler kgsm-reactor
for _ in $(seq 1 60); do
    in_c test -f /var/lib/kgsm-auth-anchor/initial-admin-password && in_c curl -fsS -o /dev/null http://127.0.0.1:8080/health && break
    sleep 2
done

# The library where this machine keeps it: /opt, owned by the deploying user.
as_heisen kgsm libraries list >/dev/null 2>&1
as_heisen kgsm libraries remove default >/dev/null 2>&1
as_heisen kgsm libraries add /opt --name default >/dev/null 2>&1
as_heisen kgsm config set default_library=default >/dev/null 2>&1

log "installing a Factorio server and copying this machine's Necesse in the legacy layout"
as_heisen kgsm install factorio --id factorio >/dev/null 2>&1 || err "installing factorio failed"
docker cp /opt/necesse "${CONTAINER}:/opt/necesse" >/dev/null
docker cp /home/heisen/.local/share/kgsm/instances/necesse "${CONTAINER}:/home/heisen/.local/share/kgsm/instances/necesse" >/dev/null
in_c install -d /home/heisen/.local/share/kgsm/backups/necesse /home/heisen/.local/bin
in_c ln -s /opt/necesse/necesse/necesse.manage.sh /home/heisen/.local/bin/necesse
in_c chown -R heisen:heisen /opt/necesse /home/heisen/.local
as_heisen kgsm start factorio >/dev/null 2>&1

# ── what must survive ─────────────────────────────────────────────────────────────────────────────
log "recording what the migration must keep"
before_instances="$(as_heisen kgsm instances list 2>/dev/null | sort | tr '\n' ' ')"
before_running="$(as_heisen kgsm instances status factorio 2>/dev/null | grep -c 'Status:.*Active')"
before_kid="$(in_c curl -s http://127.0.0.1:8098/auth/cluster/public-key | jq -r '.keys[0].kid')"
admin_user="$(in_c sed -n 's/^username: *//p' /var/lib/kgsm-auth-anchor/initial-admin-password)"
admin_pass="$(in_c sed -n 's/^password: *//p' /var/lib/kgsm-auth-anchor/initial-admin-password)"
before_token="$(in_c curl -s -X POST http://127.0.0.1:8098/auth/sign-in -H 'Content-Type: application/json' \
    -d "{\"username\":\"${admin_user}\",\"password\":\"${admin_pass}\"}" | jq -r '.token // empty')"
before_secret="$(in_c sha256sum /etc/kgsm/kgsm-cluster.env | cut -d' ' -f1)"
note "instances: ${before_instances}"
note "factorio running: ${before_running}; anchor kid: ${before_kid}; admin: ${admin_user}"
[[ -n "$before_token" && -n "$before_kid" && "$before_instances" == *factorio* && "$before_instances" == *necesse* ]] \
    || { err "the before host did not come up far enough to rehearse against"; exit 1; }

# ── the migration ─────────────────────────────────────────────────────────────────────────────────
log "running the migration"
in_c install -d /root/migrate
docker cp "${META}/migrate/checkout-to-packages.sh" "${CONTAINER}:/root/migrate/checkout-to-packages.sh" >/dev/null
MIGRATION_LOG="$(mktemp /tmp/kgsm-rehearsal-migration.XXXXXX.log)"
in_c bash /root/migrate/checkout-to-packages.sh --from-user heisen all >"$MIGRATION_LOG" 2>&1
migration_rc=$?
sed 's/\x1b\[[0-9;]*m//g' "$MIGRATION_LOG" | grep -E '^(>>|!!|\*\*)' | sed 's/^/   /'

# ── after ─────────────────────────────────────────────────────────────────────────────────────────
echo
log "results"
expect "$migration_rc" 0 "the migration exits 0"

for unit in kgsm-watchdog kgsm-auth-anchor kgsm-api kgsm-monitor kgsm-scheduler kgsm-reactor; do
    expect "$(in_c systemctl is-active "${unit}.service")" active "${unit} is active"
    expect "$(in_c systemctl show "${unit}.service" -p User --value):$(in_c systemctl show "${unit}.service" -p FragmentPath --value | cut -d/ -f1-4)" \
        "kgsm:/usr/lib/systemd" "${unit} is the packaged unit, running as kgsm"
done

expect "$(in_c sha256sum /etc/kgsm/kgsm-cluster.env | cut -d' ' -f1)" "$before_secret" "the cluster secret is the one this host founded with"
expect "$(in_c grep -c '^Api__PublicHost=rehearsal-sentinel.example$' /etc/kgsm-api/kgsm-api.env)" 1 "the operator's settings are kept"

after_kid=""
for _ in $(seq 1 30); do
    after_kid="$(in_c curl -s http://127.0.0.1:8098/auth/cluster/public-key | jq -r '.keys[0].kid // empty')"
    [[ -n "$after_kid" ]] && break
    sleep 2
done
expect "$after_kid" "$before_kid" "the anchor signs with the same key"
code="$(in_c curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8098/auth/sign-in -H 'Content-Type: application/json' \
    -d "{\"username\":\"${admin_user}\",\"password\":\"${admin_pass}\"}")"
expect "$code" 200 "the administrator signs in with the same password"
tier=""
for _ in $(seq 1 30); do
    tier="$(in_c curl -s http://127.0.0.1:8080/api/v1/me -H "Authorization: Bearer ${before_token}" | jq -r '.tier // empty')"
    [[ "$tier" == admin ]] && break
    sleep 2
done
expect "$tier" admin "a session signed before the migration is accepted after it"

expect "$(as_kgsm kgsm instances list 2>/dev/null | sort | tr '\n' ' ')" "$before_instances" "every instance is still there"
root="$(as_kgsm kgsm libraries list --json 2>/dev/null | jq -r '.[] | select(.name=="default") | .path')"
expect "$root" /var/lib/kgsm/.local/share/kgsm/library "the default library is in the kgsm account's home"
expect "$(as_kgsm kgsm config get default_library 2>/dev/null)" default "new installs are placed in it"
for inst in factorio necesse; do
    cfg="$(as_kgsm kgsm instances find "$inst" 2>/dev/null | tail -n1)"
    wd="$(in_c sed -n 's/^working_dir="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$cfg" 2>/dev/null)"
    [[ "$wd" == /var/lib/kgsm/.local/share/kgsm/library/* ]] && ok "${inst} lives in the new library (${wd})" || bad "${inst} working_dir is '${wd}'"
    homes="$(in_c grep -c '/home/heisen' "$cfg" 2>/dev/null)"
    expect "${homes:-0}" 0 "${inst}'s config names nothing under the old home"
done
expect "$(as_kgsm kgsm instances status factorio 2>/dev/null | grep -c 'Status:.*Active')" "$before_running" "factorio runs again, as it did before"
as_kgsm kgsm stop factorio >/dev/null 2>&1
as_kgsm kgsm start factorio >/dev/null 2>&1
expect "$(as_kgsm kgsm instances status factorio 2>/dev/null | grep -c 'Status:.*Active')" 1 "factorio stops and starts as kgsm"

expect "$(in_c test -e /home/heisen/.local/share/kgsm && echo left || echo gone)" gone "the old home holds no engine data"
owned="$(in_c find /var/lib/kgsm /var/lib/kgsm-auth-anchor /var/lib/kgsm-api /var/lib/kgsm-watchdog -user heisen 2>/dev/null | head -3 | tr '\n' ' ')"
expect "$owned" "" "nothing under the state tree belongs to the old user"
expect "$(in_c sh -c 'ls /etc/systemd/system/kgsm-* 2>/dev/null' | wc -l)" 0 "no checkout unit remains in /etc/systemd/system"

echo
if (( FAIL )); then
    err "${FAIL} failed, ${PASS} passed — migration log: ${MIGRATION_LOG}"
    exit 1
fi
log "all ${PASS} checks passed — migration log: ${MIGRATION_LOG}"
