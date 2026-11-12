# container-images

Stock images for container virtual machines that behave like a small VM:
the official Debian, Ubuntu, Alpine, Arch Linux, Rocky Linux and
AlmaLinux images with their own init system (systemd, or OpenRC on Alpine) and OpenSSH, ready to
run under the init of
[kernel-linux](https://github.com/ghostrack-io/kernel-linux) (interface
version 3, `init_system`). They are published on GHCR as
`ghcr.io/ghostrack-io/<name>:<version>`.

## The images

| Image | Name and tag | Init | Stop signal | Minimum memory | x86-64 level |
|---|---|---|---|---|---|
| Debian 13 | `debian:13` | systemd | 37 (`SIGRTMIN+3`) | 256 MiB | 1 |
| Debian 12 | `debian:12` | systemd | 37 (`SIGRTMIN+3`) | 256 MiB | 1 |
| Ubuntu 26.04 | `ubuntu:26.04` | systemd | 37 (`SIGRTMIN+3`) | 256 MiB | 1 |
| Ubuntu 24.04 | `ubuntu:24.04` | systemd | 37 (`SIGRTMIN+3`) | 256 MiB | 1 |
| Ubuntu 22.04 | `ubuntu:22.04` | systemd | 37 (`SIGRTMIN+3`) | 256 MiB | 1 |
| Alpine Linux (its current release) | `alpine:<release>` | busybox init running OpenRC | 12 (`SIGUSR2`) | 256 MiB | 1 |
| Alpine Linux edge | `alpine:edge` | busybox init running OpenRC | 12 (`SIGUSR2`) | 256 MiB | 1 |
| Rocky Linux 10 | `rockylinux:10` | systemd | 37 (`SIGRTMIN+3`) | 256 MiB | 3 |
| Rocky Linux 9 | `rockylinux:9` | systemd | 37 (`SIGRTMIN+3`) | 512 MiB | 2 |
| AlmaLinux 10 | `almalinux:10` | systemd | 37 (`SIGRTMIN+3`) | 256 MiB | 3 |
| AlmaLinux 9 | `almalinux:9` | systemd | 37 (`SIGRTMIN+3`) | 512 MiB | 2 |
| Arch Linux | `archlinux:rolling` | systemd | 37 (`SIGRTMIN+3`) | 256 MiB | 1 |

Arch Linux is a rolling release, and Alpine Linux edge is Alpine's
development branch; CI rebuilds both weekly, with the other images.

[`images.toml`](images.toml) lists them with their bases, the official
images on Docker Hub, pinned by digest. Each image's command is
`/sbin/init`, run as the container's init system; its `STOPSIGNAL` is the
signal on which that init shuts down cleanly (the kernel delivers no other
to it). Labels: `org.opencontainers.image.source`, `.title`, `.version`,
`.revision`, `io.ghostrack.init-system` (`systemd` or `openrc`),
`io.ghostrack.ssh-user` (`root`), `io.ghostrack.minimum-memory-bytes`
and `io.ghostrack.x86-64-level`.

An instance of an image needs at least its minimum memory: below it the
package manager is killed for memory (dnf on EL 9 needs more than
256 MiB without swap). Its host's CPU needs the image's x86-64
microarchitecture level: 1 is the baseline, 2 is x86-64-v2 (SSE4.2,
POPCNT), 3 is x86-64-v3 (AVX2, BMI2, FMA, MOVBE). Rocky Linux 10 and
AlmaLinux 10 are built for x86-64-v3, and their init dies at once on a
CPU without it (a pre-Haswell one, for instance).

What each image holds: the init system (with D-Bus on systemd), the
OpenSSH server, `iproute2`, `ping`, CA certificates, `curl`, `less`, a
small `vi`, `procps`, `sudo`, cron and the time zone data, and the
distribution's package manager set up for its usual mirrors. The base's
packages are upgraded when an image is built, so it holds its
distribution's updates of that day. There is no
kernel, boot loader, firmware, NetworkManager or cloud-init: the
platform's init configures `eth0`, the host name, `/etc/hosts` and
`/etc/resolv.conf` before the image's init starts, and nothing in the
image changes them. For a container machine the systemd images mask the
gettys (the console is the machine's log), `systemd-networkd`,
`systemd-resolved`, `systemd-timesyncd` (the guest clock is the host's
`kvm-clock`), `systemd-firstboot`, udev (`/sys` is read-only),
`systemd-remount-fs` and `networking.service`
([`common/masked-units`](common/masked-units)); Rocky and Alma leave
`dnf-makecache.timer` off (dnf refreshes its metadata itself when it is
run, and the hourly refresh takes about 190 MiB); Alpine runs no getty
and no `networking` service.

SSH: root logs in with the keys the platform writes to
`/root/.ssh/authorized_keys`, never with a password
(`PermitRootLogin prohibit-password`, `PasswordAuthentication no`,
`KbdInteractiveAuthentication no`). sshd starts at boot.

Per instance: an image holds no SSH host keys and an empty
`/etc/machine-id`. Each instance makes its own host keys at its first
boot, before sshd starts (`ghostrack-ssh-host-keys.service` on Debian and
Ubuntu, `sshd-keygen@.service` on Rocky and Alma, `sshdgenkeys.service` on
Arch, sshd's OpenRC service on Alpine), and systemd makes its machine ID;
both are kept on the instance's disk from then on. An Arch image holds no
pacman keyring either: `ghostrack-pacman-init.service` makes the instance's
own at its first boot, before sshd starts (`pacman-key --init` and
`--populate archlinux`, then a stamp in the keyring directory, which the
unit's condition reads: a first boot that stopped half way is made again),
so no two instances share its private master key.

Systemd images leave `/run/lock` empty at build time. Its runtime
directories are created by tmpfiles after early mounts, so the platform's
`/run` seeding does not trigger a nonempty mountpoint warning. Structure
and boot checks guard against shipping build-time lock state.

## Building and testing

```sh
scripts/build.sh [NAME[:VERSION]...]       # podman; tags localhost/ghostrack-images/<name>:<version>
tests/structure.sh [NAME[:VERSION]...]     # checks the built images without booting them
tests/boot.sh --kernel DIR [NAME[:VERSION]...]
tests/arch-stale-base.sh                   # Arch Linux from an old base
```

A bare name selects every version of it; no name selects every image.

`tests/structure.sh` checks that an image holds no host key, machine ID,
random seed, pacman keyring or password hash, that the SSH policy is in force
(`sshd -T`, after `ssh-keygen -A` in a throwaway container), the masked
units, the services enabled at boot, the init at `/sbin/init`, the
packages above, that its C library and init need the x86-64 level
`images.toml` gives (their `x86 ISA needed` notes, read with `readelf`),
and the image's labels, command and stop signal.

`tests/boot.sh` boots each image as a container machine under QEMU with
KVM, with a kernel-linux release's `bzImage` and `initramfs.cpio.zst` in
`DIR` (kernel-linux's `scripts/build.sh` makes them). The root disk is the
image's files on ext4 (`mkfs.ext4 -d`; the init's unpack mode, which the
platform uses, is kernel-linux's to test). Each image boots three
instances, all at the image's minimum memory: two from fresh disks, the
second on QEMU's oldest CPU model of the image's x86-64 level (`kvm64`,
`Nehalem`, `Haswell-noTSX`), then the first again. Each must reach
`running` with no failed unit (OpenRC: every service of its runlevels
started), accept a throwaway key for root over SSH, run cron and
`crontab`, keep the platform's address, route and name server, and end
with a `poweroff` report when powered off from inside; the two instances
must have different host keys, machine IDs and (Arch) pacman keyrings,
and the first must keep its own across its two boots; the Arch image's
second disk starts with a pacman keyring that a first boot left half made,
and the instance makes it again (the test needs `debugfs`). The last boot
also reaches the package
mirrors (`apt-get update`, `dnf makecache`, `apk update`, `pacman -Sy`), finds no
package update pending (an image built days ago fails here: rebuild it),
and starts the service of every active systemd timer, each of which must
succeed with the system still `running`. It reports each image's boot
time to `running`, `MemAvailable` at its minimum memory and its
gzip-compressed size. It needs podman, `qemu-system-x86_64`, `/dev/kvm`,
`mkfs.ext4`, `ssh` and network access.

`tests/arch-stale-base.sh` builds the Arch Linux image from the official
base of 2025-09-07 and runs `tests/structure.sh` on it. The build's upgrade
must trust the packagers who have signed packages since, whose keys the
base's keyring lacks (a pinned base is up to a month old when CI rebuilds
it). It downloads about a gigabyte and is not part of CI.

## Publishing

[CI](.github/workflows/ci.yml) builds every image and runs
`tests/structure.sh` on pull requests and pushes. On `main` (a push, a
weekly scheduled run, which rebuilds the images with their distributions'
updates whether or not a base moved, or a run started by hand) it then
pushes the tested images to `ghcr.io/ghostrack-io/<name>:<version>` and
`:<version>-<YYYYMMDD>-<n>`, and writes `images.json` as a workflow
artifact and as the asset of a release `images-<YYYYMMDD>-<n>`, with the
same `n`: one more than the day's highest release. A dated tag that a
release names is never pushed again (a run that fails before its release
leaves dated tags that no release names, and the next run reuses them). A
build that fails stops the publish and the release for every image, the
rolling ones included: the platform imports a release as its complete set of
stock images, so rerun the failed jobs. The boot test does not run in CI: it
needs KVM and a kernel-linux build.

Each entry of `images.json` has the image's `name`, `version`,
`display_name`, `reference`, `digest`, `tag` (the dated tag, such as
`13-20261019-1`), `init`, `stop_signal`, `ssh_user`,
`minimum_memory_bytes` and `x86_64_level`. The `reference` is
`ghcr.io/ghostrack-io/<name>@sha256:<hex>`, repository and digest
without a tag, which names one image for good.

A monthly [workflow](.github/workflows/update-bases.yml) runs
`scripts/update-bases.sh`, which moves each base to the digest its tag
names now (and a released Alpine to its current release; Alpine edge keeps its tag), and opens a pull request
when one moved.

For the maintainer:

- A package GHCR creates on a workflow's first push may start private.
  Set each package (`debian`, `ubuntu`, `alpine`, `archlinux`, `rockylinux`,
  `almalinux`) public once, in its package settings; the images are meant
  to be pulled without credentials.
- GitHub turns a public repository's scheduled workflows off after 60
  days without activity in it; turn them on again in the Actions tab.
- The base-update workflow needs "Allow GitHub Actions to create and
  approve pull requests" in the repository's Actions settings. A pull
  request it opens does not start CI by itself (GitHub runs no workflow
  for the workflow token's events): close and reopen it, or push to its
  branch, to run the checks.

## Licence

The images contain the distributions' own software under its own licences.
Everything else in this repository is licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option.
