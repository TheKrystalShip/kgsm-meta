# The acceptance test

`acceptance.sh` is the definition of done for the packaging mechanism: a fresh Arch host, one
command, a running node. It boots an Arch container with real systemd as PID 1, points it at a
repository built from the workspace, runs `bootstrap.sh`, and asserts what the node ends up being.

```bash
test/acceptance.sh                  # build the workspace's packages, then test
test/acceptance.sh --repo <dir>     # test a repository directory that already exists
test/acceptance.sh --keep           # leave the container up for inspection
```

## What it needs

- **docker, usable without sudo.** The test needs a booted systemd — presets, scriptlets, the
  post-transaction hook and unit start are all things a chroot cannot show you. `systemd-nspawn`
  would also do it and needs root, so this uses docker.
- **The `tks` workspace**, because with no `--repo` it calls `scripts/publish-repo.sh` to build the
  package set from each repo's publish output. A repo with no publish output is skipped and its
  package is simply absent from the test.
- **The packaging key's secret half.** The database is signed with the same key a node trusts, so
  the container runs at `SigLevel = Required DatabaseRequired` and the run exercises signature
  enforcement rather than stepping around it.

It touches nothing outside the container: `--cgroupns=private` gives the container its own cgroup
root, so a privileged init in there cannot see or act on this host's `kgsm.slice` or the game
servers under it, and the repository is bind-mounted read-only.

## Two things that are measured rather than asserted

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
