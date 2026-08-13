# kgsm-meta

The **pacman repository** for the KGSM ecosystem. Nodes install and upgrade every `kgsm-*`
component from here.

The packages, their signatures and the repository database are **release assets** on the `repo`
tag. That tag never moves; its assets are replaced in place on every publish, so the URL a node is
configured with is stable for the life of the fleet.

## Using it on a node

Trust the packaging key, then add the repository:

```bash
curl -fsSL https://github.com/TheKrystalShip/kgsm-meta/releases/download/repo/kgsm.gpg \
  | sudo pacman-key --add -
sudo pacman-key --lsign-key B7624435FAC1A8280B280CFBA6FBDB3B724DED1B
```

Append to `/etc/pacman.conf`:

```ini
[kgsm]
SigLevel = Required DatabaseRequired
Server = https://github.com/TheKrystalShip/kgsm-meta/releases/download/repo
```

Then `sudo pacman -Sy` and install the components this node runs. Every package belongs to the
`kgsm-node` group, so `pacman -S kgsm-node` lists them and takes a selection.

## What is here

This repository holds no source. Each component is built, packaged and signed by its own project's
CI, which publishes here. Source lives in the `kgsm-*` repositories under the same organisation.
