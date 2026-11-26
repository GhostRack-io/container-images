# shellcheck shell=bash
# Shared by the scripts and tests: images.toml as tab-separated lines, and
# the local tag of a built image. Source it after setting ${repo}.

# images_tsv: one line per image of images.toml, checked, in its order:
# name, version, family, init, stop signal, base, display name, minimum
# memory in bytes, x86-64 level, minimum disk in bytes (or - when unset),
# separated by tabs.
images_tsv() {
    # shellcheck disable=SC2154 # the sourcing script sets repo
    python3 - "${repo}/images.toml" << 'PYTHON'
import re, sys, tomllib

FIELDS = ["name", "version", "family", "init", "stop_signal", "base", "display_name",
          "minimum_memory_bytes", "x86_64_level"]
DISK = "minimum_disk_bytes"
MIB = 1048576
INITS = {"systemd": ("debian", "ubuntu", "rhel", "arch", "nixos"), "openrc": ("alpine",)}
STOP = {"systemd": 37, "openrc": 12}

def die(message):
    sys.exit(f"images.toml: {message}")

with open(sys.argv[1], "rb") as source:
    images = tomllib.load(source).get("image", [])
if not images:
    die("no [[image]] entry")
seen = set()
for image in images:
    if set(image) - {DISK} != set(FIELDS):
        die(f"an entry must have {sorted(FIELDS)} and may have {DISK}")
    key = f"{image['name']}:{image['version']}"
    if not re.fullmatch(r"[a-z0-9]+", image["name"]) or not re.fullmatch(r"[0-9][0-9.]*|edge|rolling", image["version"]):
        die(f"{key}: the name or the version is not a plain tag")
    if key in seen:
        die(f"{key} is listed twice")
    seen.add(key)
    if image["family"] not in INITS.get(image["init"], ()):
        die(f"{key}: init {image['init']} does not fit family {image['family']}")
    if image["stop_signal"] != STOP[image["init"]]:
        die(f"{key}: the stop signal of {image['init']} is {STOP[image['init']]}")
    if image["family"] == "nixos":
        if DISK not in image:
            die(f"{key}: {DISK} is required for NixOS")
        if not re.fullmatch(r"github:GhostRack-io/nixos-ghostrack/[0-9a-f]{40}", image["base"]):
            die(f"{key}: the base is not the GhostRack-io/nixos-ghostrack flake pinned by commit")
    elif not re.fullmatch(r"docker\.io/[a-z0-9._/-]+:[a-z0-9._-]+@sha256:[0-9a-f]{64}", image["base"]):
        die(f"{key}: the base is not a Docker Hub image by tag and digest")
    if not image["display_name"] or any(c in image["display_name"] for c in "\t\r\n"):
        die(f"{key}: the display name is empty or holds a tab or newline")
    memory = image["minimum_memory_bytes"]
    if type(memory) is not int or memory % MIB or memory < 256 * MIB:
        die(f"{key}: minimum_memory_bytes is not a whole number of MiB, at least 256 MiB")
    level = image["x86_64_level"]
    if type(level) is not int or level not in (1, 2, 3, 4):
        die(f"{key}: x86_64_level is not 1, 2, 3 or 4")
    disk = image.get(DISK, "-")
    if DISK in image and (type(disk) is not int or not 0 < disk <= 2**63 - 1 or disk % MIB):
        die(f"{key}: {DISK} is not a positive whole number of MiB in signed 64-bit range")
    print("\t".join([*(str(image[field]) for field in FIELDS), str(disk)]))
PYTHON
}

# image_tag NAME VERSION: the tag scripts/build.sh gives the image.
image_tag() {
    echo "localhost/ghostrack-images/$1:$2"
}

# select_images [NAME[:VERSION]...]: the lines of images_tsv the arguments
# name (a bare name selects every version of it), all of them without
# arguments; an argument that selects nothing is an error.
select_images() {
    local all line want found
    all=$(images_tsv) || return 1
    if [[ $# == 0 ]]; then
        echo "${all}"
        return
    fi
    for want in "$@"; do
        found=
        while IFS= read -r line; do
            local name=${line%%$'\t'*} rest=${line#*$'\t'}
            local version=${rest%%$'\t'*}
            if [[ ${want} == "${name}" || ${want} == "${name}:${version}" ]]; then
                echo "${line}"
                found=1
            fi
        done <<< "${all}"
        [[ -n ${found} ]] || { echo "no image ${want} in images.toml" >&2; return 1; }
    done
}
