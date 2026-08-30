# Changelog

## [1.5.0]

### Added — `/var/lib/kgsm/cluster/`

The shared state tree gains `cluster/`, for what several members of a cluster on one machine share.
Declared here rather than by whichever member is installed first, like every other path in that tree.

A member's own roster, outbox and inbox are deliberately not in it. Each member keeps those under its
own unit's `StateDirectory=`, which systemd creates owned by that unit's user — so two members on one
machine share nothing that would make one's membership depend on the other's process.

## [1.4.0]

### Added — `setup-node.sh`, one line that configures pacman

```bash
curl -fsSL https://raw.githubusercontent.com/TheKrystalShip/kgsm-meta/main/setup-node.sh | sudo bash
```

It initialises the keyring, fetches the packaging key, reads the fingerprints out of the fetched
file with `gpg --show-keys` and refuses anything that does not carry the pinned one, locally signs
it, writes the `[kgsm]` section and runs `pacman -Syu`. Then `pacman -S kgsm-node`, whose group
prompt is still the whole of the package selection.

It configures pacman and stops there. No unit is written, no component is chosen and no credential
is invented, so the reasons the previous script was not worth keeping do not apply: it wraps no
pacman prompt, re-runs no hook and maintains no second list of what a node installs.

Refusing before importing is the difference from doing it by hand. `pacman-key --add` followed by
`--lsign-key <fingerprint>` also refuses a substituted key, but only after that key is in the
keyring; reading the fingerprints out of the file first means it never gets there.

What the script cannot do is vouch for itself, and the README says so rather than implying the
one-liner is equivalent to the by-hand form. Whoever could serve a different key could serve a
different copy of the script carrying a different fingerprint. The by-hand steps stay in the README
for the reader who wants that gap closed by comparing the fingerprint out of band.

`exec </dev/null` is load-bearing. Piped into `bash` the script is stdin, so any command inside it
that read stdin would consume the rest of it — which is also why the key goes to a temporary file
and never to `pacman-key --add -`.

### Changed — the acceptance test runs the one-liner

The `<!-- node-install -->` block is the `curl … | bash` line, so extracting and running it puts
`setup-node.sh` under test too, piped in exactly as a person pipes it. `--published` fetches the
script over the network; the local modes pipe in the checkout's copy and hand it `KGSM_REPO_URL`.
`sudo` is dropped because the container is root and `archlinux:base` has none.

Two seams are checked before the container boots: `setup-node.sh` must still name the release URL,
and the README must quote the fingerprint the script pins. The assertions themselves are unchanged.

## [1.3.0]

### Changed — `kgsm-base` depends on `kgsm-keyring`

Key rotation now reaches a node with nothing asked of it. Every unit-shipping package depends on
`kgsm-base`, so one edge puts the keyring on every node in the fleet and each later `pacman -Syu`
carries whatever the trusted set has become.

The rule this replaces — *nothing depends on the keyring, and nothing may* — was drawn too wide. The
circularity is real only for a node's **first** trust decision: pacman refuses a signed package whose
key it has no trust path to, so a keyring fetched before any key is trusted is unverifiable. Once the
packaging key is in the keyring and locally signed, `kgsm-keyring` verifies like any other package
and resolving it as a dependency is ordinary. That first decision stays where it has to be — a person
running `pacman-key --add` and `--lsign-key` — and the acceptance test measures the difference: no
command names `kgsm-keyring`, and it is installed as a dependency anyway.

### Removed — `bootstrap.sh`

The README is the installer. Node setup is one root block — `pacman-key --init`, trust the packaging
key, append `[kgsm]` to `/etc/pacman.conf`, `pacman -Syu` — and then `pacman -S kgsm-node`, whose own
group prompt is the package selector. Every line `bootstrap.sh` held was pacman's job done a second
way: the repository stanza, the key import, a selection menu over `pacman -Sg`, and a re-run of the
hook that had already fired.

Its two load-bearing comments survive as prose in the README: why the first trust cannot be
delivered by a package, and why no package seeds a credential.

`test/acceptance.sh` extracts that block from `README.md` and runs it, so the documented commands are
the tested ones and a README that drifts fails the test. The nineteen assertions are unchanged. Local
modes rewrite the release URL to the `file://` repository under test and add `--noconfirm`, because
pacman treats an unanswerable prompt as a refusal; nothing else about the block is altered.

The `bootstrap.sh` release asset is gone from the `repo` tag, and `publish-repo.sh` no longer
uploads one. `kgsm.gpg` stays — it is what the first trust decision fetches.

### Added — `ci/aggregate.sh` and the `aggregate` workflow

The fleet's database rebuilds itself. `.github/workflows/aggregate.yml` runs `ci/aggregate.sh` on a
`repository_dispatch` from any project's release, on `workflow_dispatch`, and every fifteen minutes;
it seeds a staging directory from the `repo` tag's current assets, overlays the newest release of
every sibling across each of its tag families, selects the newest of each package name with
`vercmp`, rebuilds and signs `kgsm.db`, and clobbers the assets on the `repo` tag. Tagging a release
is now the whole of shipping it.

Seeding from the current assets is what keeps a package no per-repo release supersedes — `libdave`,
built by hand — in the database. The run is idempotent: the rebuilt set is compared with the served
one by package name and version rather than by bytes, which differ on every rebuild, and an
unchanged set uploads nothing. Only package files the seed did not already contain are uploaded, so
a run that collected one new package does not re-push the rest.

Each repo's release workflow fires the dispatch as a best-effort last step, using the
`KGSM_META_DISPATCH_TOKEN` organisation secret — a cross-repo dispatch cannot use a workflow's own
`GITHUB_TOKEN`. Where that secret is absent the step says so and exits 0, and the schedule covers
the release within fifteen minutes.

## [1.2.0]

### Added — `kgsm-keyring`, so rotating a key is an upgrade

`packaging/keyring/` builds `kgsm-keyring`: the public halves of the keys that sign the fleet's
packages, in the three files `pacman-key` reads — `/usr/share/pacman/keyrings/kgsm.gpg`,
`kgsm-trusted` and `kgsm-revoked` — with a scriptlet that runs `pacman-key --populate kgsm` on
install and on every upgrade, guarded on the keyring being initialised so a chroot gets a message
rather than a failed transaction. Adding or revoking a key is a new version of this package, signed
by a key the node already trusts.

Nothing depends on it and nothing may: a node's first trust decision cannot come from a package,
because pacman refuses a signed package whose key it has no trust path to. `bootstrap.sh` makes that
decision — fetch `kgsm.gpg`, assert the fingerprint is
`B7624435FAC1A8280B280CFBA6FBDB3B724DED1B`, `pacman-key --add` and `--lsign-key` — and installs this
package straight after the first `pacman -Sy`. The key is committed armored at `keyring/kgsm.asc` so
what is trusted is readable in a diff; the PKGBUILD dearmors it and refuses to build a keyring
carrying a secret key or a fingerprint the trust list does not name.

It versions on its own clock, so it publishes on `keyring-v*` with its own job in the release
workflow, asserted against the literal `pkgver` in its PKGBUILD.

### Added — `test/acceptance.sh`

The end-to-end proof, as a script rather than a transcript. It boots `archlinux:base-devel` with
real systemd as PID 1, bind-mounts a repository built from the workspace, runs `bootstrap.sh --all
--start` against it, and asserts nineteen things about what the node becomes — the units that are
active, the one that is blocked and on which key, the modes of the three secrets the packages minted
for themselves, and that the first administrator signs in with the password left in its file. The
database is signed with the real packaging key rather than the repository being dropped to
`SigLevel = Never`, so it exercises verification instead of stepping around it. `test/README.md`
states what it needs and what it measures rather than asserts.

### Added — `KGSM_REPO_URL`

`bootstrap.sh` takes the repository URL from the environment, which is what lets the acceptance test
point a container at a local `file://` directory. It changes where packages come from and nothing
about how they are verified.

### Changed — the fetched key is checked before it is signed

`curl` reporting success proves a file arrived, not which one. `bootstrap.sh` asserts the
fingerprint is in the keyring before `--lsign-key`, and prints it for a person to compare against a
copy obtained some other way — this is the one step that is not itself verified, and it is what
makes verification mean anything.

## [1.1.0]

### Added — the first administrator's password is part of the report

`kgsm-node-status` names the one-time password a package left for the first person to sign in:
`/var/lib/<package>/initial-admin-password`, with the instruction to read it as root, sign in,
change the password and delete the file. The file exists only between the first start that created
that account and a person collecting it, so a node past that point sees nothing about it. The
derivation follows the state-directory convention rather than a list of packages, so it holds for
any component that mints one.

The keys a service generates for itself are commented out in its env example, and the readiness scan
counts only an uncommented blank key — so a self-completing service is `ready` on a fresh node with
nothing asked of a person.

## [1.0.0]

### Added — `kgsm-base`, the package the fleet shares

`packaging/PKGBUILD` builds `kgsm-base` from the files in `base/`. It carries what several packages
write and none owns — the `kgsm` service account, the `/var/lib/kgsm` tree, the shared sign-in file
— plus the systemd preset policy for the whole fleet and the two tools that decide what a node is
ready to run. Every package that ships a unit depends on it, so it is installed first.

`50-kgsm.preset` enables the watchdog, the monitor, the scheduler, the reactor, the network meter,
the journal-prune timer, the API, the bot and the assistant, and the firewall and speech **sockets**
rather than their services. It disables the RAG indexer and the llama.cpp units, which are decisions
rather than defaults.

`/usr/bin/kgsm-node-status` reports what this node runs and the exact env keys still waiting on a
person, derived from what pacman installed rather than from a list. `zz-kgsm-node-apply.hook` runs
`apply-node-state` PostTransaction, which starts what is ready and restarts what this transaction
replaced. Both read one derivation, `node-state.sh`, so the report and the action cannot disagree.

### Added — a version convention

`VERSION` declares this repo's version and `deploy/version.sh` prints it, matching every other
`kgsm-*` repo. `.github/workflows/release.yml` (generated by `tks/scripts/ci-template/vendor-ci.sh`)
builds, signs and publishes the package on a `v*` tag, gated on `shellcheck` over the shell payload.

### Changed — `bootstrap.sh` reports through the installed tool

It calls `kgsm-node-status` instead of deriving the same buckets itself, and `--start` delegates to
`apply-node-state` — the same logic the post-transaction hook runs. Enabling and starting are the
packages' job now, so the script neither enables nor holds a list of opt-in units.
