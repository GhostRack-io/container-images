#!/bin/bash
# Builds the Arch Linux image from an old base and runs tests/structure.sh
# on it. The base is the official image of 2025-09-07, by digest: its
# keyring does not know the packagers who have signed Arch's packages since,
# so the build's upgrade fails (an "unknown trust" error) unless it upgrades
# the keyring package first. A base pinned in images.toml is up to a month
# old when CI rebuilds the image, and a package signed by a new packager
# fails the same way.
#
#   tests/arch-stale-base.sh
#
# Needs podman, python3, readelf (binutils) and network access (the upgrade
# downloads about a gigabyte). The image is tagged
# localhost/ghostrack-stale-base/archlinux:rolling, not where
# scripts/build.sh puts the real one.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "${repo}/scripts/lib.sh"

base=docker.io/library/archlinux:base-20250907.0.417472@sha256:fc6a7997e569e600cac7b69ccc322515b72fddbdb388e978faa3c0f12bd13dae
tag=localhost/ghostrack-stale-base/archlinux:rolling

command -v podman > /dev/null || { echo "arch-stale-base.sh: podman is not installed" >&2; exit 1; }
IFS=$'\t' read -r name version family _init _stop _base display_name memory level < <(select_images archlinux:rolling)
echo "arch-stale-base.sh: ${name}:${version} from ${base}"
podman build \
    --platform linux/amd64 \
    --squash \
    --file "${repo}/images/${family}/Containerfile" \
    --build-arg "BASE=${base}" \
    --build-arg "VERSION=${version}" \
    --build-arg "TITLE=${display_name}" \
    --build-arg "REVISION=$(git -C "${repo}" rev-parse HEAD 2> /dev/null || echo unknown)" \
    --build-arg "MINIMUM_MEMORY_BYTES=${memory}" \
    --build-arg "X86_64_LEVEL=${level}" \
    --tag "${tag}" \
    "${repo}"
STRUCTURE_IMAGE=${tag} "${repo}/tests/structure.sh" "${name}:${version}"
