#!/bin/bash
# Exercises the NixOS archive check through scripts/build.sh, with a
# stand-in for the Nix builder and OCI assembly. Needs Python and zstd.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/container-images-nixos-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

mkdir "${work}/bin"
cat > "${work}/bin/podman" <<'PODMAN'
#!/bin/bash
set -euo pipefail
case $1 in
    run) cat "${FIXTURE_ARCHIVE}" ;;
    build) touch "${FIXTURE_ASSEMBLED}" ;;
    *) exit 2 ;;
esac
PODMAN
chmod +x "${work}/bin/podman"
export PATH="${work}/bin:${PATH}"
export FIXTURE_ASSEMBLED="${work}/assembled"

python3 - "${work}" <<'PYTHON'
import io, sys, tarfile
from pathlib import Path

work = Path(sys.argv[1])
for name, tar_format in (("gnu", tarfile.GNU_FORMAT), ("pax", tarfile.PAX_FORMAT)):
    data = bytes(1024)
    member = tarfile.TarInfo("path/" + "a" * 120)
    member.size = len(data)
    with tarfile.open(work / f"{name}-complete.tar", "w", format=tar_format) as archive:
        archive.addfile(member, io.BytesIO(data))
        end = archive.offset
    complete = (work / f"{name}-complete.tar").read_bytes()
    for blocks in (0, 1):
        (work / f"{name}-{blocks}-end-blocks.tar").write_bytes(complete[:end + blocks * 512])
PYTHON

for archive in "${work}"/*.tar; do
    zstd -q -- "${archive}"
    export FIXTURE_ARCHIVE="${archive}.zst"
    rm -f "${FIXTURE_ASSEMBLED}"
    case ${archive} in
        *-complete.tar)
            "${repo}/scripts/build.sh" nixos:26.05
            [[ -f ${FIXTURE_ASSEMBLED} ]]
            ;;
        *)
            if "${repo}/scripts/build.sh" nixos:26.05 > "${work}/build.log" 2>&1; then
                echo "nixos-archive.sh: $(basename "${archive}") passed validation" >&2
                exit 1
            fi
            [[ ! -e ${FIXTURE_ASSEMBLED} ]]
            grep -Fq 'root archive is missing its end blocks' "${work}/build.log" || {
                cat "${work}/build.log" >&2
                exit 1
            }
            ;;
    esac
done
echo "nixos-archive.sh: archive checks passed"
