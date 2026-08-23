#!/usr/bin/env bash
#
# version.sh — print the version this repo declares.
#
#   ./deploy/version.sh            1.0.0
#   ./deploy/version.sh --pkgver   1.0.0   (the form pacman accepts: no hyphen)
#
# Every kgsm-* repo carries one of these so a package asks for a version rather than restating one.
# Here the declaration is the VERSION file at the repo root, because kgsm-base builds from no
# project: its payload is a handful of shipped files with no compiler to read a version out of.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE="${HERE}/../VERSION"

[[ -f "$FILE" ]] || { printf 'no VERSION file at %s\n' "$FILE" >&2; exit 1; }

version="$(tr -d '[:space:]' < "$FILE")"
[[ -n "$version" ]] || { printf 'VERSION is empty\n' >&2; exit 1; }

# A prerelease is written 1.0.0-rc1 here and 1.0.0rc1 to pacman. vercmp orders the stripped form
# before the release, so dropping the hyphen keeps a prerelease behind what it precedes.
if [[ "${1:-}" == "--pkgver" ]]; then
    printf '%s\n' "${version//-/}"
else
    printf '%s\n' "$version"
fi
