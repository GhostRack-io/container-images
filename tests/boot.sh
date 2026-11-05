#!/bin/bash
# Boots built stock images as container machines under QEMU with KVM, with
# a kernel-linux release (interface version 3, init_system), and checks
# what an instance does: the image's init reaches running with nothing
# failed, sshd accepts the account's key for root, cron and the package
# mirrors work, no package update is pending, the services of the image's
# timers run, the network and DNS are the ones the platform's init set up,
# each instance makes its own host keys and machine ID and keeps them, and
# a poweroff inside ends the machine with a poweroff report.
#
#   tests/boot.sh --kernel DIR [NAME[:VERSION]...]   (every image without names)
#
# Three instances an image, each at the image's minimum memory
# (images.toml): a first one and a second from fresh disks, then the first
# again, which reaches the mirrors and starts the service of every timer.
# The second runs on the oldest CPU model of the image's x86-64 level, the
# others on the host's CPU.
#
# DIR holds a kernel-linux release's bzImage and initramfs.cpio.zst. Each
# image is the one scripts/build.sh tagged. Its root disk is the image's
# files on ext4 (mkfs.ext4 -d); the init's unpack mode, which an agent
# uses, is kernel-linux's to test. Needs podman, qemu-system-x86_64,
# /dev/kvm, mkfs.ext4, ssh, ssh-keygen, python3 and network access for the
# mirrors. There is no vsock device here, so the reports are read from the
# serial console.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "${repo}/scripts/lib.sh"

usage() {
    echo "usage: tests/boot.sh --kernel DIR [NAME[:VERSION]...]" >&2
    exit 2
}

die() {
    echo "boot.sh: $*" >&2
    exit 1
}

kernel_dir=
while [[ $# -gt 0 ]]; do
    case $1 in
        --kernel)
            [[ $# -ge 2 ]] || usage
            kernel_dir=$2
            shift 2
            ;;
        --kernel=*)
            kernel_dir=${1#--kernel=}
            shift
            ;;
        -*) usage ;;
        *) break ;;
    esac
done
[[ -n ${kernel_dir} ]] || usage
kernel=${kernel_dir}/bzImage
initrd=${kernel_dir}/initramfs.cpio.zst
[[ -f ${kernel} && -f ${initrd} ]] || die "no bzImage and initramfs.cpio.zst in ${kernel_dir}"
for tool in podman qemu-system-x86_64 mkfs.ext4 ssh ssh-keygen timeout python3; do
    command -v "${tool}" > /dev/null || die "${tool} is not installed"
done
[[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm is not usable"
selected=$(select_images "$@")

disk_size=2G
ssh_wait_seconds=180
poweroff_wait_seconds=60
machine_timeout=900

work=$(mktemp -d "${TMPDIR:-/tmp}/container-images-boot.XXXXXX")
qemu_pid=
cleanup() {
    if [[ -n ${qemu_pid} ]]; then
        kill "${qemu_pid}" 2> /dev/null || true
    fi
    rm -rf "${work}" 2> /dev/null || podman unshare rm -rf "${work}"
}
trap cleanup EXIT

# A throwaway key: the account's key, which the platform's init writes to
# root's authorized_keys.
ssh-keygen -q -t ed25519 -N '' -C boot-test -f "${work}/key"
public_key=$(cat "${work}/key.pub")

failures=0
image_failures=0
fail() {
    echo "  FAIL: $*"
    failures=$((failures + 1))
    image_failures=$((image_failures + 1))
}

# cpu_model LEVEL: QEMU's oldest CPU model with every feature of x86-64
# level LEVEL, and nothing of the next.
cpu_model() {
    case $1 in
        1) echo kvm64 ;;
        2) echo Nehalem ;;
        3) echo Haswell-noTSX ;;
        4) echo Skylake-Server-noTSX-IBRS ;;
        *) die "no CPU model for x86-64 level $1" ;;
    esac
}

# free_port: a TCP port on 127.0.0.1 nothing listens on.
free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# make_disk IMAGE DISK: an ext4 disk holding the image's files, owned as
# in the image.
make_disk() {
    # shellcheck disable=SC2016 # expanded by the inner shell
    podman unshare sh -euc '
        mount=$(podman image mount "$1")
        status=0
        mkfs.ext4 -q -F -L root -d "${mount}" "$2" "$3" > /dev/null || status=$?
        podman image unmount "$1" > /dev/null
        exit "${status}"
    ' sh "$1" "$2" "${disk_size}"
}

# compressed_mib IMAGE: the image's size as a registry stores it: its
# config and its layers, gzip-compressed, in MiB.
compressed_mib() {
    rm -rf "${work}/oci"
    podman push -q --compression-format gzip --force-compression "$1" "oci:${work}/oci" > /dev/null
    python3 - "${work}/oci" << 'PYTHON'
import json, sys
oci = sys.argv[1]
def blob(digest):
    return f"{oci}/blobs/{digest.replace(':', '/')}"
index = json.load(open(f"{oci}/index.json"))
manifest = json.load(open(blob(index["manifests"][0]["digest"])))
size = manifest["config"]["size"] + sum(layer["size"] for layer in manifest["layers"])
print(f"{size / 1048576:.1f}")
PYTHON
    rm -rf "${work}/oci"
}

# ssh_run [timeout SECONDS] COMMAND...: COMMAND as root in the instance.
ssh_run() {
    local limit=()
    if [[ $1 == timeout ]]; then
        limit=(timeout "$2")
        shift 2
    fi
    "${limit[@]}" ssh -q -i "${work}/key" -p "${port}" \
        -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=3 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        root@127.0.0.1 "$@"
}

# The checks inside an instance, as POSIX sh; the arguments: the init
# system, then "mirrors" to reach the package mirrors, count the pending
# updates and start the service of every timer. Lines of KEY VALUE.
# shellcheck disable=SC2016 # expanded by the instance's shell
inside='
init=$1
mirrors=${2:-}
settled() {
    [ "$(cat /run/openrc/softlevel 2> /dev/null)" = default ] \
        && ! rc-status --all 2> /dev/null | grep -q -E "starting|stopping"
}
if [ "${init}" = systemd ]; then
    state=$(systemctl is-system-running --wait 2> /dev/null)
    echo "state ${state}"
    echo "boot_seconds $(systemctl show -p FinishTimestampMonotonic --value | awk "{ printf \"%.1f\", \$1 / 1000000 }")"
    systemctl list-units --failed --no-legend --plain 2> /dev/null | awk "{ print \"failed\", \$1 }"
    for unit in cron.service crond.service; do
        if systemctl cat "${unit}" > /dev/null 2>&1; then
            echo "cron_daemon $(systemctl is-active "${unit}")"
        fi
    done
else
    tries=300
    while [ "${tries}" -gt 0 ] && ! settled; do
        tries=$((tries - 1))
        sleep 0.2
    done
    if settled; then echo "state running"; else echo "state starting"; fi
    echo "boot_seconds $(cut -d" " -f1 /proc/uptime)"
    for level in boot default; do
        for service in $(rc-update show "${level}" | awk "{ print \$1 }"); do
            rc-service "${service}" status > /dev/null 2>&1 || echo "failed ${service}"
        done
    done
    rc-status --crashed 2> /dev/null | awk "NF { print \"failed\", \$1 }"
    if pidof crond > /dev/null; then echo "cron_daemon active"; else echo "cron_daemon inactive"; fi
fi
echo "uptime $(cut -d" " -f1 /proc/uptime)"
echo "pid1 $(cat /proc/1/comm)"
echo "mem_available_kib $(awk "/^MemAvailable:/ { print \$2 }" /proc/meminfo)"
if printf "@daily true\n" | crontab - && crontab -l | grep -q -x "@daily true" && crontab -r; then
    echo "crontab ok"
else
    echo "crontab fail"
fi
echo "hostname $(hostname)"
echo "eth0 $(ip -4 -o addr show dev eth0 | awk "{ print \$4 }" | tr "\n" " ")"
echo "route $(ip -4 route show default | tr "\n" " ")"
echo "dns $(grep "^nameserver" /etc/resolv.conf | awk "{ print \$2 }" | tr "\n" " ")"
echo "hostkey $(ssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub | awk "{ print \$2 }")"
echo "machine_id $(cat /etc/machine-id 2> /dev/null)"
if [ "${mirrors}" = mirrors ]; then
    if command -v apt-get > /dev/null; then
        apt-get -q -q update > /dev/null 2>&1 && echo "mirrors ok" || echo "mirrors fail"
        if simulated=$(apt-get -s -q dist-upgrade 2> /dev/null); then
            echo "pending_updates $(echo "${simulated}" | grep -c "^Inst ")"
        fi
    elif command -v dnf > /dev/null; then
        dnf -q -y makecache > /dev/null 2>&1 && echo "mirrors ok" || echo "mirrors fail"
        listed=$(dnf -q check-update 2> /dev/null)
        case $? in
            0) echo "pending_updates 0" ;;
            100) echo "pending_updates $(echo "${listed}" | awk "NF == 3 && \$1 ~ /[.]/" | wc -l)" ;;
        esac
    else
        apk update -q > /dev/null 2>&1 && echo "mirrors ok" || echo "mirrors fail"
        if simulated=$(apk upgrade --simulate 2> /dev/null); then
            echo "pending_updates $(echo "${simulated}" | grep -c " Upgrading ")"
        fi
    fi
    # What a timer starts later, at any time in the life of the instance,
    # must work at this memory too.
    if [ "${init}" = systemd ]; then
        for timer in $(systemctl list-units --type=timer --state=active --no-legend --plain | awk "{ print \$1 }"); do
            for service in $(systemctl show -p Triggers --value "${timer}"); do
                timeout 600 systemctl start "${service}" > /dev/null 2>&1
                echo "timer ${timer} ${service} $(systemctl show -p Result --value "${service}")"
            done
        done
        echo "state_after_timers $(systemctl is-system-running 2> /dev/null)"
    fi
fi
true
'

# value KEY: the value of KEY in the instance's lines.
value() {
    sed -n "s/^$1 //p" "${case_dir}/inside.txt" | head -n 1 | sed 's/ *$//'
}

# boot_instance CASE DISK MEMORY_MIB CPU INIT STOP_SIGNAL HOSTNAME [mirrors]:
# boots DISK on QEMU's CPU model CPU, runs the checks inside over SSH
# (their lines in $case_dir/inside.txt), then powers the instance off from
# inside and checks it ends. With "mirrors" the instance also reaches the
# package mirrors and starts its timers' services.
boot_instance() {
    local name=$1 disk=$2 memory=$3 cpu=$4 init=$5 stop_signal=$6 hostname=$7 mirrors=${8:-}
    case_dir=${work}/${name}
    mkdir -p "${case_dir}"
    port=$(free_port)
    python3 - "${stop_signal}" "${public_key}" > "${case_dir}/config.json" << 'PYTHON'
import json, sys
print(json.dumps({"version": 3, "argv": ["/sbin/init"], "init_system": True,
                  "stop_signal": int(sys.argv[1]),
                  "authorized_keys": {"user": "root", "keys": [sys.argv[2]]}}))
PYTHON
    local cmdline="console=ttyS0 quiet gh.v=3 gh.hostname=${hostname} gh.ip4=10.115.0.15/24 gh.gw4=10.115.0.1 gh.dns=10.115.0.3 gh.vsock=1024"
    timeout "${machine_timeout}" qemu-system-x86_64 \
        -M pc -enable-kvm -cpu "${cpu},enforce" -m "${memory}" -smp 1 -nodefaults -no-user-config \
        -display none -no-reboot \
        -kernel "${kernel}" -initrd "${initrd}" -append "${cmdline}" \
        -serial "file:${case_dir}/serial.log" \
        -device virtio-serial-pci,id=serial0 \
        -chardev "file,id=hvc,path=${case_dir}/hvc.log" \
        -device virtconsole,chardev=hvc \
        -drive "file=${disk},format=raw,if=none,id=disk" \
        -device virtio-blk-pci,drive=disk \
        -netdev "user,id=net0,net=10.115.0.0/24,host=10.115.0.1,dns=10.115.0.3,hostfwd=tcp:127.0.0.1:${port}-10.115.0.15:22" \
        -device virtio-net-pci,netdev=net0 \
        -object rng-random,id=rng0,filename=/dev/urandom \
        -device virtio-rng-pci,rng=rng0 \
        -fw_cfg "name=opt/gigahost/config,file=${case_dir}/config.json" &
    qemu_pid=$!
    local waited=0 up=
    while [[ ${waited} -lt $((ssh_wait_seconds * 2)) ]]; do
        kill -0 "${qemu_pid}" 2> /dev/null || break
        if ssh_run true 2> /dev/null; then
            up=1
            break
        fi
        sleep 0.5
        waited=$((waited + 1))
    done
    if [[ -z ${up} ]]; then
        fail "${name}: no SSH login with the account's key within ${ssh_wait_seconds} s"
        kill "${qemu_pid}" 2> /dev/null || true
        wait "${qemu_pid}" 2> /dev/null || true
        qemu_pid=
        show_logs
        return
    fi
    ssh_run sh -s "${init}" "${mirrors}" <<< "${inside}" > "${case_dir}/inside.txt" 2>&1 || true
    # The instance powers itself off; the session may end before it answers.
    ssh_run timeout 20 poweroff > /dev/null 2>&1 || true
    waited=0
    while kill -0 "${qemu_pid}" 2> /dev/null && [[ ${waited} -lt $((poweroff_wait_seconds * 2)) ]]; do
        sleep 0.5
        waited=$((waited + 1))
    done
    if kill -0 "${qemu_pid}" 2> /dev/null; then
        fail "${name}: the machine did not end within ${poweroff_wait_seconds} s of poweroff"
        kill "${qemu_pid}" 2> /dev/null || true
    fi
    wait "${qemu_pid}" 2> /dev/null || true
    qemu_pid=
    check_instance "${name}" "${init}" "${hostname}" "${mirrors}"
}

# check_instance CASE INIT HOSTNAME [mirrors]: the instance's lines and reports.
check_instance() {
    local name=$1 init=$2 hostname=$3 mirrors=${4:-} failed
    local before=${image_failures}
    # systemd writes to the console (hvc.log); the init and the kernel to
    # the serial port.
    if grep -a -q -s -F 'Directory /run/lock to mount over is not empty' "${case_dir}/hvc.log" "${case_dir}/serial.log"; then
        fail "${name}: /run/lock was populated before its runtime mount"
    fi
    [[ $(value state) == running ]] || fail "${name}: the init's state is $(value state), not running"
    failed=$(sed -n 's/^failed //p' "${case_dir}/inside.txt" | tr '\n' ' ')
    [[ -z ${failed} ]] || fail "${name}: failed: ${failed}"
    case ${init} in
        systemd) [[ $(value pid1) == systemd ]] || fail "${name}: PID 1 is $(value pid1)" ;;
        openrc) [[ $(value pid1) == init ]] || fail "${name}: PID 1 is $(value pid1)" ;;
    esac
    [[ $(value cron_daemon) == active ]] || fail "${name}: cron is $(value cron_daemon)"
    [[ $(value crontab) == ok ]] || fail "${name}: crontab does not work"
    [[ $(value hostname) == "${hostname}" ]] || fail "${name}: the host name is $(value hostname), not ${hostname}"
    [[ $(value eth0) == 10.115.0.15/24 ]] || fail "${name}: eth0 has $(value eth0)"
    [[ $(value route) == "default via 10.115.0.1 dev eth0"* ]] || fail "${name}: the default route is $(value route)"
    [[ $(value dns) == 10.115.0.3 ]] || fail "${name}: the name servers are $(value dns)"
    [[ $(value hostkey) == SHA256:* ]] || fail "${name}: no ed25519 host key"
    if [[ ${init} == systemd && ! $(value machine_id) =~ ^[0-9a-f]{32}$ ]]; then
        fail "${name}: the machine ID is '$(value machine_id)'"
    fi
    if [[ ${mirrors} == mirrors ]]; then
        [[ $(value mirrors) == ok ]] || fail "${name}: the package mirrors are not reached"
        case $(value pending_updates) in
            0) ;;
            '') fail "${name}: the pending package updates are not counted" ;;
            *) fail "${name}: $(value pending_updates) package updates pending: the image is older than its distribution's updates (rebuild it)" ;;
        esac
        local timer
        while read -r timer; do
            [[ ${timer} == *" success" ]] || fail "${name}: a timer's service fails: ${timer}"
        done < <(sed -n 's/^timer //p' "${case_dir}/inside.txt")
        if [[ ${init} == systemd && $(value state_after_timers) != running ]]; then
            fail "${name}: the state after the timers' services is $(value state_after_timers)"
        fi
    fi
    # The init's prefix is ghostrack-init from kernel-linux gh8 on.
    grep -a -q -E '(gigahost|ghostrack)-init: report \{"v":3,"event":"started","pid":[0-9]+,' "${case_dir}/serial.log" \
        || fail "${name}: no started report"
    local reports
    reports=$(grep -a -c '"event":"exited"' "${case_dir}/serial.log" || true)
    if [[ ${reports} != 1 ]] || ! grep -a -q -E '(gigahost|ghostrack)-init: report \{"v":3,"event":"exited","code":null,"signal":2,"reason":"poweroff"\}' "${case_dir}/serial.log"; then
        fail "${name}: not one poweroff report: $(grep -a -o '"event":"exited".*' "${case_dir}/serial.log" | tr '\n' ' ')"
    fi
    echo "  ${name}: $(value state) at $(value boot_seconds) s (uptime $(value uptime) s at login), MemAvailable $(value mem_available_kib) KiB"
    [[ ${image_failures} == "${before}" ]] || show_logs
}

show_logs() {
    echo "  --- ${case_dir##*/}: checks inside ---"
    sed 's/^/  | /' "${case_dir}/inside.txt" 2> /dev/null | tail -n 30 || true
    echo "  --- serial console ---"
    sed 's/^/  | /' "${case_dir}/serial.log" 2> /dev/null | tail -n 15 || true
    echo "  --- hvc0 ---"
    tr -d '\r' < "${case_dir}/hvc.log" 2> /dev/null | sed 's/^/  | /' | tail -n 40 || true
}

summary=()
while IFS=$'\t' read -r -u 3 name version _family init stop_signal _base display_name memory level; do
    image=$(image_tag "${name}" "${version}")
    memory_mib=$((memory / 1048576))
    image_failures=0
    echo "boot.sh: ${image} (${display_name})"
    podman image exists "${image}" || { fail "${image} is not built"; continue; }
    slug=${name}-${version//./-}
    make_disk "${image}" "${work}/${slug}.img"
    cp --sparse=always "${work}/${slug}.img" "${work}/${slug}-a.img"
    mv "${work}/${slug}.img" "${work}/${slug}-b.img"

    # A first instance, a second one from a fresh disk on the oldest CPU
    # the image is for, the first again.
    boot_instance "${slug}-a" "${work}/${slug}-a.img" "${memory_mib}" host "${init}" "${stop_signal}" "${slug}-a"
    a_dir=${case_dir}
    boot_seconds=$(value boot_seconds)
    mem_kib=$(value mem_available_kib)
    mem_mib=$(( ${mem_kib:-0} / 1024 ))
    a_key=$(value hostkey)
    a_id=$(value machine_id)
    boot_instance "${slug}-b" "${work}/${slug}-b.img" "${memory_mib}" "$(cpu_model "${level}")" "${init}" "${stop_signal}" "${slug}-b"
    [[ -n ${a_key} && $(value hostkey) != "${a_key}" ]] || fail "${slug}: two instances have the same host key"
    if [[ ${init} == systemd ]]; then
        [[ -n ${a_id} && $(value machine_id) != "${a_id}" ]] || fail "${slug}: two instances have the same machine ID"
    fi
    boot_instance "${slug}-a-again" "${work}/${slug}-a.img" "${memory_mib}" host "${init}" "${stop_signal}" "${slug}-a" mirrors
    [[ $(value hostkey) == "${a_key}" ]] || fail "${slug}: the host key changed between two boots of one instance"
    [[ $(value machine_id) == "${a_id}" ]] || fail "${slug}: the machine ID changed between two boots of one instance"
    rm -f "${work}/${slug}-a.img" "${work}/${slug}-b.img"
    rm -rf "${a_dir}"

    size=$(compressed_mib "${image}")
    if [[ ${image_failures} == 0 ]]; then result=ok; else result="${image_failures} failed"; fi
    summary+=("$(printf '%-18s %8s %8s %10s %10s  %s' "${name}:${version}" "${memory_mib}" "${boot_seconds:-?}" "${mem_mib}" "${size}" "${result}")")
    echo "  ${summary[-1]}"
done 3<<< "${selected}"

echo
printf '%-18s %8s %8s %10s %10s  %s\n' image mem_MiB boot_s avail_MiB gzip_MiB result
printf '%s\n' "${summary[@]}"
if [[ ${failures} != 0 ]]; then
    echo "boot.sh: ${failures} check(s) failed"
    exit 1
fi
echo "boot.sh: all images passed"
