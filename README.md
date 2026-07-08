# proxmox-uki-installer

Install Proxmox VE 9 with a signed Unified Kernel Image (UKI) booted by
systemd-boot, a dracut initramfs, and optional full-disk LUKS encryption with
TPM2 auto-unlock and Secure Boot. The installer runs from any Linux live
environment with a network connection and writes to a target disk.

Proxmox VE is Debian based. Its stock boot path uses GRUB (or `proxmox-boot-tool`)
plus initramfs-tools. This installer replaces that with a UKI so the kernel,
initramfs, and command line are a single signed EFI binary, which is what makes
a durable TPM2 policy and Secure Boot practical. Proxmox's own boot hooks are
left installed but disabled with `dpkg-divert`, so package updates do not
overwrite the configuration and nothing needs pinning.

## What it produces

- A single dracut UKI per kernel, built by `ukify`, placed in `EFI/Linux` on the
  EFI System Partition and discovered automatically by systemd-boot.
- Rebuilds on every kernel update through a `dpkg` kernel hook, so upgrades keep
  working with no manual steps.
- Optional LUKS2 on the root partition, unlocked either by passphrase or by the
  TPM2 (signed PCR 11 policy, so it survives kernel upgrades).
- Optional LVM (thin or thick) with a configurable root size.
- Filesystems: ext4, xfs, or btrfs. btrfs installs onto a single `@` subvolume
  with `compress=zstd:1,noatime,space_cache=v2,discard=async`, which keeps a
  whole-root snapshot a single command.
- Secure Boot using the Microsoft-signed shim plus a Machine Owner Key (MOK).
  The same MOK signs the UKI, systemd-boot, and DKMS/out-of-tree modules, so
  custom modules load under lockdown.

## Requirements

- A UEFI target machine.
- A Linux live environment with a network connection. Debian live is the
  reference, but any Debian-family live environment works. Missing tools
  (`debootstrap`, `cryptsetup`, `gdisk`, and so on) are installed automatically.
- Network access to the Debian and Proxmox package repositories.

## Quick start

From the live environment, download both scripts into the same directory and run
`install.sh`. It is interactive by default.

```sh
mkdir proxmox-uki-installer && cd proxmox-uki-installer
curl -fsSLO https://raw.githubusercontent.com/cmspam/proxmox-uki-installer/main/install.sh
curl -fsSLO https://raw.githubusercontent.com/cmspam/proxmox-uki-installer/main/stage2.sh
sudo bash install.sh
```

`stage2.sh` must sit next to `install.sh`; the installer copies it into the
target and runs it inside the chroot.

The installer asks for the target disk, filesystem, LUKS, LVM, Secure Boot, and
passwords, shows a summary, and asks for confirmation before it writes anything.

## Scripted install

Any setting can be supplied through the environment instead of a prompt. A value
passed in the environment is used as is and is never prompted for. Set
`NONINTERACTIVE=yes` (or run with a non-terminal stdin) to take the defaults for
everything not supplied.

```sh
sudo NONINTERACTIVE=yes \
  TARGET_DISK=/dev/disk/by-id/ata-... \
  FS=btrfs USE_LUKS=yes UNLOCK=tpm2 SECUREBOOT=yes \
  LUKSPW='choose-a-passphrase' \
  bash install.sh
```

On real hardware use a stable `/dev/disk/by-id/...` path. Kernel device names
such as `/dev/sda` can change between boots.

### Settings

| Variable | Values | Default |
|---|---|---|
| `PART_MODE` | `auto`, `freespace`, `custom` | `auto` |
| `TARGET_DISK` | disk to install onto (auto, freespace) | prompt |
| `ESP_PART` | existing ESP partition (custom; reuse in freespace) | |
| `ROOT_PART` | existing root partition (custom) | |
| `FORMAT_ESP` | `yes`, `no` (no reuses an existing ESP) | `yes`, `no` when reusing |
| `ESP_SIZE` | EFI partition size (auto, freespace) | `1GiB` |
| `ROOT_PART_SIZE` | root partition size, or `rest` for the remainder | `rest` |
| `FS` | `ext4`, `xfs`, `btrfs` | `ext4` |
| `BTRFS_OPTS` | btrfs mount options | `compress=zstd:1,noatime,space_cache=v2,discard=async` |
| `USE_LVM` | `yes`, `no` | `no` |
| `LVM_THIN` | `yes`, `no` (thin provision the root LV) | `no` |
| `ROOT_SIZE` | root LV size, or `100%FREE` (LVM only) | `100%FREE` |
| `USE_LUKS` | `yes`, `no` | `no` |
| `UNLOCK` | `tpm2`, `passphrase` (LUKS only) | `passphrase` |
| `SECUREBOOT` | `yes`, `no` | `yes` |
| `HOSTONLY` | `yes`, `no` (host-specific vs generic initramfs) | `no` |
| `HOSTNAME_` | target hostname | `pve` |
| `ROOTPW` | root password | `proxmox` |
| `LUKSPW` | LUKS passphrase | `proxmox` |
| `MOKPW` | one-time MokManager password, 8 to 16 characters | `12345678` |
| `EXTRA_CMDLINE` | extra kernel command line, appended verbatim | |
| `SKIP_NVRAM` | `yes` skips the efibootmgr entry, uses the removable fallback | `no` |
| `MIRROR` | Debian mirror | `http://deb.debian.org/debian` |

## Partitioning modes

- `auto` wipes the whole target disk and creates an ESP plus a root partition.
  If `ROOT_PART_SIZE` is smaller than the disk, the remainder is left
  unallocated for a second partition, an LVM you grow into later, or another OS.
- `freespace` creates the ESP and root inside existing unallocated space and
  leaves other partitions untouched.
- `custom` uses partitions you have already prepared. `FORMAT_ESP=no` lets you
  share an existing ESP with another operating system.

## Secure Boot

Secure Boot is on by default. The installer keeps the firmware's Microsoft keys
enrolled and adds its own MOK alongside them, so the disk still boots on typical
hardware without changing firmware key state.

On the first boot the machine stops in MokManager (the blue shim screen) to
enroll the MOK. Choose to enroll the key and, when asked, enter the `MOKPW`
password. This is a one-time step. The same key then verifies the UKI,
systemd-boot, and any DKMS modules it signs.

DKMS modules are signed with the MOK automatically (`/etc/dkms/framework.conf`),
so out-of-tree drivers load under kernel lockdown.

## LUKS and TPM2 auto-unlock

If you choose `UNLOCK=tpm2`, the installer writes a `crypttab` entry with
`tpm2-device=auto` but does not enroll the TPM during installation. Enrollment
must happen after the first real boot, because the Secure Boot measurement
(PCR 7) is only stable once the MOK is enrolled. Run the bundled helper once,
after MokManager and the first passphrase boot:

```sh
pve-tpm-enroll
```

Reboot, and the root unlocks from the TPM with no passphrase. The policy is
signed against PCR 11, so kernel upgrades do not break it.

## Development

`testmatrix.sh` drives the installer through every mode and option combination
against a spare disk and inspects the on-disk result. It is destructive and
picks the target as the disk that is not holding the running root. It is meant
for a disposable virtual machine, not a real system.

## License

MIT
