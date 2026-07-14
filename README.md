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
- Filesystems: ext4, xfs, btrfs, or ZFS. btrfs installs onto a single `@`
  subvolume with `compress=zstd:1,noatime,space_cache=v2,discard=async`, which
  keeps a whole-root snapshot a single command.
- Root on ZFS: a single pool (default `rpool`) with a `rpool/ROOT/pve` boot
  dataset, imported by the dracut `zfs` module from the UKI. The Proxmox kernel
  ships ZFS built in, so no DKMS is needed. Encryption is optional: OpenZFS native
  (passphrase at boot) or LUKS underneath the pool (the TPM2 path below).
- Secure Boot using the Microsoft-signed shim plus a Machine Owner Key (MOK).
  The same MOK signs the UKI, systemd-boot, and DKMS/out-of-tree modules, so
  custom modules load under lockdown.

## Requirements

- A UEFI target machine.
- A Linux live environment with a network connection. The Proxmox VE ISO
  (debug/rescue shell) is the reference and, unlike a plain Debian netinst, it
  works out of the box; any Debian-family live environment with the tools also
  works. Missing tools (`debootstrap`, `cryptsetup`, `gdisk`, and so on) are
  installed automatically.
- For a **ZFS root** (`FS=zfs`), the live environment must have working ZFS
  (`zpool` must run), because the pool is created before the target exists. The
  Proxmox VE ISO ships ZFS; a plain Debian live does not.
- Network access to the Debian and Proxmox package repositories.

## Root on ZFS

With `FS=zfs` the installer creates a single pool on the root partition and a
boot dataset layout, then boots it from the UKI via the dracut `zfs` module:

```
rpool                 (mountpoint=none)
  rpool/ROOT          (mountpoint=none)
    rpool/ROOT/pve    (mountpoint=/, the booted root)
```

`bootfs` is set on the pool and the kernel command line is
`root=zfs:rpool/ROOT/pve`. The Proxmox kernel ships ZFS built in, so no DKMS is
built; the installer adds only the dracut `zfs` module and OpenZFS userland. The
pool is exported cleanly at the end of the install so it imports on first boot
without a force flag. Encryption is optional: `ZFS_ENC=native` (OpenZFS native
encryption, passphrase prompted in the initramfs) or `ZFS_ENC=luks` (LUKS under
the pool, reusing the TPM2 auto-unlock path below).

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
  FS=btrfs USE_LUKS=yes SECUREBOOT=yes \
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
| `FS` | `ext4`, `xfs`, `btrfs`, `zfs` | `ext4` |
| `ZPOOL` | ZFS pool name (FS=zfs) | `rpool` |
| `ZFS_ENC` | `none`, `native`, `luks` (FS=zfs encryption) | `none` |
| `BTRFS_OPTS` | btrfs mount options | `compress=zstd:1,noatime,space_cache=v2,discard=async` |
| `USE_LVM` | `yes`, `no` (non-zfs) | `no` |
| `LVM_THIN` | `yes`, `no` (thin provision the root LV) | `no` |
| `ROOT_SIZE` | root LV size, or `100%FREE` (LVM only) | `100%FREE` |
| `USE_LUKS` | `yes`, `no` (non-zfs; zfs uses ZFS_ENC) | `no` |
| `SECUREBOOT` | `yes`, `no` | `yes` |
| `HOSTONLY` | `yes`, `no` (host-specific vs generic initramfs) | `no` |
| `HOSTNAME_` | target hostname | `pve` |
| `ROOTPW` | root password | `proxmox` |
| `LUKSPW` | LUKS passphrase | `proxmox` |
| `ZFSPW` | ZFS native-encryption passphrase (ZFS_ENC=native) | `proxmox` |
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

Every LUKS install is identical: it creates a passphrase (slot 0) and a
`crypttab` entry with `tpm2-device=auto`. That option is harmless with no TPM
slot enrolled, so the system boots on the passphrase until you decide to add the
TPM. The installer does not enroll the TPM during installation, and it cannot:
TPM enrollment binds to the Secure Boot state (PCR 7), and PCR 7 is only stable
once the MOK has been enrolled at MokManager. Enrolling earlier would bind to a
PCR 7 that no longer matches after the MOK is added, and unlock would fall back
to the passphrase. TPM auto-unlock is therefore an optional post-boot step.

So the TPM is enrolled once, after the first boot, with the bundled helper:

1. Install with `USE_LUKS=yes` and a passphrase. Reboot.
2. First boot stops in MokManager. Enroll the MOK (enter `MOKPW`) and continue.
3. The system boots and asks for the LUKS passphrase. Enter it and log in.
4. Run the helper, then reboot:

   ```sh
   pve-tpm-enroll
   reboot
   ```

The root now unlocks from the TPM with no passphrase. The policy is signed
against PCR 11, so kernel and command-line changes do not break it. If a reboot
still asks for the passphrase (for example because you enrolled another MOK or
changed Secure Boot keys afterward), the PCR 7 state moved; run `pve-tpm-enroll`
again and reboot. The passphrase slot always remains as a fallback.

## Changing the kernel command line later

The kernel command line lives in a single file, `/etc/kernel/cmdline`, which the
UKI build hook reads. It already contains the base line (`root=`, `rootfstype=`,
any `rootflags` or `rd.lvm.lv`, and whatever you passed as `EXTRA_CMDLINE` at
install time). To add or change options on the installed system:

```sh
# 1. edit the single command-line file (one line, space separated)
$EDITOR /etc/kernel/cmdline

# 2. rebuild and re-sign the UKI, then reboot
pve-uki-rebuild
```

`pve-uki-rebuild` regenerates the initrd and rebuilds the UKI for every installed
kernel (pass a version, for example `pve-uki-rebuild "$(uname -r)"`, to do just
one). It re-signs the UKI with the MOK, so Secure Boot stays valid, and it
regenerates the signed PCR 11 policy, so TPM2 auto-unlock keeps working. A
command-line change is handled the same way as a kernel upgrade. The same helper
is what you run after changing the dracut configuration under
`/etc/dracut.conf.d`.

The usual Debian and Proxmox methods do not apply here: GRUB is disabled, and
`/etc/cmdline.d/*` is not read for UKIs. `/etc/kernel/cmdline` is the one source.

## Development

`testmatrix.sh` drives the installer through every mode and option combination
against a spare disk and inspects the on-disk result. It is destructive and
picks the target as the disk that is not holding the running root. It is meant
for a disposable virtual machine, not a real system.

## License

MIT
