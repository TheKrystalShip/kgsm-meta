# The acceptance test

`acceptance.sh` is the definition of done for the packaging mechanism: a fresh Arch host, the
commands the README gives a person, a running node. It boots an Arch container with real systemd as
PID 1, points it at a repository, runs those commands, and asserts what the node ends up being.

```bash
test/acceptance.sh                  # build the workspace's packages, then test
test/acceptance.sh --repo <dir>     # test a repository directory that already exists
test/acceptance.sh --published      # test the published repository on GitHub Releases
test/acceptance.sh --keep           # leave the container up for inspection
```

## It runs the README, not a copy of it

The install block is extracted from `README.md` — the fenced block after the `<!-- node-install -->`
marker — and executed. A README that drifts from what works fails this test, which is the only way a
document stays true without somebody remembering to check it.

That block fetches `setup-node.sh` and pipes it into a shell, so the script is under test with it.
`--published` fetches it over the network the way a node does; the local modes pipe in the
checkout's copy. Piping rather than running a file is the shape that matters: a script that is
itself stdin leaves any command reading stdin eating the rest of it, and this is what proves
`setup-node.sh` does not.

Three things about the run differ from what a person types, and nothing else does:

- **The repository URL**, in the local modes only. `--repo` and the default hand the script
  `KGSM_REPO_URL` pointing at the `file://` directory under test, which covers both the key it
  fetches and the `Server` line it writes. `--published` leaves it alone. Nothing inside the script
  is rewritten.
- **`sudo`.** The container is PID-1 root and `archlinux:base` ships no sudo, so the one word a
  person needs and a root shell does not is dropped from the line.
- **`--noconfirm` on `pacman -S…`**. pacman asks a person to confirm a transaction and treats an
  unanswerable prompt as a refusal — measured: it exits 1 with the answer unread. The group install
  that follows the block is `pacman -S --noconfirm kgsm-node`, and pacman's own default for a group
  selection is every member, so that installs all of `kgsm-node`.

Two seams between the README and the script are checked before the container boots: the script must
still name the release URL, and the README must quote the fingerprint the script pins.

## What it needs

- **docker, usable without sudo.** The test needs a booted systemd — presets, scriptlets, the
  post-transaction hook and unit start are all things a chroot cannot show you. `systemd-nspawn`
  would also do it and needs root, so this uses docker.
- **The `tks` workspace**, because with no `--repo` and no `--published` it calls
  `scripts/publish-repo.sh` to build the package set from each repo's publish output. A repo with no
  publish output is skipped and its package is simply absent from the test.
- **The packaging key's secret half**, for the same case. The database is signed with the same key a
  node trusts, so the container runs at `SigLevel = Required DatabaseRequired` and the run exercises
  signature enforcement rather than stepping around it.

It touches nothing outside the container: `--cgroupns=private` gives the container its own cgroup
root, so a privileged init in there cannot see or act on this host's `kgsm.slice` or the game
servers under it, and the repository is bind-mounted read-only.

## Three things that are measured rather than asserted

- **Where `kgsm-keyring` came from.** No command in the test names it: it arrives because
  `kgsm-base` depends on it, and a repository serving an older `kgsm-base` delivers no keyring at
  all. The run reports which of the two it saw, and pacman's own install reason for it.
- **`kgsm-net-meter.service`** loads an eBPF program and attaches it to `kgsm.slice`. Its first run
  lands before `kgsm-watchdog` has created that slice — the unit is ordered after the watchdog's
  unit, which is not the same as after the slice exists — so it fails, and the second pass through
  the node-state logic attaches it. The test reports the state it reaches instead of asserting one,
  because a host without bpffs or without the kernel facilities would legitimately reach another.
- **The container's own failed units.** `systemd-firstboot.service` and `getty@tty1.service` fail in
  any container, and `systemd-networkd-wait-online.service` times out because networkd manages
  nothing here — it is pulled in by `network-online.target`, which the assistant and bot units want.
  The test records the failed set before installing anything and reports both, so a KGSM failure is
  read against that baseline rather than against zero.

## Running it in CI

Not wired, and two things stand in the way rather than one: it needs a **privileged container with
its own systemd**, which a GitHub-hosted runner cannot nest, and it needs **every package already
built**, which is a cross-repo operation no single project's workflow performs. A self-hosted runner
with docker would satisfy both.
