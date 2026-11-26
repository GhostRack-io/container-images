#!/bin/bash
# Builds stock images with podman, as images.toml describes them, and tags
# each localhost/ghostrack-images/<name>:<version>.
#
#   scripts/build.sh [NAME[:VERSION]...]     (every image without arguments)
#
# A bare name builds every version of it (debian: Debian 13 and 12).
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "${repo}/scripts/lib.sh"

command -v podman > /dev/null || { echo "build.sh: podman is not installed" >&2; exit 1; }
selected=$(select_images "$@")
revision=$(git -C "${repo}" rev-parse HEAD 2> /dev/null || echo unknown)

# nixos_root BASE VERSION DIRECTORY: build the locked upstream root archive
# and validate it before handing it to Podman for assembly.
nixos_root() {
    local base=$1 version=$2 directory=$3
    local builder=docker.io/nixos/nix:2.31.5@sha256:4ae3542b89e38bf739a98d9e1ffd082c3c7b8a6455ec0c2331560b9440aec442
    command -v zstd > /dev/null || { echo "build.sh: zstd is not installed" >&2; return 1; }
    # shellcheck disable=SC2016 # expanded in the Nix builder
    podman run --rm --platform linux/amd64 --entrypoint /bin/sh "${builder}" -euc '
        nix() { command nix --extra-experimental-features "nix-command flakes" "$@"; }
        actual=$(nix eval --no-update-lock-file --raw "$1#nixosConfigurations.ghostrack.config.system.nixos.release")
        if [ "${actual}" != "$2" ]; then
            echo "build.sh: flake release ${actual} does not match image version $2" >&2
            exit 1
        fi
        output=$(nix build --no-update-lock-file --no-link --print-out-paths "$1#packages.x86_64-linux.imageTarball")
        cat "${output}/tarball/nixos-ghostrack.tar.zst"
    ' sh "${base}" "${version}" > "${directory}/root.tar.zst"
    zstd -d -q -o "${directory}/root.tar" -- "${directory}/root.tar.zst"
    tar -tf "${directory}/root.tar" > /dev/null
    python3 - "${directory}/root.tar" << 'PYTHON'
import sys, tarfile

end_size = 2 * tarfile.BLOCKSIZE
with open(sys.argv[1], "rb") as root:
    size = root.seek(0, 2)
    if size < end_size or size % tarfile.BLOCKSIZE:
        sys.exit("build.sh: invalid root archive size")
    root.seek(0)
    with tarfile.open(fileobj=root, mode="r:") as archive:
        for _ in archive:
            pass
        # The terminator starts after the final member, including its padding.
        root.seek(archive.offset)
    if root.read(end_size) != bytes(end_size):
        sys.exit("build.sh: root archive is missing its end blocks")
    if any(block.strip(b"\0") for block in iter(lambda: root.read(64 * 1024), b"")):
        sys.exit("build.sh: root archive has nonzero data after its end blocks")
PYTHON
    sha256sum < "${directory}/root.tar.zst" | awk '{ print "build.sh: root archive sha256 " $1 }'
    rm -f "${directory}/root.tar.zst"
}

while IFS=$'\t' read -r -u 3 name version family _init _stop base display_name memory level _disk; do
    tag=$(image_tag "${name}" "${version}")
    echo "build.sh: ${tag} from ${base}"
    context=${repo}
    assembly=(--build-arg "BASE=${base}")
    if [[ ${family} == nixos ]]; then
        context=$(mktemp -d "${TMPDIR:-/tmp}/container-images-nixos.XXXXXX")
        trap 'rm -rf "${context}"' EXIT
        nixos_root "${base}" "${version}" "${context}"
        assembly=(--format oci --timestamp 1)
    fi
    podman build \
        "${assembly[@]}" \
        --platform linux/amd64 \
        --squash \
        --file "${repo}/images/${family}/Containerfile" \
        --build-arg "VERSION=${version}" \
        --build-arg "TITLE=${display_name}" \
        --build-arg "REVISION=${revision}" \
        --build-arg "MINIMUM_MEMORY_BYTES=${memory}" \
        --build-arg "X86_64_LEVEL=${level}" \
        --tag "${tag}" \
        "${context}"
    if [[ ${family} == nixos ]]; then
        rm -rf "${context}"
        trap - EXIT
    fi
done 3<<< "${selected}"
