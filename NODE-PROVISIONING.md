# Provisioning a node, start to finish

A runbook for an **agent with a shell on the target host** and a person available to answer
questions. It is written to be executed top to bottom: every step is a command whose output is
checked, every decision that belongs to a person is asked for in one block at the start, and every
place where the run legitimately stops is named.

`README.md` describes the *mechanism* — what the repository is, why the key is trusted the way it
is, what the hook does. This describes the *run*. Where the two disagree about a command, the README
is right: its install block is extracted and executed by `test/acceptance.sh`, so it cannot drift.

**Where this ends.** A node that boots into its units, an administrator account somebody can sign in
to, a library a game server can be installed into, and — for a cluster node — its assigned name
served over HTTPS. Installing game servers is not provisioning
and is not here.

## The rules this run is bound by

- **Never invent a value.** No credential, no domain, no path guessed from a hostname. A key nobody
  supplied stays blank and the unit that needs it stays stopped — that is a correct outcome, and it
  is reported as one. A node that starts with a fabricated value is worse than a node that has not
  started.
- **Never build from source.** Nothing here compiles anything. A node installs binary packages; it
  needs no .NET SDK, no git checkout, no NuGet credential. If a step seems to call for a build, the
  step is being read wrong.
- **Report what happened, not what was meant to happen.** Quote the command's actual output. "The
  unit is running" is a claim `systemctl is-active` either supports or does not.
- **Ask once, at the start.** Section 1 collects everything a person owes. Running into a missing
  answer at step 9 wastes their attention and yours.
- **Root is required for most of this.** Get it before starting: either a root shell, or a working
  `sudo`. On a host where `sudo` prompts, collect the password up front — a password prompt in the
  middle of a non-interactive pipeline reads as a hang.

## 1. Ask the operator, once

Put all of these to the person in one message. Everything below the first three is optional and
names exactly what is lost by skipping it, so a person can answer "skip" and get a working node.

| # | What to ask | Why it cannot be guessed | If they skip it |
|---|---|---|---|
| 1 | **Root access** — a root shell, or the `sudo` password | Installing packages, writing `/etc/pacman.conf` and trusting a key are all privileged | Nothing can proceed; stop here |
| 2 | **Which components this node runs** (see the roles in §4) | A node is a selection, not a fixed set. A machine with no GPU should not be asked to serve models; a second node usually wants no Discord bot | Default to the whole `kgsm-node` group, and say that is what was chosen |
| 3 | **Where game server instances live** — an absolute path on this host | Which disk holds tens of GB of game data is a hardware decision (§8) | Instances land on the root filesystem, in the library the engine seeds itself |
| 4 | **Its own cluster, or joining one.** Its own: the public address the panel is reached at, and whether it needs TLS. Joining: the cluster's secret, this machine's public host (its dynamic-DNS name, with 443 forwarded to it), and an address the cluster's DNS holder reaches it at before it has a name (§10) | Each describes one network and is wrong on any other | Its own cluster on `http://<lan-ip>:8080`, signed into at `:8098`; nothing off the LAN reaches it |
| 5 | **A Discord bot token** — only if `kgsm-bot` was selected | It comes from a Discord application only they own | `kgsm-bot.service` stays stopped and `kgsm-node-status` keeps saying so |
| 6 | **A Discord OAuth client id + secret** — only on a machine that runs its own cluster, if people sign in through Discord. A node signs nobody in: the auth anchor does, so the application is the anchor's | Same application, and both callbacks must be registered on it | Everyone signs in with a KGSM username and password, which needs nothing |
| 7 | **The inference backend** — Ollama, or the llama.cpp units; only if `kgsm-llm` was selected | A host runs one or the other; both loaded means two copies of the weights | The assistant starts and every turn fails until one exists (§11) |
| 8 | **A Steam account username** — only for games Steam will not serve anonymously | It is their account, and the login is interactive once | Anonymous-install games work; account-gated ones refuse |

Answers 5 through 8 can all arrive later. Say so when asking — it is the difference between a person
answering four questions now and blocking on eight.

## 2. Preflight

Every line here is read-only. Run them before touching anything.

```bash
uname -m                       # x86_64 — the packages are built for it and no other
command -v pacman              # a path — KGSM's packages are pacman packages
[ -d /run/systemd/system ] && echo booted || echo "NO SYSTEMD"
df -h /var/lib /opt            # room for the packages and the state tree
curl -fsI https://github.com >/dev/null && echo reachable
pacman -Q kgsm-base 2>/dev/null && echo "ALREADY A NODE"
```

- **Not `x86_64`** — stop and report it. There is no build for another architecture, and nothing in
  this document produces one.
- **No `pacman`** — stop. This is an Arch mechanism end to end.
- **No booted systemd** (a container without an init, a chroot, an image build) — the install still
  works, presets still apply, and *nothing starts*. Proceed if that is deliberate, then run §7 on the
  booted host. Otherwise stop.
- **Already a node** — this is a re-run or an upgrade, not a provisioning. Skip to §5, read the state,
  and act on what is actually outstanding. Do not re-run §3 blindly on a host whose `[kgsm]` section
  somebody may have pointed elsewhere on purpose.

## 3. Trust the key, add the repository

The one-liner, exactly as `README.md` gives it and `test/acceptance.sh` runs it:

```bash
curl -fsSL https://raw.githubusercontent.com/TheKrystalShip/kgsm-meta/main/setup-node.sh | sudo bash
```

It initialises pacman's keyring, fetches the packaging key, **refuses it unless it carries the
fingerprint compiled into the script**, locally signs it, appends the `[kgsm]` section to
`/etc/pacman.conf`, and runs `pacman -Syu`. It is idempotent and re-running it is safe.

Three things worth knowing before running it:

- **Flags need `-s --`.** Piped into bash, `bash` reads `--no-upgrade` as its own flag unless it is
  handed over: `curl -fsSL <url> | sudo bash -s -- --no-upgrade`.
- **`KGSM_REPO_URL` repoints the whole script** — at a mirror, or a `file://` directory under test.
  Leave it unset for a real node.
- **The first step is the one nothing verifies.** Whoever could serve a different key could serve a
  different copy of the script carrying a different fingerprint. If the person cares about that gap,
  the by-hand form in `README.md` lets them compare `B7624435FAC1A8280B280CFBA6FBDB3B724DED1B`
  against a copy obtained some other way first. Offer it; do not decide it for them.

Verify the repository answers before going further:

```bash
pacman -Sl kgsm | head -5      # package lines, not an error
pacman -Sg kgsm-node | head    # the group exists and has members
```

An empty `pacman -Sl kgsm` with no error means the database synced and served nothing — check the
`Server` line in `/etc/pacman.conf` against the URL in the README.

## 4. Install the components

**Read the group rather than trusting a list.** Membership changes as the ecosystem grows, and the
node is entitled to whatever the repository is serving today:

```bash
pacman -Sg kgsm-node
```

**`pacman -S kgsm-node` is interactive** — it prints the numbered members and waits on
`Enter a selection (default=all):`. An agent has two non-interactive forms and must choose one
deliberately:

```bash
sudo pacman -S --noconfirm kgsm-node                    # every member: pacman's own default
sudo pacman -S --noconfirm kgsm kgsm-watchdog kgsm-monitor   # a named subset
```

Roles, as a starting point for the answer to question 2. Reconcile every name against
`pacman -Sg kgsm-node` before running anything — a name this document knows and the repository does
not is a typo in the transaction, not a missing package.

| Role | Packages | What it is |
|---|---|---|
| **Game host** | `kgsm`, `kgsm-watchdog`, `kgsm-monitor`, `kgsm-monitor-net-meter`, `kgsm-scheduler`, `kgsm-reactor`, `kgsm-firewall` | Runs game servers and measures them. No panel, no chat surface. Reachable only by another node's panel |
| **Panel host** | the above plus `kgsm-api`, `kgsm-web` | Adds the Control Panel: the API and the SPA it serves at `/` |
| **Assistant host** | plus `kgsm-llm`, optionally `kgsm-rag-indexer`, `kgsm-llm-llamacpp`, `kgsm-speech` | Adds the local assistant. Needs a model server (§11) and real hardware to run it on |
| **Discord surface** | plus `kgsm-bot` | Adds the Discord bot. Needs the token from question 5 |
| **Everything** | `kgsm-node` | What `--noconfirm` gives you |

Four dependencies that decide whether a selection makes sense:

- **`kgsm-web` without `kgsm-api`** installs a bundle nothing serves. The API is what serves it.
- **`kgsm-monitor-net-meter`** attaches an eBPF program to `kgsm.slice`, which `kgsm-watchdog`
  creates. Without the watchdog it never runs and the monitor reports `rxBps`/`txBps` as null —
  measured absence, which is correct, not a failure.
- **`kgsm-llm-llamacpp`** execs `/usr/bin/llama-server`, provided by `llama.cpp-cuda`, `-vulkan`,
  `-rocm` or plain `llama-cpp`. Exactly one of them can be installed and which one depends on the
  card, so none is a hard dependency. Installing the KGSM package without one of them is a unit that
  cannot start.
- **`kgsm` on a host running only container instances** does not need `kgsm-watchdog`, but every
  native instance does. Install it unless the person said containers only.

**Capture the transaction's output** — `| tee /tmp/kgsm-install.log`. Each package's scriptlet prints
what it owes a person, and that text scrolls past exactly once. `kgsm-node-status` recovers the same
facts afterwards, so this is a convenience, not the record.

## 5. Read the node's state

```bash
sudo kgsm-node-status
```

This is the authority on what the node is. It is read-only, always exits 0, and derives everything
from what pacman installed and what systemd was asked for — it holds no list of components, so it is
right about a package this document has never heard of.

**Run it as root.** The env files it scans are `root:root 0640`, so an unprivileged run cannot read
them, finds no outstanding keys, and reports a blocked unit as ready. Nothing announces that it read
nothing — the report simply comes back wrong.

The unit table has three policies, and each means something different:

- **`on`** — enabled, nothing outstanding, safe to run. It should be `active` (or `inactive` for a
  socket-activated `.service`, which is that unit working correctly).
- **`blocked`** — enabled, and a key in its own env file is still blank. The hook deliberately
  refuses to start it. §6 is the fix.
- **`opt-in`** — the preset policy leaves it disabled. Installing it was not choosing to run it. It
  is a decision (§11), not a fault.

Below the table, up to three more sections:

- **Blocked** names the env file and the exact keys. Act on it.
- **First sign-in** names a one-time password file a service minted. Act on it (§9). It blocks
  nothing — the unit that wrote it is already running.
- **Set only if...** is the shared sign-in file, `/etc/kgsm/kgsm-auth.env`. It holds nothing up. A
  host whose people sign in with a KGSM password needs nothing in it.

If the RUNNING column reads `unknown` everywhere, there is no systemd to ask (§2) and nothing was
started.

## 6. Fill in what is blocked

The rule the scan applies, so you can apply the same one: **a key is outstanding when it is blank or
carries a `YOUR_..._HERE` placeholder.** Anything a leaf runs perfectly well without is commented out
in its file instead, and a secret a leaf generates for itself is commented out too. So a blank
uncommented key means a person, and only a person.

Today one package blocks on a credential nobody but the operator has:

| Unit | File | Key | Where the value comes from |
|---|---|---|---|
| `kgsm-bot.service` | `/etc/kgsm-bot/kgsm-bot.env` | `Discord__Token` | The bot's Discord application (question 5) |

Take the list from `kgsm-node-status`, not from that table — the table is what a node looks like
today and the scan is what this node actually is.

**Edit the file in place.** It is `root:root 0640` — systemd reads `EnvironmentFile=` as root before
dropping to `User=kgsm`, so nothing reads it as the service account — and it is listed in the
package's `backup=()`, so an upgrade writes a `.pacnew` beside your edit instead of over it. Do not
recreate it, do not change its mode or owner, and do not copy it somewhere else.

```bash
sudo sed -i 's|^Discord__Token=.*|Discord__Token=<the token>|' /etc/kgsm-bot/kgsm-bot.env
sudo kgsm-node-status                 # the unit should have moved out of `blocked`
```

If the person deferred a credential, leave the key blank, say which unit stays stopped because of it,
and carry on. That node is finished and correct; it is just not running that one surface.

## 7. Start what became ready

The post-transaction hook already started everything that was ready at install time. After filling in
a key, either start the unit directly or re-run the hook's action half over the whole node:

```bash
sudo systemctl start kgsm-bot.service                       # the one unit
sudo /usr/lib/kgsm-base/apply-node-state </dev/null         # everything now ready
```

**`</dev/null` is not optional.** `apply-node-state` reads the changed paths from stdin, because
that is how the hook hands them over. Run from a terminal with stdin attached it waits for input,
and the run looks like a hang.

It starts a unit only when it is enabled, stopped and owes nothing; it restarts a unit whose package
was just replaced; it never fails, and on a host with no systemd it prints the report and does
nothing. Running it twice is safe.

## 8. Register a library, if the default one is in the wrong place

**The engine's first run seeds a library.** On its way to running whatever it was asked to do, it
creates its config, registers `default` at the instances directory `kgsm --paths` already reports,
names it as the default, and writes the `.kgsm-library` marker that makes it reachable. A node can
host a game with nobody having configured anything, and the first command is an ordinary one:
`kgsm install factorio` on an untouched host installs factorio.

Those paths follow the service account's home, because that is what systemd gives `User=kgsm` and no
unit sets `XDG_*`. On a node they are:

```
/var/lib/kgsm/.config/kgsm/config.ini              the config
/var/lib/kgsm/.local/share/kgsm/libraries.ini      the library registry
/var/lib/kgsm/.local/share/kgsm/instances          the seeded library root
```

Ask the engine rather than assuming: `sudo -u kgsm -H kgsm --paths` prints all of them, and reading
them as any other account reports a different tree entirely (§14).

That default is on the root filesystem. Game data is tens of gigabytes, so on most hosts the answer
to question 3 is a different disk, and the step here is to say so:

```bash
sudo -u kgsm -H kgsm libraries add /srv/games --name main
sudo -u kgsm -H kgsm config set default_library=main
sudo -u kgsm -H kgsm libraries list          # both, with free space and online state
```

Naming the new default is not optional once there are two. With several registered and no default
chosen, every install refuses and demands `--library`.

Drop the seeded one if nothing has been installed into it, or move what has:

```bash
sudo -u kgsm -H kgsm libraries remove default              # empty
sudo -u kgsm -H kgsm libraries remove default --drain main # with instances in it
```

**`-u kgsm -H` is the whole point.** See §14: run without it and the registry lands under the wrong
account's home, where no unit on this host will ever look — including the seeded library, which the
first run creates wherever `HOME` pointed.

An admin can do the same thing from the panel once somebody has signed in (`POST
/api/v1/hosts/{id}/libraries`, admin-gated) — but during provisioning nobody has, so the shell is the
path.

## 9. Sign in for the first time

People sign in at the cluster's **auth anchor**, never at a node: `kgsm-api` signs nobody in and
accepts only sessions the anchor minted. On a machine that founded its own cluster the anchor runs
here, and its first start finds an empty account store, creates the administrator `admin`, and leaves
the generated one-time password in a file:

```bash
sudo cat /var/lib/kgsm-auth-anchor/initial-admin-password
```

Give it to the person. **It is removed the first time that account signs in with a password**, so it
exists exactly between those two moments — a node past that point has no file and
`kgsm-node-status` says nothing about it, which is not an error. **Do not choose a password for the
person and do not set one from a script** — it would be a credential this run invented, and it would
sit in shell history.

A machine that joined a cluster somebody else runs has no anchor of its own running and no password
file: its people already have accounts at that cluster's anchor, which replication brings here.

`kgsm-api`'s own log says which member signs its sessions, or that none does:

```bash
journalctl -u kgsm-api | grep -E 'signed by the auth anchor|no member of this cluster holds'
```

Who may do what is not a sign-in question. It is set on the KGSM account in the Control Panel, and no
Discord guild, group or role grants anything on any surface.

## 10. Make the node reachable

Everything here is in `/etc/kgsm-api/kgsm-api.env`, where **every host-specific value ships commented
out on purpose**. Follow §10·a or §10·b, never both. Ports on the host firewall are the operator's;
KGSM opens and closes *game* ports and never 443 or 8080.

```bash
sudo systemctl restart kgsm-api.service       # after any edit to that file
```

### 10·a. Joining a cluster

The cluster names the node, issues its certificate and serves it through nginx. Authority:
`cluster-dns-plan.md` in the workspace. The node is configured with no name, no certificate and no
public URL.

| Where | Key | Value |
|---|---|---|
| `/etc/kgsm/kgsm-cluster.env` | `Cluster__Secret` | The cluster's secret, supplied by the operator |
| `/etc/kgsm-api/kgsm-api.env` | `Api__Urls` | `http://127.0.0.1:8097`, plus the join address from the last row when it is on this machine's own interface |
| | `Api__HostId` | The member id, stable forever. Blank takes the machine name |
| | `Api__PublicHost` | The machine's dynamic-DNS name, or a fixed public address. Blank: the node is a member but gets no name |
| | `Api__CorsOrigins` | The panel's origin, `https://kgsm.<zone>` |
| | `Api__LocalAnchorUrl` | Empty: this node joins a cluster somebody else runs and never introduces itself to an anchor on its own machine |
| never set | `Api__PublicBaseUrl`, `Api__ConnectHost`, `Api__ClusterGossipUrl`, `Kestrel__*`, provider keys | Their values come from the cluster |

**A machine that founded its own cluster first stops being one.** kgsm-base founds a cluster on a
machine whose secret was blank at first install, and that machine's anchor holds its accounts. Its
members remember that cluster — who held the accounts, at what version — and gossip would carry it into
the cluster being joined, where a tie on the version goes to whichever member id sorts later: this
machine's anchor could be handed the joined cluster's accounts. So, before the secret changes, and in
this order:

```bash
sudo systemctl disable --now kgsm-auth-anchor.service      # this machine no longer holds accounts
sudo systemctl stop kgsm-api.service                        # and every other member unit on it
sudo rm /etc/kgsm/cluster-founded                           # it did not found the cluster it is joining
sudo rm /var/lib/kgsm-api/kgsm-api.cluster.db* \
        /var/lib/kgsm-auth-anchor/cluster.db*               # each member's memory of the old cluster
```

Then set the secret below and start the node. Accounts made in the old cluster stay behind: joining is
not a merge, and `cluster-auth-plan.md` §8 is where reconciling them lives.

Machine prerequisites:

- `nginx` installed and enabled (`systemctl enable --now nginx`). The package ships
  `/etc/nginx/conf.d/00-kgsm-api-sites.conf`, the proxy rules, the reload grant and the
  `/var/lib/kgsm/{tls,nginx}` directories; nothing is hand-copied. Arch's stock `nginx.conf` reads
  no `conf.d`, so its `http {}` block needs `include /etc/nginx/conf.d/*.conf;` — without it the
  site file is never loaded and `nginx -t` passes anyway.
- The router forwards TCP 443 to this machine, as a plain port forward. A proxy that terminates TLS
  in front of it serves only the names it holds certificates for and refuses the cluster's name with
  `unrecognized name`; one in front must pass the connection through by SNI. Port 80 is not needed:
  certificates are DNS-01. No certbot.
- The host firewall admits TCP 443 from anywhere and the join port from the private network the DNS
  holder reaches it over, e.g. `ufw allow 443/tcp` and
  `ufw allow in on wg0 from 10.44.0.0/24 to any port 8097 proto tcp`.
- The dynamic-DNS client for `Api__PublicHost` runs on this network.

Join:

1. **Pick the join address**: an address the DNS holder's machine reaches this node's API at before it
   has a name. The anchor delivers the first certificate there, and a public address needs TLS the
   node does not have yet, so it is a private one over plain http: a LAN or VPN address (e.g. a
   WireGuard peer address) bound in `Api__Urls` as `http://<private-ip>:8097`.
2. **Optionally pin the name** on the DNS anchor: `MemberNamePins` in `kgsm-dns.settings.json`
   (`<member-id>=<name>`), then redeploy kgsm-dns. Unpinned, a name is drawn from `MemberNames`.
3. **An admin adds the member** from the panel's Cluster page, pasting `http://<private-ip>:8097`.
4. **Watch it named**, within a minute:

```bash
journalctl -u kgsm-api -f | grep -i -E 'name|certificate|site'   # told its name, certificate installed
dig +short <name>.nodes.<zone> @<zone's nameserver>              # the CNAME to Api__PublicHost
curl -fsS https://<name>.nodes.<zone>/health                     # served on the anchor-issued cert
```

The roster then reaches the node at `https://<name>.nodes.<zone>` and every game server installed on it
is published as `<game>.play.<zone>`. A name looked up before it existed is negatively cached by
resolvers for up to 30 minutes; check at the zone's nameserver or with `curl --resolve`.

Removing the node from the Cluster page releases its names three minutes later. A node that is only
offline keeps them.

### 10·b. Its own cluster

A machine whose secret was blank at first install is a cluster of one: kgsm-base generated its secret,
its auth anchor is on and holds the accounts, and `kgsm-api` introduces itself to that anchor at
`http://127.0.0.1:8098` on its own, because nobody can sign in to do it by hand until it has.

The node unit binds `http://0.0.0.0:8080` and serves both the SPA at `/` and the API under `/api/v1` on
that one origin; the anchor binds `0.0.0.0:8098`, and people sign in there. On a LAN that is enough for
the network — open `http://<ip>:8080`, and give the panel `http://<ip>:8098` as the address to sign in
at. Fill in only what question 4 actually asked for:

- **`Api__PublicBaseUrl`** — the address a browser reaches this node at, `http://<ip>:8080` or its
  public origin. The node was introduced to its anchor over loopback, so without it the cluster's
  roster hands a browser `127.0.0.1`.
- **`Anchor__AllowedOrigins`** in `/etc/kgsm-auth-anchor/kgsm-auth-anchor.env` — the panel's origin,
  the same address, so the panel may sign people in at the anchor. Without it every sign-in fails in
  the browser before the anchor sees it.
- **A public origin over TLS.** Kestrel terminates TLS itself on both — there is no reverse proxy in
  this design. The four `Api__Urls` / `Kestrel__Certificates__*` lines are uncommented **together**:
  an https bind with no certificate fails exactly as a certificate path with no file does. The env file
  carries the certbot invocation and the deploy hook that makes the certificate readable by the
  non-root service; the anchor's own env file takes the same four keys for its port.
- **`Api__CorsOrigins`** — needed only when a *different* origin must reach this API. Same-origin needs
  none, and unset means same-origin only.
- **The Discord application**, only for question 6, goes in `/etc/kgsm/kgsm-auth.env`, which the anchor
  reads; its callbacks are the anchor's, `/auth/<provider>/callback` and
  `/auth/identities/<provider>/callback` on the anchor's address.

## 11. The decisions left deliberately off

`kgsm-node-status` lists these as `opt-in`. Each is installed and not running because running it is
a choice.

**The assistant's model server.** `kgsm-llm` starts on its own and **every turn fails until it can
reach a model**. Two backends, and a host runs one:

- **Ollama** — install it separately and keep it bound to `127.0.0.1`. A routable bind is an
  unauthenticated inference endpoint on the internet.
- **llama.cpp** — `kgsm-llm-llamacpp`, three steps and all three are needed:

```bash
sudo <editor> /etc/kgsm-assistant/llama-server.env   # model paths, ports, idle timeout
sudo -u kgsm kgsm-llama-fetch-models                 # GGUFs into /var/lib/llama/models — large, slow
sudo kgsm-llama-use-backend llamacpp                 # moves the assistant AND the indexer together
```

Moving one of those two alone points something at a dead port.

**The retrieval index.** `kgsm-rag-indexer` builds the assistant's local corpus and costs GPU time
and disk. The assistant answers without it — it just has nothing local to draw on.

```bash
sudo systemctl enable --now kgsm-rag-indexer.service
```

**Steam.** For games Steam will not serve anonymously, set the username in the engine's config and
bootstrap the login **once, interactively** — this is a person at a terminal approving on their
phone, not something to script:

```bash
sudo -u kgsm -H kgsm config set STEAM_USERNAME=<username>
sudo -u kgsm -H steamcmd +login <username> +quit     # the person answers Steam Guard
```

Leave the password unset. SteamCMD keeps a refresh token that satisfies Steam Guard afterwards, and
supplying a password takes the password path and replaces that token.

**Docker.** Only for container-kind instances. It is an `optdepends` of `kgsm` and not installed by
default.

## 12. Verify

Assert, do not assume. Every line below has an expected answer.

```bash
sudo kgsm-node-status                             # no `blocked` rows left unexplained
systemctl list-units 'kgsm-*' --all --no-pager    # matches the table above
systemctl --failed --no-pager                     # compare against §13, not against zero

kgsm --version                                    # the engine answers
sudo -u kgsm -H kgsm libraries list               # at least one library, state online

curl -fsS http://127.0.0.1:8080/health            # kgsm-api answers (8097 on a cluster node)
curl -fsS http://127.0.0.1:8080/ -o /dev/null -w '%{http_code}\n'   # 200 = the SPA is served
curl -fsS https://<name>.nodes.<zone>/health      # cluster node only: served at its assigned name

ls /var/lib/kgsm/leaves/                          # one descriptor per installed leaf
ls /var/lib/kgsm/events/                          # the event journal directory exists
```

Then the one end-to-end check, and only with the person's agreement — it downloads a game server and
writes to their disk:

```bash
sudo -u kgsm -H kgsm install factorio --id probe
sudo -u kgsm -H kgsm start probe && sleep 20 && sudo -u kgsm -H kgsm status probe
sudo -u kgsm -H kgsm stop probe && sudo -u kgsm -H kgsm uninstall probe --yes
```

Factorio and Terraria are the quickest to install; prefer one of them when the game does not matter.
Say plainly whether this was run or skipped — a provisioning report that implies an install was
proven when it was not is the one failure mode worse than an unprovisioned node.

## 13. Failures that are not failures

Read `systemctl --failed` against this list before reporting anything:

- **`kgsm-net-meter.service` failed once and is now running.** Attaching its eBPF program needs
  `/sys/fs/cgroup/kgsm.slice` to exist, and being ordered after `kgsm-watchdog.service` is not the
  same as being ordered after the slice that unit creates at runtime. The second pass attaches it. A
  meter that is still failing after the watchdog is up is a real fault.
- **A socket-activated `.service` reading `inactive`.** `kgsm-firewall.service` and
  `kgsm-speech.service` are meant to exit when nobody is asking — `kgsm-speech` holds about 1.6GB of
  models and only a process ending returns it. The `.socket` being active is the unit that matters.
- **`systemd-networkd-wait-online.service` timing out** on a host where networkd manages nothing. It
  is pulled in by `network-online.target`, which the assistant and bot units want.
- **A unit reading `blocked` with a key nobody supplied.** That is the mechanism working. Report it
  as an outstanding answer, not as a broken node.

## 14. Running the engine by hand on a node

**Every KGSM unit runs as the `kgsm` service account, and the engine's data lives under that
account's home at `/var/lib/kgsm`.** Instances, blueprints, the library registry and the config are
all under its XDG paths.

Run as any other account, the engine would read and write *that* account's home, a registry no unit
on the host reads — so it refuses instead. Every command other than `--help`, `--version` and
`--paths` stops with exit code 16, naming the account the host's services run as (the owner of the
event journal at `/var/lib/kgsm/events`) and the exact invocation to use. `--paths` still answers,
and is how to see which tree an account resolves to.

```bash
sudo -u kgsm -H kgsm <command>          # -H sets HOME to /var/lib/kgsm; without it, sudo keeps yours
sudo -u kgsm -H kgsm --paths            # confirm: every user path under /var/lib/kgsm
```

The account's shell is `nologin`, which does not affect `sudo -u` — it only means nobody logs in as
it.

## 15. Upgrades, afterwards

```bash
sudo pacman -Syu
```

That is the whole of it, key rotation included: `kgsm-keyring` is an ordinary package that every node
carries, so adding or revoking a signing key arrives with the upgrade.

Two things to do afterwards:

- **Merge any `.pacnew`.** An edited file under `/etc` is never overwritten; the new one lands beside
  it. New settings are declared there, and a key a file never declares binds to nothing.
- **Run `sudo kgsm-node-status`.** The hook restarts what it replaced and starts what became ready,
  and the report says what it did.

An administrator who disabled a unit keeps it disabled across every later version — presets are
applied on first install only, never on upgrade.

## 16. What not to do

- **Do not fill a blank key with a plausible value.** A node that starts and is wrong is worse than a
  node that has not started.
- **Do not `pacman -U -dd`.** It skips the dependency sort, and a scriptlet that runs before
  `50-kgsm.preset` exists falls through to Arch's `disable *` and lands its unit off. This affects
  hand-built testing only; a `pacman -S` from the repository always sorts correctly.
- **Do not build a component from source on a node**, and do not copy a binary from another machine.
  The package manager is the delivery path.
- **Do not weaken `SigLevel`.** `Required DatabaseRequired` is what makes the trust established in §3
  mean anything.
- **Do not run `kgsm` as the wrong account** (§14).
- **Do not report a state you did not measure.** `sudo kgsm-node-status` and `systemctl` are cheap.
