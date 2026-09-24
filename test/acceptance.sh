#!/usr/bin/env bash
#
# acceptance.sh — prove that a fresh Arch host becomes a running KGSM node with nothing but the
# commands the README gives a person.
#
#   test/acceptance.sh                  # build the workspace's packages, then test
#   test/acceptance.sh --repo <dir>     # test a repository directory that already exists
#   test/acceptance.sh --published      # test the PUBLISHED repository on GitHub Releases — the
#                                       # script, the key and every package fetched over the network,
#                                       # exactly the path a real node takes
#   test/acceptance.sh --keep           # leave the container up for inspection
#
# The install block is EXTRACTED FROM README.md and run as it is written, so a README that drifts
# from what works fails this test rather than a copy of it kept here. That block fetches
# setup-node.sh and pipes it into a shell, so the script is under test with it: `--published` fetches
# it from the repository over TLS, and the local modes pipe in the checkout's copy and hand it
# KGSM_REPO_URL, which changes where packages come from and nothing about how they are verified.
#
# What it asserts, in an Arch container running real systemd as PID 1:
#
#   * the [kgsm] database and every package verify against the packaging key, at
#     SigLevel = Required DatabaseRequired — the same enforcement a real node runs under
#   * installing the kgsm-node group leaves the ready units ACTIVE with nothing else run
#   * exactly one unit is blocked, on exactly one key: kgsm-bot on Discord__Token
#   * the machine founded a cluster of its own: a generated secret, the founding record, and the auth
#     anchor switched on, holding the accounts, with its signing key and its first administrator's
#     one-time password both 0600
#   * the node joined that anchor with nobody signed in, and that administrator signs in at the anchor
#     with the password in the file
#   * given the operator's answer about the address, the node names the anchor as its sign-in provider
#     and the panel it serves is in the anchor's client registry without anybody entering it
#   * the API found every leaf this node installed WITHOUT being told where any of them is, and
#     reports the one it did not install as absent rather than as unreachable
#
# A few members are deliberately not installed — see SKIP_MEMBERS, which says why for each.
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
SCRIPT_URL="https://raw.githubusercontent.com/TheKrystalShip/kgsm-meta/main/setup-node.sh"
SETUP="${HERE}/../setup-node.sh"
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
grep -q "$SCRIPT_URL" <<< "$INSTALL_BLOCK" || {
    err "the README's install block does not name ${SCRIPT_URL}"
    exit 1
}

# The block fetches a script, so what the block does is what the script does. These two are the
# seam between them: a README pointing at a script that no longer names this repository, or a
# by-hand section quoting a fingerprint the script does not pin, is drift the test refuses.
[[ -f "$SETUP" ]] || { err "no ${SETUP}"; exit 1; }
grep -q "$RELEASE_URL" "$SETUP" || { err "setup-node.sh does not name ${RELEASE_URL}"; exit 1; }

SETUP_FPR="$(sed -n "s/^KEY_FINGERPRINT='\\([0-9A-F]*\\)'.*/\\1/p" "$SETUP")"
[[ -n "$SETUP_FPR" ]] || { err "no KEY_FINGERPRINT in setup-node.sh"; exit 1; }
grep -q "$SETUP_FPR" "$README" || {
    err "the README does not quote the fingerprint setup-node.sh pins (${SETUP_FPR})"
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

# The block fetches setup-node.sh over the network and pipes it into a shell. Locally, the checkout's
# copy is piped in instead — the same shape, because piping IS the thing under test: a script that is
# stdin leaves anything reading stdin eating the rest of itself, and this proves setup-node.sh does
# not. KGSM_REPO_URL is how the script is told which repository to use; nothing inside it is rewritten.
INSTALL_SCRIPT="$INSTALL_BLOCK"
if (( ! PUBLISHED )); then
    INSTALL_SCRIPT="${INSTALL_SCRIPT//curl -fsSL ${SCRIPT_URL}/cat /tmp/setup-node.sh}"
    INSTALL_SCRIPT="${INSTALL_SCRIPT//| sudo bash/| env KGSM_REPO_URL=${SOURCE_URL} bash}"
fi

# The container is PID-1 root and archlinux:base ships no sudo, so the one word a person needs and a
# root shell does not is dropped. Everything else about the line is run as it is written.
INSTALL_SCRIPT="${INSTALL_SCRIPT//| sudo bash/| bash}"

# The one thing this changes about the commands themselves. pacman asks a person to confirm the
# transaction and treats an unanswerable prompt as a refusal — measured: it exits 1 with the answer
# unread — so a `pacman -S…` line needs --noconfirm to mean the same thing with nobody at the
# keyboard. Nothing else is rewritten; the block is otherwise run as it is written.
INSTALL_SCRIPT="$(sed -E 's/^(pacman -S[a-z]*)( |$)/\1 --noconfirm\2/' <<< "$INSTALL_SCRIPT")"

# ---------------------------------------------------------------------------------- the container

# The second machine, used once the first is proven: a machine that founded its own cluster, joining the
# first one's.
JOINER="${CONTAINER}-joiner"

cleanup() {
    if (( KEEP )); then
        warn "containers ${CONTAINER} ${JOINER} left running — remove them with: docker rm -f ${CONTAINER} ${JOINER}"
        return
    fi
    docker rm -f "$CONTAINER" "$JOINER" >/dev/null 2>&1
}
trap cleanup EXIT

docker rm -f "$CONTAINER" "$JOINER" >/dev/null 2>&1

MOUNT=()
(( ! PUBLISHED )) && MOUNT=(-v "${REPO_DIR}:/srv/kgsm:ro")

# boot_node <container> — an Arch machine with systemd as PID 1, up and settled.
boot_node() {
    local name="$1" state=""
    log "booting ${IMAGE} as ${name} with systemd as PID 1"
    # --cgroupns=private is not a detail: it gives the container its own cgroup root, so a privileged
    # init in here cannot see or act on the host's kgsm.slice and the game servers under it.
    docker run -d --name "$name" \
        --privileged --cgroupns=private --stop-signal SIGRTMIN+3 \
        --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
        "${MOUNT[@]}" \
        "$IMAGE" /usr/lib/systemd/systemd >/dev/null || { err "${name} did not start"; exit 1; }

    for _ in $(seq 1 60); do
        state="$(docker exec "$name" systemctl is-system-running 2>/dev/null)"
        [[ "$state" == running || "$state" == degraded ]] && break
        sleep 1
    done
    [[ -n "$state" ]] || { err "systemd never came up in ${name}"; exit 1; }
    log "systemd is ${state} in ${name}"
}

boot_node "$CONTAINER"
# The image's own systemd-firstboot.service fails in a container and has nothing to do with KGSM.
# Record the baseline so a later failure is read against it rather than against zero.
baseline="$(docker exec "$CONTAINER" systemctl list-units --state=failed --no-legend --plain \
    | awk '{print $1}' | paste -sd' ')"
note "failed before installing anything: ${baseline:-none}"

# ------------------------------------------------------------------------------------- the install

# Members this suite does not install. None of them is skipped for being broken, and the exclusion is
# named out loud below rather than quietly narrowing what "the kgsm-node group" means:
#
#   kgsm-speech  pulls 813MB of models as a hard dependency, to serve recognition and synthesis a node
#                without a GPU cannot usefully run. Paying that download on every run buys nothing.
#   kgsm-llm     the assistant, exercised on the host that has the hardware for it; here it would only
#                re-prove what the leaf below proves better — that a leaf which is NOT installed is
#                reported absent.
#
# Their absence is itself under test: the API must report each as absent rather than as a leaf that is
# present and unreachable, which is the other half of the discovery this suite exists to check. The
# Control Panel is installed: the panel a node serves is a client of the cluster's sign-in provider, and
# its arriving in the provider's registry unasked is one of the things measured.
SKIP_MEMBERS=(kgsm-speech kgsm-llm)

# install_node <container> <log> — the README's install block, then the kgsm-node group less the members
# above. Returns the first failing step's status.
install_node() {
    local name="$1" logfile="$2" rc skip_re members
    log "running the README's install block on ${name}"
    # `set -euo pipefail` is the test's, not the README's: a person watching a terminal sees a failing
    # command and stops, and this is how a script gets the same answer.
    #
    # It is written to a file and run from there rather than piped into `bash -s`, so that the block's
    # own commands keep a stdin of their own — `pacman-key --add -` reads the key off a pipe, and a
    # script that IS stdin leaves them reading the rest of itself.
    (( PUBLISHED )) || docker exec -i "$name" tee /tmp/setup-node.sh >/dev/null < "$SETUP"
    {
        printf 'set -euo pipefail\n'
        printf '%s\n' "$INSTALL_SCRIPT"
    } | docker exec -i "$name" tee /tmp/kgsm-install.sh >/dev/null
    docker exec "$name" bash /tmp/kgsm-install.sh >"$logfile" 2>&1
    rc=$?
    (( rc == 0 )) || return "$rc"

    # The README's second command is `pacman -S kgsm-node`, whose prompt defaults to every member. A
    # script answers it by naming the members instead — read from the group rather than from a list
    # kept here, so a member added to the ecosystem is installed without this file being touched.
    skip_re="$(printf '%s|' "${SKIP_MEMBERS[@]}")"; skip_re="${skip_re%|}"
    members="$(docker exec "$name" pacman -Sqg kgsm-node 2>/dev/null \
        | grep -vE "^(${skip_re})$" | tr '\n' ' ')"
    log "installing the kgsm-node group on ${name}, less ${SKIP_MEMBERS[*]}"
    note "installing: ${members}"
    # Unquoted on purpose: the member list is words, and a package name cannot contain a space.
    # shellcheck disable=SC2086
    docker exec "$name" pacman -S --noconfirm $members >>"$logfile" 2>&1
}

INSTALLLOG="$(mktemp /tmp/kgsm-acceptance-install.XXXXXX.log)"
install_node "$CONTAINER" "$INSTALLLOG"
install_rc=$?

# What "settled" means, in three parts, because the obvious one is wrong. `is-active` on a Type=simple
# unit is true the instant the process is exec'd — before the API has opened its stores, minted its
# signing key or created the first administrator. Waiting on that waits on fork(), and the assertions
# below then race the very bootstrap they check; which of the two won depended on how many other units
# the transaction happened to start first, so the suite passed or failed on package count.
#
# So: systemd has no queued jobs left (the post-transaction hook starts units one at a time, and a unit
# ordered after network-online.target waits on systemd-networkd-wait-online, which in a container Docker
# configures the interface for takes a couple of minutes to give up), the API answers its own health
# endpoint, and the one-time password the anchor's bootstrap writes is on disk. The last is needed
# because the bootstrapper is a hosted service: Kestrel can be listening while it is still running.
#
# Every part is bounded and none of them replaces an assertion — a file that never arrives still fails
# its check below, with the message it always had.
settle_node() {
    local name="$1"
    log "letting the units on ${name} settle"
    for _ in $(seq 1 90); do
        docker exec "$name" systemctl list-jobs --no-pager 2>/dev/null | grep -q 'No jobs' || { sleep 2; continue; }
        docker exec "$name" curl -fsS -o /dev/null http://127.0.0.1:8080/health 2>/dev/null || { sleep 2; continue; }
        docker exec "$name" test -e /var/lib/kgsm-auth-anchor/initial-admin-password 2>/dev/null && break
        sleep 2
    done
}
settle_node "$CONTAINER"

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
    kgsm-auth-anchor.service
    kgsm-firewall.socket
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
check_mode /var/lib/kgsm-auth-anchor/initial-admin-password 600 "the first administrator's password"
check_mode /var/lib/kgsm-auth-anchor/session-signing.pem    600 "the anchor's self-minted signing key"

# The cluster of one. A machine whose secret was blank at first install generates one and records that
# it founded the cluster — which is what switched its anchor on, and what lets that anchor claim the
# accounts and the node introduce itself to it.
secret_set="$(docker exec "$CONTAINER" grep -cE '^[[:space:]]*Cluster__Secret[[:space:]]*=[[:space:]]*[^[:space:]]' \
    /etc/kgsm/kgsm-cluster.env 2>/dev/null)"
expect "${secret_set:-0}" 1 "the install generated a cluster secret"
check_mode /etc/kgsm/cluster-founded 644 "the record that this machine founded its cluster"

anchor_log="$(docker exec "$CONTAINER" journalctl -u kgsm-auth-anchor.service --no-pager -o cat 2>/dev/null)"
if grep -q "this member holds the cluster's accounts" <<< "$anchor_log"; then
    ok "the anchor holds the cluster's accounts"
else
    bad "the anchor never said it holds the cluster's accounts"
fi

# Read before anybody signs in: the introduction is the node's own, because nobody can sign in to make
# it until the node knows who holds the accounts.
api_log="$(docker exec "$CONTAINER" journalctl -u kgsm-api.service --no-pager -o cat 2>/dev/null)"
if grep -q 'joined the auth anchor on this machine' <<< "$api_log"; then
    ok "the node joined the anchor on its machine with nobody signed in"
else
    bad "the node never joined the anchor on its machine"
fi

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

# A node that cannot place a game server cannot host one, and no package registers a library: the
# engine's first run does. Under systemd the engine runs as the service account, so HOME is set here
# to what systemd gives User=kgsm — asked with any other, the engine answers about a different tree
# and the check would measure nothing.
AS_KGSM=(runuser -u kgsm -- env HOME=/var/lib/kgsm)
KGSM_HOME_DATA=/var/lib/kgsm/.local/share/kgsm

# Whether a unit got there first. Read before this test runs a kgsm command of its own, because that
# command would seed it too — either answer is a working node, and which one it was is worth saying.
if docker exec "$CONTAINER" test -e "${KGSM_HOME_DATA}/libraries.ini" 2>/dev/null; then
    info "the engine had already been run by a unit — its library was in place before this check"
else
    info "no unit had run the engine yet — this check is its first invocation"
fi

libs="$(docker exec "$CONTAINER" "${AS_KGSM[@]}" kgsm libraries list 2>&1)"
if printf '%s\n' "$libs" | awk 'NR > 1 && $2 == "online" { found = 1 } END { exit !found }'; then
    ok "the engine has a reachable library — a game server can be placed on this node"
else
    bad "the engine has no reachable library: $(printf '%s' "$libs" | tr '\n' ' ')"
fi

# Registered is not the same as reachable. __logic_library_is_online reads a marker off the root and
# compares its id to the registry's, so that an unmounted disk is not mistaken for the library it
# normally holds — and a root without one is registered, permanently offline, and refuses every
# install as unreachable.
if docker exec "$CONTAINER" test -f "${KGSM_HOME_DATA}/library/.kgsm-library" 2>/dev/null; then
    ok "the library root carries its marker"
else
    bad "the library root has no .kgsm-library marker — it would read offline forever"
fi

# The config key holds a NAME resolved against the registry, so the two are only correct together:
# unnamed, the second library anybody adds makes every install demand --library.
expect "$(docker exec "$CONTAINER" "${AS_KGSM[@]}" kgsm config get default_library 2>/dev/null)" \
       default "the seeded library is named as this host's default"

# The operator's answer about the address, written where NODE-PROVISIONING.md §10·b writes it: the
# address a browser reaches the node at — this machine's private address, as a LAN install's is — and the
# URL a browser signs in at, which the anchor stamps on every session as its issuer. Everything below reads
# them back from the cluster rather than from here: the node learns the issuer over gossip, and the anchor
# learns the node's address the same way.
ip_of() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
a_ip="$(ip_of "$CONTAINER")"
ISSUER="http://127.0.0.1:8098"
docker exec "$CONTAINER" sh -c "printf 'Api__PublicBaseUrl=http://%s:8080\n' '${a_ip}' >> /etc/kgsm-api/kgsm-api.env"
docker exec "$CONTAINER" sh -c "printf 'Anchor__Issuer=%s\n' '${ISSUER}' >> /etc/kgsm-auth-anchor/kgsm-auth-anchor.env"
docker exec "$CONTAINER" systemctl restart kgsm-api.service kgsm-auth-anchor.service
settle_node "$CONTAINER"
discovered=""
for _ in $(seq 1 45); do
    discovered="$(docker exec "$CONTAINER" curl -s http://127.0.0.1:8080/.well-known/oauth-protected-resource 2>/dev/null \
        | grep -oE '"authorization_servers" *: *\[ *"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/')"
    [[ "$discovered" == "$ISSUER" ]] && break
    sleep 2
done
expect "$discovered" "$ISSUER" "the node names the anchor as its sign-in provider"

# The handoff, end to end: the password in that file signs the account in that file in, at the anchor —
# the node signs nobody in.
user="$(docker exec "$CONTAINER" sed -n 's/^username: *//p' /var/lib/kgsm-auth-anchor/initial-admin-password 2>/dev/null)"
pass="$(docker exec "$CONTAINER" sed -n 's/^password: *//p' /var/lib/kgsm-auth-anchor/initial-admin-password 2>/dev/null)"
token=""
if [[ -n "$user" && -n "$pass" ]]; then
    login="$(docker exec "$CONTAINER" curl -s -w '\n%{http_code}' \
        -X POST http://127.0.0.1:8098/auth/sign-in -H 'Content-Type: application/json' \
        -d "{\"username\":\"${user}\",\"password\":\"${pass}\"}" 2>/dev/null)"
    code="$(printf '%s' "$login" | tail -n1)"
    expect "$code" 200 "'${user}' signs in at the anchor with the password from the file"
    # Kept for the assertions below, which are the admin's view of the node and of the anchor.
    token="$(printf '%s' "$login" | head -n-1 | grep -oE '"token" *: *"[^"]+"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
else
    bad "could not read a username and password out of the initial-admin-password file"
fi

# The panel this node serves, registered with the provider by the node's own announcement. Nobody
# entered it: it arrives over gossip, joined to the address the roster holds for the node.
clients=""
for _ in $(seq 1 30); do
    clients="$(docker exec "$CONTAINER" curl -s -H "Authorization: Bearer ${token}" \
        http://127.0.0.1:8098/auth/cluster/clients 2>/dev/null)"
    grep -q '/signed-in"' <<< "$clients" && break
    sleep 2
done
panel="$(grep -oE '"redirectUris" *: *\[ *"[^"]+/signed-in"' <<< "$clients" | sed 's/.*"\([^"]*\)"$/\1/' | head -1)"
if [[ -n "$panel" ]] && grep -q '"source" *: *"member"' <<< "$clients"; then
    ok "the panel is a client of the provider without anybody entering it (${panel})"
else
    bad "the panel never reached the provider's client registry: ${clients:-no answer}"
fi

# Every leaf this node installed, joined up. Each of these binds a fixed endpoint, and the panel is
# where a person finds out whether the machine's parts found each other — so a node that installed
# the whole ecosystem and reports half of it absent is a broken node, however green systemctl looks.
# This is the assertion the wiring defects hid behind: every unit was active and every capability
# said the leaf was not there.
caps="$(docker exec "$CONTAINER" curl -s -H "Authorization: Bearer ${token}" \
    http://127.0.0.1:8080/api/v1/hosts 2>/dev/null)"
if [[ -z "$token" ]]; then
    bad "no session token — the capability block could not be read"
elif [[ "$caps" != *'"capabilities"'* ]]; then
    bad "GET /hosts returned no capability block — the panel cannot say what this node runs"
else
    # The block reports five. The firewall and the bot are not in it — the ports surface and the bot
    # page carry their own provisioning — so asserting them here would be asserting a shape the API
    # does not have.
    for leaf in metrics watchdog scheduler reactor; do
        if printf '%s' "$caps" | grep -qE "\"${leaf}\"[^}]*\"provisioned\" *: *true"; then
            ok "the api found the ${leaf} leaf without being told where it is"
        else
            bad "the api reports ${leaf} absent, though this node installed it"
        fi
    done

    # And the other direction, which is the half that is easy to get wrong. The assistant is not
    # installed here, so the API must report it ABSENT — not present-and-unreachable. A host resolves
    # a leaf's endpoint from the descriptor its package leaves behind; no package, no descriptor, no
    # capability. Reporting it down instead would make every node without an assistant look broken.
    if printf '%s' "$caps" | grep -qE '"assistant"[^}]*"provisioned" *: *false'; then
        ok "the api reports the assistant absent — it is not installed on this node"
    else
        bad "the api does not report the assistant absent, though this node never installed it"
    fi
fi

# The shared state tree kgsm-base declares. Every path here is written by several packages and owned
# by none of them, so a missing one is not a missing feature — it is one package quietly writing
# somewhere else, or not at all. Checked as modes rather than mere existence because the account store
# holding password hashes at anything but 0700 is the failure worth catching.
check_mode /var/lib/kgsm/events          755 "the engine's event journal"
check_mode /var/lib/kgsm/leaves          755 "the leaf config descriptors"
check_mode /var/lib/kgsm/leaves/commands 755 "the leaf command manifests"
check_mode /var/lib/kgsm/auth            700 "the KGSM account store"
check_mode /var/lib/kgsm/cluster         755 "what members of a cluster on one machine share"

# The two shared env files. Both ship blank — no package carries a credential — and both are read by
# every member on the host, so a missing one is a host where sign-in or cluster membership is
# configured per component instead of once.
check_mode /etc/kgsm/kgsm-auth.env    640 "the host's shared sign-in applications"
check_mode /etc/kgsm/kgsm-cluster.env 640 "the host's shared cluster secret"

# ---------------------------------------------------------------- a founding machine joins another
#
# A second machine installed the same way founds a cluster of its own, then joins the first one's by
# taking its secret — the whole of NODE-PROVISIONING.md §10·a for a founding machine, with nothing
# cleared by hand. What must not happen is the joiner's memory of its own cluster, or its own anchor,
# competing with the cluster it joins for the accounts.
echo
log "a machine that founded its own cluster joins this one"
boot_node "$JOINER"
JOINLOG="$(mktemp /tmp/kgsm-acceptance-joiner.XXXXXX.log)"
install_node "$JOINER" "$JOINLOG"
expect "$?" 0 "the joiner installs with the README's commands"
settle_node "$JOINER"

joiner_anchor_log="$(docker exec "$JOINER" journalctl -u kgsm-auth-anchor.service --no-pager -o cat 2>/dev/null)"
if grep -q "this member holds the cluster's accounts" <<< "$joiner_anchor_log"; then
    ok "the joiner founded a cluster of its own, its anchor holding that cluster's accounts"
else
    bad "the joiner's anchor never held its own cluster's accounts"
fi

b_ip="$(ip_of "$JOINER")"
secret="$(docker exec "$CONTAINER" sed -n 's/^[[:space:]]*Cluster__Secret[[:space:]]*=[[:space:]]*//p' \
    /etc/kgsm/kgsm-cluster.env | tail -n1)"

# The runbook's two steps on the joining machine: the secret, and a restart of every member on it.
docker exec "$JOINER" sed -i "s/^[[:space:]]*Cluster__Secret[[:space:]]*=.*$/Cluster__Secret=${secret}/" \
    /etc/kgsm/kgsm-cluster.env
since="$(docker exec "$JOINER" date +%s)"
docker exec "$JOINER" systemctl try-restart kgsm-api kgsm-auth-anchor kgsm-bot kgsm-assistant-service kgsm-dns \
    2>/dev/null
settle_node "$JOINER"

# And the one step on the cluster being joined: an admin adds the machine. Asked at this machine's own
# address rather than loopback, because a node records the address an admin reached it at as where the
# joiner calls back.
added="$(docker exec "$CONTAINER" curl -s -o /dev/null -w '%{http_code}' \
    -X POST "http://${a_ip}:8080/api/v1/members" -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' -d "{\"url\":\"http://${b_ip}:8080\"}" 2>/dev/null)"
case "$added" in 2??) ok "an admin of this cluster adds the joiner (HTTP ${added})" ;;
                 *)   bad "adding the joiner answered HTTP ${added:-nothing}" ;; esac

joiner_api_log="$(docker exec "$JOINER" journalctl -u kgsm-api.service --since "@${since}" --no-pager -o cat 2>/dev/null)"
joiner_anchor_log="$(docker exec "$JOINER" journalctl -u kgsm-auth-anchor.service --since "@${since}" --no-pager -o cat 2>/dev/null)"

if grep -q 'it held the state of a cluster whose secret this member no longer holds' <<< "$joiner_api_log"; then
    ok "the joiner's node discarded what it knew of its old cluster on its own"
else
    bad "the joiner's node never discarded its old cluster's state"
fi
if grep -q 'waits for an admin to add it' <<< "$joiner_api_log"; then
    ok "the joiner's node waited to be added rather than introducing itself to its own anchor"
else
    bad "the joiner's node did not say it waits to be added"
fi
if grep -q 'did not found the cluster it is in, so this anchor never claims' <<< "$joiner_anchor_log" \
   && ! grep -q 'claimed them as' <<< "$joiner_anchor_log"; then
    ok "the joiner's anchor never claimed the joined cluster's accounts"
else
    bad "the joiner's anchor claimed, or never said it would not"
fi
# Nobody introduces it to the cluster it is now in, so it stays out of the roster and serves nothing
# until an administrator adds it as a promotion candidate. Asked rather than read from its log: a member
# standing by refuses a sign-in with 503, naming whoever it knows holds the accounts.
refused="$(docker exec "$JOINER" curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8098/auth/sign-in \
    -H 'Content-Type: application/json' -d '{"username":"admin","password":"x"}' 2>/dev/null)"
expect "$refused" 503 "the joiner's anchor stands by, signing nobody in"

a_standing="$(docker exec "$CONTAINER" journalctl -u kgsm-auth-anchor.service --since "@${since}" --no-pager -o cat \
    2>/dev/null | grep -c 'standing by')"
expect "${a_standing:-0}" 0 "this cluster's anchor still holds its accounts after the join"

joined_issuer=""
for _ in $(seq 1 30); do
    joined_issuer="$(docker exec "$JOINER" curl -s http://127.0.0.1:8080/.well-known/oauth-protected-resource 2>/dev/null \
        | grep -oE '"authorization_servers" *: *\[ *"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/')"
    [[ "$joined_issuer" == "$ISSUER" ]] && break
    sleep 2
done
expect "$joined_issuer" "$ISSUER" "the joiner names this cluster's provider"

# Who this cluster's administrator is on the joiner. Measured rather than asserted: the joiner's own
# first administrator carries the same username, and reconciling one person's two accounts is
# cluster-auth-plan.md §8's, not this join's.
me="$(docker exec "$JOINER" curl -s -H "Authorization: Bearer ${token}" http://127.0.0.1:8080/api/v1/me 2>/dev/null \
    | grep -oE '"tier" *: *"[^"]*"' | head -1)"
info "this cluster's administrator on the joiner: ${me:-no answer}"

# ------------------------------------------------------------------------ the web server, after KGSM
#
# The runbook's prerequisite for serving the cluster's names, installed the way a person would: after
# the node. The components' site files are already in conf.d, which Arch's stock nginx.conf does not
# read; kgsm-base's pacman hook is what makes it, with nobody editing the file.
echo
log "installing nginx after the node"
docker exec "$CONTAINER" pacman -S --noconfirm nginx >>"$INSTALLLOG" 2>&1
confd="$(docker exec "$CONTAINER" grep -cE '^[[:space:]]*include[[:space:]]+/etc/nginx/conf\.d/\*\.conf;' \
    /etc/nginx/nginx.conf 2>/dev/null)"
expect "${confd:-0}" 1 "nginx reads the sites KGSM installed, with nobody editing nginx.conf"
nginx_t="$(docker exec "$CONTAINER" nginx -t 2>&1 | tail -1)"
case "$nginx_t" in *successful*) ok "nginx accepts the configuration with KGSM's sites in it" ;;
                   *)            bad "nginx -t: ${nginx_t:-no answer}" ;; esac

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
