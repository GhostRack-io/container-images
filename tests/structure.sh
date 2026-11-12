#!/bin/bash
# Checks built stock images without booting them: no host keys and no
# machine ID in them, the SSH policy, the masked units, the services
# enabled at boot, the init at the command's path, the x86-64 level its
# C library and init need, the image's config.
#
#   tests/structure.sh [NAME[:VERSION]...]   (every image without arguments)
#
# Each image is the one scripts/build.sh tagged
# (localhost/ghostrack-images/<name>:<version>), or STRUCTURE_IMAGE=REF for
# a single NAME:VERSION. Needs podman, python3 and readelf (binutils).
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "${repo}/scripts/lib.sh"

for tool in podman python3 readelf; do
    command -v "${tool}" > /dev/null || { echo "structure.sh: ${tool} is not installed" >&2; exit 1; }
done
selected=$(select_images "$@")
if [[ -n ${STRUCTURE_IMAGE:-} && $(wc -l <<< "${selected}") != 1 ]]; then
    echo "structure.sh: STRUCTURE_IMAGE names one image; select one NAME:VERSION" >&2
    exit 1
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/container-images-structure.XXXXXX")
trap 'rm -rf "${work}"' EXIT
masked_units=$(grep -v -E '^(#|$)' "${repo}/common/masked-units" | tr '\n' ' ')
failures=0

fail() {
    echo "  FAIL: $*"
    failures=$((failures + 1))
}

# The checks inside the image, as POSIX sh: one "FAIL ..." line each that
# fails. The arguments: the init system, the family, the version, then the
# units to see masked.
# shellcheck disable=SC2016 # expanded by the image's shell
inside='
set -u
init=$1
family=$2
version=$3
shift 3
fail() { echo "FAIL $*"; }
for key in /etc/ssh/ssh_host_*; do
    [ -e "${key}" ] && fail "host key ${key} in the image"
done
if [ "${init}" = systemd ]; then
    [ -f /etc/machine-id ] && [ ! -s /etc/machine-id ] || fail "/etc/machine-id is not an empty file"
else
    [ ! -s /etc/machine-id ] || fail "/etc/machine-id is not empty"
fi
if [ -e /var/lib/dbus/machine-id ] || [ -L /var/lib/dbus/machine-id ]; then
    fail "/var/lib/dbus/machine-id is in the image"
fi
# Nothing of one instance is shared by all: no random seed, no keys or
# password hashes.
for path in /var/lib/systemd/random-seed /var/lib/seedrng /var/lib/systemd/credential.secret /root/.ssh/*; do
    [ -e "${path}" ] && fail "${path} is in the image"
done
awk -F: '\''$2 ~ /^\$/ { print $1 }'\'' /etc/shadow | while read -r user; do
    fail "${user} has a password hash"
done
[ -x /sbin/init ] || fail "/sbin/init is not an executable"
for path in /boot/vmlinuz /usr/sbin/NetworkManager /usr/bin/cloud-init /etc/netplan /usr/sbin/chronyd /usr/sbin/dhclient; do
    [ -e "${path}" ] && fail "${path} is in the image"
done
for tool in ip ping curl less vi ps sudo crontab ssh-keygen; do
    command -v "${tool}" > /dev/null || fail "no ${tool}"
done
[ -f /etc/ssl/certs/ca-certificates.crt ] || [ -f /etc/pki/tls/certs/ca-bundle.crt ] || fail "no CA certificates"
[ -e /usr/share/zoneinfo/UTC ] || fail "no time zone data"
if [ "${init}" = systemd ]; then
    if [ -d /run/lock ] && [ ! -L /run/lock ] && [ -n "$(find /run/lock -mindepth 1 -print -quit)" ]; then
        fail "/run/lock contains build-time runtime state"
    fi
    for unit in "$@"; do
        [ "$(readlink "/etc/systemd/system/${unit}")" = /dev/null ] || fail "${unit} is not masked"
    done
    if [ -e /etc/systemd/system/ghostrack-ssh-host-keys.service ]; then
        enabled="ghostrack-ssh-host-keys.service ssh.service cron.service"
    elif [ "${family}" = arch ]; then
        enabled="sshd.service cronie.service ghostrack-pacman-init.service"
    else
        enabled="sshd.service crond.service"
    fi
    for unit in ${enabled}; do
        [ "$(systemctl is-enabled "${unit}" 2> /dev/null)" = enabled ] || fail "${unit} is not enabled"
    done
    # (systemctl cat needs a running systemd; is-enabled reads the files.)
    for unit in ssh.socket dnf-makecache.timer; do
        if [ -e "/usr/lib/systemd/system/${unit}" ] || [ -e "/lib/systemd/system/${unit}" ]; then
            [ "$(systemctl is-enabled "${unit}" 2> /dev/null)" != enabled ] || fail "${unit} is enabled"
        fi
    done
else
    grep -q -E "^(tty|ttyS|console)[0-9]*::respawn" /etc/inittab && fail "/etc/inittab starts a getty"
    for service in sshd crond; do
        [ -e "/etc/runlevels/default/${service}" ] || fail "${service} is not in the default runlevel"
    done
    for level in /etc/runlevels/*; do
        [ -e "${level}/networking" ] && fail "networking is in the runlevel ${level##*/}"
    done
    grep -q "^root:[!]" /etc/shadow && fail "root is locked, which refuses its keys"
    # Alpine edge stays on edge; a release stays on its release.
    if [ "${version}" = edge ]; then
        grep -v "^#" /etc/apk/repositories | grep -q -E "/(v[0-9]+[.][0-9]+|latest-stable)/" && fail "/etc/apk/repositories names a release"
        grep -v "^#" /etc/apk/repositories | grep -q "/edge/" || fail "/etc/apk/repositories does not name edge"
    fi
fi
if [ "${family}" = arch ]; then
    # Each instance makes its own pacman keyring, whose master key is
    # private: the image holds none, no package cache and no sync databases.
    [ ! -e /etc/pacman.d/gnupg ] || fail "/etc/pacman.d/gnupg is in the image"
    if [ -n "$(ls -A /var/cache/pacman/pkg 2> /dev/null)" ]; then fail "/var/cache/pacman/pkg is not empty"; fi
    if [ -n "$(ls -A /var/lib/pacman/sync 2> /dev/null)" ]; then fail "/var/lib/pacman/sync is not empty"; fi
    # The unit makes the keyring once, and again after a first boot that
    # stopped half way: pacman-key --init makes the directory before the
    # keys. Its conditions and commands, run here, leave a complete keyring
    # (a secret key, the stamp) over a half-made one, and the unit is
    # skipped from then on. It runs before sshd, so that no one logs in
    # before the keyring is there.
    unit=/etc/systemd/system/ghostrack-pacman-init.service
    grep -q "^Before=.*sshd.service" "${unit}" || fail "the pacman keyring unit does not run before sshd"
    condition=$(grep "^ConditionPathExists=" "${unit}") || condition=
    if [ -z "${condition}" ]; then
        fail "the pacman keyring unit has no condition"
    else
        systemd-analyze condition "${condition}" > /dev/null 2>&1 || fail "the pacman keyring unit is skipped with no keyring"
        mkdir -p /etc/pacman.d/gnupg
        : > /etc/pacman.d/gnupg/half-made
        systemd-analyze condition "${condition}" > /dev/null 2>&1 || fail "the pacman keyring unit is skipped after a first boot that stopped half way"
        sed -n -e "s/^ExecStartPre=//p" -e "s/^ExecStart=//p" "${unit}" | while read -r command; do
            sh -c "${command}" > /dev/null 2>&1 || fail "the pacman keyring unit fails: ${command}"
        done
        [ ! -e /etc/pacman.d/gnupg/half-made ] || fail "the pacman keyring unit keeps a half-made keyring"
        [ -n "$(gpg --homedir /etc/pacman.d/gnupg --list-secret-keys --with-colons 2> /dev/null)" ] || fail "the pacman keyring unit makes no secret key"
        if systemd-analyze condition "${condition}" > /dev/null 2>&1; then fail "the pacman keyring unit runs again after it made the keyring"; fi
    fi
fi
# sshd accepts its configuration once an instance has made its keys, and
# the policy is in force.
ssh-keygen -A > /dev/null
mkdir -p /run/sshd
sshd=$(command -v sshd || echo /usr/sbin/sshd)
"${sshd}" -t || fail "sshd -t refuses the configuration"
# (OpenSSH 10.6 prints the keywords in their usual case.)
config=$("${sshd}" -T 2> /dev/null | tr "[:upper:]" "[:lower:]")
echo "${config}" | grep -q -x -E "permitrootlogin (prohibit-password|without-password)" || fail "root may log in with a password"
echo "${config}" | grep -q -x "passwordauthentication no" || fail "password authentication is on"
echo "${config}" | grep -q -x "kbdinteractiveauthentication no" || fail "keyboard-interactive authentication is on"
true
'

# needed_level IMAGE: the highest x86-64 level that the image's C library
# or its init is marked as needing (glibc's loader refuses an object on a
# CPU without it), 1 when neither is marked (the baseline, as with musl).
needed_level() {
    local notes needed path paths
    # shellcheck disable=SC2016 # expanded by the image's shell
    paths=$(podman run --rm --network none --entrypoint /bin/sh "$1" -c '
        for libc in /lib64/libc.so.6 /lib/x86_64-linux-gnu/libc.so.6 /usr/lib/x86_64-linux-gnu/libc.so.6 /lib/ld-musl-x86_64.so.1; do
            [ -e "${libc}" ] && readlink -f "${libc}" && break
        done
        readlink -f /sbin/init
    ') || return 1
    [[ $(wc -l <<< "${paths}") == 2 ]] || return 1
    needed=
    while IFS= read -r path; do
        podman run --rm --network none --entrypoint /bin/cat "$1" "${path}" < /dev/null > "${work}/object" 2> /dev/null || return 1
        # (readelf exits 1 on the dlopen notes of a recent systemd.)
        notes=$(readelf -n "${work}/object" 2> /dev/null || true)
        [[ -n ${notes} ]] || return 1
        needed+=$(sed -n 's/.*x86 ISA needed: //p' <<< "${notes}" | grep -o -E 'x86-64-v[0-9]' | sed 's/^x86-64-v//' || true)$'\n'
    done <<< "${paths}"
    needed=$(grep -E '^[0-9]+$' <<< "${needed}" | sort -n | tail -n 1 || true)
    echo "${needed:-1}"
}

while IFS=$'\t' read -r -u 3 name version family init stop_signal _base display_name memory level; do
    image=${STRUCTURE_IMAGE:-$(image_tag "${name}" "${version}")}
    before=${failures}
    echo "structure.sh: ${image} (${display_name})"
    if ! config=$(podman image inspect --format json "${image}" 2> /dev/null); then
        fail "${image} is not built (scripts/build.sh ${name}:${version})"
        continue
    fi
    problems=$(python3 - "${version}" "${display_name}" "${init}" "${stop_signal}" "${memory}" "${level}" 3<<< "${config}" << 'PYTHON'
import json, os, signal, sys
version, title, init, stop, memory, level = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5], sys.argv[6]
image = json.load(os.fdopen(3))[0]
config = image.get("Config") or {}
labels = config.get("Labels") or {}
want = {
    "org.opencontainers.image.source": "https://github.com/ghostrack-io/container-images",
    "org.opencontainers.image.title": title,
    "org.opencontainers.image.version": version,
    "io.ghostrack.init-system": init,
    "io.ghostrack.ssh-user": "root",
    "io.ghostrack.minimum-memory-bytes": memory,
    "io.ghostrack.x86-64-level": level,
}
for key, value in want.items():
    if labels.get(key) != value:
        print(f"label {key} is {labels.get(key)!r}, not {value!r}")
if config.get("Cmd") != ["/sbin/init"] or config.get("Entrypoint"):
    print(f"the command is {config.get('Entrypoint')} {config.get('Cmd')}, not /sbin/init alone")
names = {"SIGRTMIN+3": signal.SIGRTMIN + 3, "SIGUSR2": signal.SIGUSR2}
got = config.get("StopSignal", "")
if names.get(got, -1) != stop:
    print(f"the stop signal is {got!r}, not signal {stop}")
for key in ("Volumes", "ExposedPorts"):
    if config.get(key):
        print(f"the image declares {key}: {sorted(config[key])}")
if image.get("Architecture") != "amd64" or image.get("Os") != "linux":
    print(f"the image is for {image.get('Os')}/{image.get('Architecture')}")
PYTHON
    )
    while IFS= read -r problem; do
        [[ -n ${problem} ]] && fail "${problem}"
    done <<< "${problems}"
    if ! needed=$(needed_level "${image}"); then
        fail "the C library and the init could not be read"
    elif [[ ${needed} != "${level}" ]]; then
        fail "the C library or the init needs x86-64 level ${needed}; images.toml says ${level}"
    fi
    # shellcheck disable=SC2086 # one unit a word
    inside_out=$(podman run --rm --network none --entrypoint /bin/sh "${image}" -c "${inside}" sh "${init}" "${family}" "${version}" ${masked_units} 2>&1) \
        || fail "the checks inside the image did not run: ${inside_out}"
    while IFS= read -r line; do
        case ${line} in
            FAIL\ *) fail "${line#FAIL }" ;;
        esac
    done <<< "${inside_out}"
    [[ ${failures} == "${before}" ]] && echo "  ok"
done 3<<< "${selected}"

if [[ ${failures} != 0 ]]; then
    echo "structure.sh: ${failures} check(s) failed"
    exit 1
fi
echo "structure.sh: all checks passed"
