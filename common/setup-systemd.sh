#!/bin/sh
# Run by the systemd images' Containerfiles after the packages are
# installed: the SSH policy, the masked units, the services enabled at
# boot, and nothing of an instance's own (host keys, machine ID) left in
# the image.
#
#   setup-systemd.sh FAMILY     (debian, ubuntu or rhel)
set -eu
family=$1
build=$(dirname "$0")

install -d -m 0755 /etc/ssh/sshd_config.d
install -m 0644 "${build}/sshd-ghostrack.conf" /etc/ssh/sshd_config.d/00-ghostrack.conf

while read -r unit; do
    case ${unit} in
        '' | '#'*) continue ;;
    esac
    ln -sfn /dev/null "/etc/systemd/system/${unit}"
done < "${build}/masked-units"

case ${family} in
    debian | ubuntu)
        # Debian's and Ubuntu's sshd needs its host keys before it starts;
        # this unit makes them at an instance's first boot.
        install -m 0644 "${build}/ghostrack-ssh-host-keys.service" /etc/systemd/system/
        # Ubuntu starts sshd from ssh.socket; here sshd runs from boot, as on
        # Debian.
        if [ -e /usr/lib/systemd/system/ssh.socket ] || [ -e /lib/systemd/system/ssh.socket ]; then
            systemctl disable ssh.socket
        fi
        systemctl enable ghostrack-ssh-host-keys.service ssh.service cron.service
        # The images' package installs may start services, as on a VM.
        rm -f /usr/sbin/policy-rc.d
        ;;
    rhel)
        # sshd.service wants sshd-keygen.target, whose units make the keys.
        systemctl enable sshd.service crond.service
        # dnf-makecache.timer refreshes dnf's metadata every hour. dnf takes
        # about 190 MiB for it, which a small instance does not have to
        # spare (on EL 9 at 256 MiB it is killed for memory and the system
        # is degraded); dnf refreshes the metadata itself when it is run.
        if [ -e /usr/lib/systemd/system/dnf-makecache.timer ]; then
            systemctl disable dnf-makecache.timer
        fi
        ;;
    *)
        echo "setup-systemd.sh: unknown family ${family}" >&2
        exit 1
        ;;
esac

# Package setup leaves runtime subdirectories such as lock/subsys behind.
# The platform seeds /run before systemd mounts /run/lock; tmpfiles recreates
# these directories after the mount, so keep its image mountpoint empty.
if [ -d /run/lock ] && [ ! -L /run/lock ]; then
    find /run/lock -mindepth 1 -delete
fi

# Every instance makes its own host keys and machine ID at its first boot.
rm -f /etc/ssh/ssh_host_*
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
