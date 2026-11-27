#!/bin/sh
# Run by images/alpine/Containerfile after the packages are installed:
# busybox init without terminals, OpenRC's runlevels as on a small VM
# (without networking: the platform's init has configured eth0 and DNS),
# the SSH policy, and no host keys in the image.
set -eu
build=$(dirname "$0")/../..

# The console is the container's log: no getty on it or on virtual
# terminals, which a container machine does not have.
sed -i -e '/^tty[0-9]*::/d' -e '/^ttyS[0-9]*::/d' -e '/^console::respawn/d' /etc/inittab

for service in bootmisc sysctl syslog; do
    rc-update add "${service}" boot
done
for service in sshd crond; do
    rc-update add "${service}" default
done
for service in killprocs savecache; do
    rc-update add "${service}" shutdown
done

# The platform's init has brought the network up, so OpenRC is told that
# net is provided: a service that needs net (i2pd, for one) then starts
# without the networking service, which has no /etc/network/interfaces.
sed -i 's/^#*rc_provide=.*/rc_provide="net"/' /etc/rc.conf
grep -q -x 'rc_provide="net"' /etc/rc.conf || echo 'rc_provide="net"' >> /etc/rc.conf

install -d -m 0755 /etc/ssh/sshd_config.d
install -m 0644 "${build}/common/sshd-ghostrack.conf" /etc/ssh/sshd_config.d/00-ghostrack.conf

# root has no password; a locked one ("!") would also refuse its keys,
# since this sshd has no PAM.
sed -i 's/^root:![^:]*:/root:*:/' /etc/shadow

# sshd's OpenRC service makes this instance's host keys when it starts.
rm -f /etc/ssh/ssh_host_*
