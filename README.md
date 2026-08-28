# kgsm-meta

Three things live here: the **pacman repository** every KGSM node installs from, **`kgsm-base`**,
the package holding what the whole fleet shares and no single component owns, and
**`kgsm-keyring`**, the keys that sign it all.

The packages, their signatures and the repository database are **release assets** on the `repo`
tag. That tag never moves; its assets are replaced in place on every publish, so the URL a node is
configured with is stable for the life of the fleet. `kgsm-base` is published like every other
project — on its own `v*` tag, by this repo's release workflow — and aggregated into the `repo` tag
from there.

## Installing a node

A node is a machine that has been told where the fleet's packages live and which key signs them;
pacman does the rest, and does it the same way it does for every other repository on the host. One
line does the telling:

<!-- node-install -->

```bash
curl -fsSL https://raw.githubusercontent.com/TheKrystalShip/kgsm-meta/main/setup-node.sh | sudo bash
```

Then install what this node runs:

```bash
pacman -S kgsm-node
```

Every component belongs to the `kgsm-node` group, so that one command prints the numbered member
list and prompts `Enter a selection (default=all):`, which takes ranges and gaps (`1 2 5 6 8 9`).
That prompt **is** the node's package selector — there is nothing here that wraps it, and pressing
enter takes the lot. `kgsm-base` and `kgsm-keyring` are deliberately outside the group: they arrive
as dependencies of whatever was selected, and offering them in the prompt would present a choice
that is not one.

Nothing else is asked of the machine. Each package applies the fleet's preset policy to its own
units, a post-transaction hook starts everything that is ready, and the operator is told the exact
keys still waiting on a person. Ask again at any time:

```bash
kgsm-node-status
```

**No package carries a credential.** A package ships its env file with the secrets blank and
`kgsm-node-status` names the ones a person still has to fill in — a value invented here would
produce a node that starts and is wrong, which is worse than one that has not started yet.

Upgrades from here are `pacman -Syu`, key rotation included.

### What `setup-node.sh` does, and doing it by hand instead

It initialises pacman's keyring, fetches the packaging key, refuses it unless it carries the
fingerprint written into the script, locally signs it, appends the `[kgsm]` section to
`/etc/pacman.conf` and runs `pacman -Syu`. It configures pacman and stops there: no unit is written,
no component is chosen, no credential is invented. `--no-upgrade` stops it before the sync, and
`KGSM_REPO_URL` points the whole of it at a different repository. Piped into a shell, a flag needs
`-s --` so bash hands it to the script rather than reading it as its own:
`curl -fsSL <url> | sudo bash -s -- --no-upgrade`.

**The first step is the one nothing verifies.** Everything pacman fetches afterwards is checked
against the key trusted here, which is what makes verification mean anything. A script fetched over
the network cannot vouch for itself, though — whoever could serve a different key could serve a
different copy of the script, carrying a different fingerprint. Reading it before running it, or
comparing the fingerprint against a copy obtained some other way, is what closes that gap. As root,
the same steps are:

```bash
pacman-key --init
curl -fsSL https://github.com/TheKrystalShip/kgsm-meta/releases/download/repo/kgsm.gpg | pacman-key --add -
pacman-key --lsign-key B7624435FAC1A8280B280CFBA6FBDB3B724DED1B

cat >> /etc/pacman.conf <<'EOF'

[kgsm]
SigLevel = Required DatabaseRequired
Server = https://github.com/TheKrystalShip/kgsm-meta/releases/download/repo
EOF

pacman -Syu
```

`--lsign-key` names the fingerprint explicitly and fails if the fetched asset carries some other key,
so a substituted file is refused rather than trusted without comment. `SigLevel` is `Required`, not
`Optional`: an unsigned or wrongly-signed package is refused rather than warned about. The tag never
moves, so that URL is stable for the life of the fleet.

## `kgsm-keyring`

The public halves of the keys that sign the fleet's packages, in the three files `pacman-key` reads:
`/usr/share/pacman/keyrings/kgsm.gpg`, `kgsm-trusted` (fingerprint and trust level) and
`kgsm-revoked` (empty while no key has been retired — it ships anyway, because a file that first
appears at the moment of a revocation is a file nobody has ever exercised). Its scriptlet runs
`pacman-key --populate kgsm` on install and on every upgrade, guarded on the keyring being
initialised so a chroot or an image build gets a message instead of a failed transaction.

It exists so that **key rotation is a package upgrade**. Adding or revoking a key becomes a new
version of this package, signed by a key the node already trusts and delivered by `pacman -Syu`.

**`kgsm-base` depends on it**, so every node that runs anything at all carries it and takes key
changes with its ordinary upgrades. That dependency is safe precisely because it is not the node's
*first* trust decision: by the time pacman resolves it, the packaging key is in the keyring and
locally signed, so `kgsm-keyring` verifies like any other package. The first trust cannot come from
a package — pacman refuses a signed package whose key it has no trust path to, and `pacman -U <url>`
does not escape that either, since `LocalFileSigLevel` is `TrustedOnly` — which is what the
`pacman-key --add` / `--lsign-key` pair above is for.

It versions on its own clock, so it has its own directory (`packaging/keyring/`) rather than being a
second package in `kgsm-base`'s PKGBUILD, which would share one `pkgver`. Its tag prefix is
`keyring-v*`, and the release workflow's `package-keyring` job asserts the tag against the literal
`pkgver` in that PKGBUILD. The key itself is committed **armored**, at `keyring/kgsm.asc`, so what
is being trusted is readable in a diff; the PKGBUILD dearmors it and refuses to build a keyring
carrying a secret key or a fingerprint the trust list does not name.

## `kgsm-base`

`kgsm-base` is a hard dependency of every package that ships a systemd unit, so it is installed
before any of them. It is deliberately **not** in the `kgsm-node` group: it arrives as a dependency
of whatever was selected, and offering it in the selection prompt would present a choice that is
not one. Its payload:

| Path | What it is |
|---|---|
| `/usr/lib/sysusers.d/kgsm.conf` | the `kgsm` service account every unit runs as |
| `/usr/lib/tmpfiles.d/kgsm.conf` | `/var/lib/kgsm` and its `events/`, `leaves/`, `leaves/commands/` and `auth/` |
| `/etc/kgsm/kgsm-auth.env` | the shared sign-in application, keys blank, in `backup=()` |
| `/usr/lib/systemd/system-preset/50-kgsm.preset` | which units a node runs |
| `/usr/bin/kgsm-node-status` | what this node runs, and what still needs a person |
| `/usr/lib/kgsm-base/node-state.sh` | the readiness derivation both tools share |
| `/usr/lib/kgsm-base/apply-node-state` | the hook's action half |
| `/usr/share/libalpm/hooks/zz-kgsm-node-apply.hook` | runs it, PostTransaction |

Source is `base/`, installed verbatim — nothing here is built or rendered.

**The account and the state tree are here rather than in `kgsm`** because several packages write
into them and none owns them. Declaring them on the engine would make the engine's presence a
precondition for a leaf's state directory, and a node can run `kgsm-monitor` with no engine at all.

**`/etc/kgsm/kgsm-auth.env` ships as a real file with blank values.** Three leaves load it with
`EnvironmentFile=-`, so a host that signs nobody in through a provider still needs it to exist to
be filled in later. No package may carry a credential, and `kgsm-node-status` reports it separately
from the keys that actually block a unit — a host whose people sign in with a KGSM password needs
nothing in it.

**A secret a service mints for itself is reported, never left to be discovered.** A package that
creates the first administrator on its first start writes that one-time password to
`/var/lib/<package>/initial-admin-password`, and `kgsm-node-status` names the file for as long as it
is there — read it as root, sign in, change the password, delete it. A key a service can generate for
itself is commented out in its env example instead of shipped blank, and the readiness scan counts
only an uncommented blank key, so such a unit is ready on a fresh node with nothing asked of a
person. What remains in the report is the credentials only a person can supply.

## Enabling and starting: what happens where, and why

The split is not stylistic. `systemctl preset` is symlink manipulation on disk and works with no
running system; `systemctl start` needs one.

- **Each package presets its own units in `post_install`.** Arch's `99-default.preset` is
  `disable *`, so without `50-kgsm.preset` every unit would land disabled. The first matching entry
  across preset files wins and they are read in lexical order, so `50-` decides the KGSM units and
  touches nothing else on the host.
- **`post_install` only, never `post_upgrade`.** An administrator who disabled something keeps it
  disabled across every later version.
- **Starting is the `zz-kgsm-node-apply` hook's**, PostTransaction. The `zz-` prefix is
  load-bearing: alpm runs hooks in filename order and systemd's own — `20-systemd-sysusers`,
  `21-systemd-tmpfiles`, `30-systemd-daemon-reload` — must all have run first. Measured on a real
  transaction, it lands last, `(5/5)`.
- **The hook starts a unit only when it is enabled, stopped, and its package's env file holds no
  outstanding keys.** It restarts an already-running unit whose package this transaction replaced.
  A socket-activated pair comes down together and the socket is re-armed, because the daemon holds
  the old binary until it exits.
- **Nothing there can fail a transaction.** Every `systemctl` call is tolerated and reported, and a
  chroot, an image build or a container without an init gets the report and no action at all.

**A hook installed by `kgsm-base` in the same transaction DOES fire for that transaction** —
measured in a sandboxed pacman root: pacman reads its hook directories after the package changes
are applied, so a first install of the whole fleet is covered by the hook it just laid down. On a
host where the transaction ran with no systemd to act on — an image build, a chroot — the report
says so and `/usr/lib/kgsm-base/apply-node-state` run once with a booted system does the starting.

**A node upgrading from a `kgsm` that owned the shared files needs nothing done by hand.** Those two
paths move from `kgsm` to `kgsm-base`, which is a file conflict only when the two halves land in
different transactions — and they cannot, because the new `kgsm` depends on `kgsm-base`. Measured in
a sandboxed root: an old `kgsm` owning both, upgraded alongside the new pair, passes the file-conflict
check, installs `kgsm-base` first, and leaves `kgsm` owning neither.

**`kgsm-base` must be installed before the packages whose scriptlets preset their units.** pacman
sorts a transaction by dependency order and every unit-shipping package depends on it, so it is —
verified, it installs first out of fifteen. `pacman -U -dd` skips that sort and installs in
command-line order; a scriptlet running before `50-kgsm.preset` exists falls through to `disable *`
and its unit lands off. That affects hand-built testing only, never a `pacman -S` from the
repository.

## Version and changelog

`VERSION` at the repo root declares the version; `deploy/version.sh` prints it, and `--pkgver`
prints the pacman-safe form. The PKGBUILD asks for it rather than restating one, the same as every
other repo. `CHANGELOG.md` carries an entry per release. A `v*` tag matching `VERSION` builds,
signs and publishes the package — the workflow refuses a tag that disagrees.

`kgsm-keyring` is outside that line. Its `pkgver` is declared literally in
`packaging/keyring/PKGBUILD` and moves when a key moves, so it publishes on `keyring-v*` and is
asserted against that literal.

The release workflow is **generated**: edit `tks/scripts/ci-template/` and re-run `vendor-ci.sh`,
never `.github/workflows/release.yml` here. `kgsm-base` builds nothing, so its build job is
`shellcheck` over the shell payloads.

## Aggregation: tag a release, the fleet has it

Each project's own release workflow builds, signs and publishes its package to **its own** release.
Aggregating those into the `[kgsm]` database this repo serves is `.github/workflows/aggregate.yml`,
which runs `ci/aggregate.sh` here. No person and no workstation is in that path.

The script seeds a staging directory from the `repo` tag's current assets — which is what preserves
a package no per-repo release supersedes, such as the hand-built `libdave` — overlays the newest
release from every sibling across all of its tag families, selects the newest of each package name
with `vercmp`, rebuilds `kgsm.db` across that set, signs it with the packaging key, and clobbers the
assets on the `repo` tag. Rebuilding across the whole set rather than amending is what makes
publishing one project safe: an incremental add would drop every package the run did not collect.

Three properties worth knowing:

- **It is idempotent.** The rebuilt database is compared against the served one by package set and
  version, not by bytes or timestamps, and an unchanged set uploads nothing. A run that has no work
  is cheap, which is what makes a frequent schedule reasonable.
- **The schedule is the guarantee, not the mechanism.** It runs every 15 minutes, so a release is
  in the fleet's database within that window with nothing configured anywhere.
- **A dispatch makes it immediate.** Every repo's release workflow fires a `repository_dispatch` at
  this one as its last step, using the `KGSM_META_DISPATCH_TOKEN` secret — a cross-repo dispatch
  cannot use a workflow's own `GITHUB_TOKEN`. The step is best-effort: with no such secret it says
  so and exits 0, and the schedule picks the release up instead. Creating that token (a fine-grained
  PAT with contents write on `kgsm-meta`, stored as an organisation secret) is the only thing that
  turns "within 15 minutes" into "within seconds".

Superseded package files stay in the release deliberately. pacman only ever fetches what the
database names, and the older assets are the rollback path.

`tks/scripts/publish-repo.sh` does the same aggregation from a workstation, and with no flag
packages the local workspace instead — which is what a dev host wants and what the acceptance test
builds its repository from.

## What is here

No component source. Each is built, packaged and signed by its own project's CI, which publishes
here. Source lives in the `kgsm-*` repositories under the same organisation. The `base/` payload and
the `keyring/` key material are the exceptions — they belong to the fleet rather than to any one
component.

`test/acceptance.sh` proves the whole mechanism end-to-end: it builds the workspace's packages into
a local repository, boots an Arch container with real systemd, runs **the install block above**
against that repository, and asserts what the node ends up running. It extracts that block from this
file rather than restating it, so a README that drifts from what works fails the test.
`test/README.md` states what it needs.
