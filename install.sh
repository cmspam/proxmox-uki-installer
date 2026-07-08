#!/usr/bin/env bash
#
# Proxmox VE fresh-install with UKI + dracut + systemd-boot, optional LUKS/LVM.
# Runs from any Linux live environment that has the required tools (see check_tools).
# It partitions TARGET_DISK, debootstraps Debian trixie, installs the Proxmox kernel
# and boot toolchain, and configures a signed-or-unsigned UKI booted by systemd-boot.
#
# Interactive by default: any setting below that is not supplied in the
# environment is prompted for when stdin is a TTY (target disk is chosen from a
# menu; passwords are entered twice, hidden). A value passed via the environment
# is used as-is and never prompted. Set NONINTERACTIVE=yes (or pipe from a
# non-TTY) to skip all prompts and take the defaults shown in brackets, which is
# how the automated tests drive it. Settings:
#
#   PART_MODE     auto | freespace | custom                         [auto]
#                   auto      wipe TARGET_DISK, make ESP + root
#                   freespace make ESP + root in unallocated space, keep others
#                   custom    use existing ESP_PART + ROOT_PART (nothing wiped)
#   TARGET_DISK   block device to install onto (auto/freespace)     [prompt]
#   ESP_PART      existing ESP partition (custom; or reuse in freespace)  []
#   ROOT_PART     existing root partition (custom mode)             []
#   FORMAT_ESP    yes | no  (no = reuse/share an existing ESP)  [custom:no,else:yes]
#   ESP_SIZE      EFI partition size (auto/freespace)                [1GiB]
#   ROOT_PART_SIZE root partition size, e.g. 200G, or 'rest' for remainder [rest]
#   FS            root filesystem: ext4 | xfs | btrfs              [ext4]
#   BTRFS_OPTS    btrfs mount options (btrfs only)  [compress=zstd:1,noatime,space_cache=v2,discard=async]
#   USE_LVM       yes | no                                          [no]
#   LVM_THIN      yes | no  (thin-provision the root LV; LVM only)  [no]
#   ROOT_SIZE     root LV size, e.g. 64GiB, or 100%FREE (LVM only)  [100%FREE]
#   USE_LUKS      yes | no                                          [no]
#   UNLOCK        tpm2 | passphrase (only meaningful with LUKS)     [passphrase]
#   SECUREBOOT    yes | no (shim+MOK chain; no = plain systemd-boot)[yes]
#   HOSTONLY      yes | no  (host-specific initramfs vs generic)    [no]
#   HOSTNAME_     target hostname                                   [pve]
#   ROOTPW        root password on the target                       [proxmox]
#   LUKSPW        LUKS passphrase (slot 0)                           [proxmox]
#   MOKPW         one-time MokManager password (enroll+trust, 8..16) [12345678]
#   MIRROR        Debian mirror                                      [deb.debian.org]
#   EXTRA_CMDLINE extra kernel cmdline appended verbatim             []
#
set -euo pipefail

# ---------------- config ----------------
# Every setting may be supplied via the environment (scripted/testing) or
# prompted interactively (real installs). An env-provided value is always
# respected as-is; anything left unset is prompted when stdin is a TTY, else it
# falls back to a hard default. Set NONINTERACTIVE=yes to force defaults.
NONINTERACTIVE="${NONINTERACTIVE:-no}"
if [ "$NONINTERACTIVE" = yes ] || [ ! -t 0 ]; then INTERACTIVE=no; else INTERACTIVE=yes; fi

_set(){ [ -n "${!1+x}" ]; }   # true if the named variable came from the environment

ask(){ # ask VAR "question" "default" [choice ...]
  local var="$1" q="$2" def="$3"; shift 3
  _set "$var" && return 0
  if [ "$INTERACTIVE" != yes ]; then printf -v "$var" '%s' "$def"; return 0; fi
  local opts=("$@") i=1 o ans
  for o in "${opts[@]}"; do printf '  %d) %s\n' "$i" "$o"; i=$((i+1)); done
  read -r -p "$q [$def] > " ans
  [ -z "$ans" ] && ans="$def"
  if [ "${#opts[@]}" -gt 0 ] && [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#opts[@]}" ]; then
    ans="${opts[ans-1]}"
  fi
  printf -v "$var" '%s' "$ans"
}

ask_secret(){ # ask_secret VAR "label" DEFAULT MIN MAX(0=unbounded)
  local var="$1" label="$2" def="$3" min="${4:-1}" max="${5:-0}" p1 p2
  _set "$var" && return 0
  if [ "$INTERACTIVE" != yes ]; then printf -v "$var" '%s' "$def"; return 0; fi
  while :; do
    read -r -s -p "$label > " p1; printf '\n'
    [ "${#p1}" -lt "$min" ] && { echo "  must be at least $min characters"; continue; }
    [ "$max" -gt 0 ] && [ "${#p1}" -gt "$max" ] && { echo "  must be at most $max characters"; continue; }
    read -r -s -p "confirm $label > " p2; printf '\n'
    [ "$p1" != "$p2" ] && { echo "  does not match, try again"; continue; }
    printf -v "$var" '%s' "$p1"; break
  done
}

pick_disk(){ # interactive target-disk selection
  local disks=() sizes=() models=() line name size model n ans
  while IFS= read -r line; do
    name="${line%% *}"; disks+=("$name")
  done < <(lsblk -dpno NAME 2>/dev/null | grep -vE '/dev/(loop|sr|zram)')
  [ "${#disks[@]}" -eq 0 ] && { echo "no disks found"; exit 1; }
  echo "Available disks:"
  n=1; for d in "${disks[@]}"; do
    printf '  %d) %s\n' "$n" "$(lsblk -dpno NAME,SIZE,MODEL "$d" 2>/dev/null)"; n=$((n+1))
  done
  read -r -p "Select target disk (number or /dev path) > " ans
  if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#disks[@]}" ]; then
    printf -v TARGET_DISK '%s' "${disks[ans-1]}"
  else
    printf -v TARGET_DISK '%s' "$ans"
  fi
}

pick_part(){ # pick_part VAR "question" — choose an existing partition
  local var="$1" q="$2" parts=() p n ans
  while IFS= read -r p; do parts+=("$p"); done < <(lsblk -pno NAME,TYPE 2>/dev/null | awk '$2=="part"{print $1}')
  if [ "${#parts[@]}" -gt 0 ]; then
    echo "Existing partitions:"
    n=1; for p in "${parts[@]}"; do printf '  %d) %s\n' "$n" "$(lsblk -pno NAME,SIZE,FSTYPE,PARTLABEL "$p" 2>/dev/null)"; n=$((n+1)); done
  fi
  read -r -p "$q (number or /dev path) > " ans
  if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#parts[@]}" ]; then
    printf -v "$var" '%s' "${parts[ans-1]}"
  else
    printf -v "$var" '%s' "$ans"
  fi
}

# ---- partitioning mode (how ESP + root are obtained) ----
#   auto      wipe TARGET_DISK; make ESP + root (root = ROOT_PART_SIZE, remainder left free)
#   freespace make ESP + root in unallocated space on TARGET_DISK; keep other partitions
#   custom    use existing ESP_PART + ROOT_PART you prepared (nothing wiped or created)
ask PART_MODE "Partitioning mode" auto  auto freespace custom
if [ "$PART_MODE" = custom ]; then
  if ! _set ESP_PART; then
    [ "$INTERACTIVE" = yes ] || { echo "custom mode needs ESP_PART and ROOT_PART"; exit 1; }
    pick_part ESP_PART  "ESP partition (existing)"
  fi
  if ! _set ROOT_PART; then
    [ "$INTERACTIVE" = yes ] || { echo "custom mode needs ROOT_PART"; exit 1; }
    pick_part ROOT_PART "Root partition (existing)"
  fi
  ESP_PART="$(readlink -f "$ESP_PART")"; ROOT_PART="$(readlink -f "$ROOT_PART")"
  { [ -b "$ESP_PART" ] && [ -b "$ROOT_PART" ]; } || { echo "ESP_PART/ROOT_PART must be block devices"; exit 1; }
  ask FORMAT_ESP "Format the ESP? (no = reuse/share an existing one)" no  no yes
  TARGET_DISK="${TARGET_DISK:-$ROOT_PART}"   # for logging/summary only
else
  if ! _set TARGET_DISK; then
    [ "$INTERACTIVE" = yes ] || { echo "set TARGET_DISK, e.g. /dev/disk/by-id/..."; exit 1; }
    pick_disk
  fi
  # resolve stable/by-id paths to the canonical device (names can shift per boot)
  TARGET_DISK="$(readlink -f "$TARGET_DISK")"
  [ -b "$TARGET_DISK" ] || { echo "TARGET_DISK $TARGET_DISK is not a block device"; exit 1; }
fi

ask FS         "Root filesystem"            ext4  ext4 btrfs xfs
ask USE_LVM    "Use LVM?"                    no    no yes
if [ "$USE_LVM" = yes ]; then
  ask LVM_THIN   "LVM thin provisioning?"    no    no yes
  ask ROOT_SIZE  "Root LV size (e.g. 100G, 100%FREE)" 100%FREE
else
  LVM_THIN="${LVM_THIN:-no}"; ROOT_SIZE="${ROOT_SIZE:-100%FREE}"
fi
ask USE_LUKS   "Encrypt root with LUKS?"     no    no yes
if [ "$USE_LUKS" = yes ]; then
  ask UNLOCK   "Unlock method"               passphrase  passphrase tpm2
else
  UNLOCK="${UNLOCK:-passphrase}"
fi
ask SECUREBOOT "Secure Boot (shim + MOK)?"   yes   yes no
ask HOSTONLY   "Host-specific initramfs (vs generic)?" no  no yes
ask HOSTNAME_  "Hostname"                    pve

ask_secret ROOTPW "root password" proxmox 1 0
if [ "$USE_LUKS" = yes ]; then
  ask_secret LUKSPW "LUKS passphrase" proxmox 1 0
else
  LUKSPW="${LUKSPW:-proxmox}"
fi
if [ "$SECUREBOOT" = yes ]; then
  # one-time password typed at MokManager (enroll + trust); mokutil requires 8..16 chars
  ask_secret MOKPW "MokManager password (8..16 chars)" 12345678 8 16
else
  MOKPW="${MOKPW:-12345678}"
fi
case "${#MOKPW}" in 8|9|10|11|12|13|14|15|16) ;; *) echo "MOKPW must be 8..16 characters (mokutil limit); got ${#MOKPW}"; exit 1 ;; esac

if [ "$PART_MODE" != custom ]; then
  ask ESP_SIZE       "ESP size"  1GiB
  ask ROOT_PART_SIZE "Root partition size (e.g. 200G, or 'rest' for the remainder)"  rest
fi

# btrfs defaults (match cache22 / Fedora atomic): zstd:1 = low-CPU compression,
# SSD-friendly. Applied at install-time mount, in fstab (stage2), and rootflags.
BTRFS_OPTS="${BTRFS_OPTS:-compress=zstd:1,noatime,space_cache=v2,discard=async}"

ESP_SIZE="${ESP_SIZE:-1GiB}"
ROOT_PART_SIZE="${ROOT_PART_SIZE:-rest}"
# FORMAT_ESP is left to per-mode defaults: custom asks (default no), a reused ESP
# in freespace defaults no, a freshly-created ESP (auto/freespace) defaults yes.
ESP_PART="${ESP_PART:-}"
ROOT_PART="${ROOT_PART:-}"
SKIP_NVRAM="${SKIP_NVRAM:-no}"   # skip efibootmgr NVRAM entry (rely on removable fallback)
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
EXTRA_CMDLINE="${EXTRA_CMDLINE:-}"
SUITE=trixie
VG=pve
MNT=/mnt/target

log(){ printf '\n\033[1;36m### %s\033[0m\n' "$*"; }

part(){ # partition device name for a disk + index (handles nvme/mmc p-suffix)
  case "$TARGET_DISK" in
    *nvme*|*mmcblk*|*loop*) echo "${TARGET_DISK}p$1" ;;
    *) echo "${TARGET_DISK}$1" ;;
  esac
}

teardown(){ # release all mounts / LVM / LUKS this script may hold (idempotent)
  set +e
  umount -R "$MNT" 2>/dev/null || umount -Rl "$MNT" 2>/dev/null
  swapoff -a 2>/dev/null
  for vg in $(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' '); do
    vgchange -an "$vg" 2>/dev/null
  done
  cryptsetup close cryptroot 2>/dev/null
  set -e
}
# never leave mounts/dm behind, even if stage2 or a step fails
trap teardown EXIT

# ---------------- 0a. ensure the live-env front-half tools exist ----------------
# Lets the installer run on a pristine Debian live (only debootstrap's target
# gets the boot toolchain; these are what the FRONT half needs).
need="debootstrap cryptsetup gdisk dosfstools parted"
[ "$FS" = btrfs ] && need="$need btrfs-progs"
[ "$FS" = xfs ] && need="$need xfsprogs"
[ "$USE_LVM" = yes ] && need="$need lvm2"
[ "$LVM_THIN" = yes ] && need="$need thin-provisioning-tools"
missing=""
for t in $need; do dpkg -s "$t" >/dev/null 2>&1 || missing="$missing $t"; done
if [ -n "$missing" ]; then
  log "installing live-env tools:$missing"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq $missing
fi

# ---------------- 0a. summary + destructive confirmation ----------------
case "$PART_MODE" in
  auto)      _tgt="$TARGET_DISK  (WHOLE DISK WILL BE WIPED)"; _sz="ESP $ESP_SIZE + root $ROOT_PART_SIZE" ;;
  freespace) _tgt="$TARGET_DISK  (new partitions in free space; others kept)"; _sz="ESP $ESP_SIZE + root $ROOT_PART_SIZE" ;;
  custom)    if [ "$FORMAT_ESP" = yes ]; then _en=", ESP too"; else _en=""; fi
             _tgt="ESP=$ESP_PART root=$ROOT_PART  (existing; root will be formatted${_en})"; _sz="existing partitions" ;;
esac
cat <<SUMMARY

  Mode        : $PART_MODE
  Target      : $_tgt
  Layout      : $_sz
  Filesystem  : $FS$( [ "$FS" = btrfs ] && echo " (subvol @, $BTRFS_OPTS)" )$( [ "$USE_LVM" = yes ] && echo "  on LVM$( [ "$LVM_THIN" = yes ] && echo " (thin)" ), root LV=$ROOT_SIZE" )
  LUKS        : $USE_LUKS$( [ "$USE_LUKS" = yes ] && echo "  (unlock: $UNLOCK)" )
  Secure Boot : $SECUREBOOT$( [ "$SECUREBOOT" = yes ] && echo "  (shim + MOK, confirm at MokManager)" )
  Initramfs   : $( [ "$HOSTONLY" = yes ] && echo host-specific || echo generic )
  Hostname    : $HOSTNAME_

SUMMARY
if [ "$INTERACTIVE" = yes ]; then
  read -r -p "Type YES (uppercase) to proceed (this formats the root partition): " _ok
  [ "$_ok" = YES ] || { echo "aborted."; exit 1; }
fi

# ---------------- 0b. cleanup (release any dm/mounts this installer may hold) ----------------
teardown

# ---------------- 1. partition / locate ESP + root ----------------
# GPT names let us resolve devices by /dev/disk/by-partlabel/* (partition
# NUMBERS aren't predictable in freespace mode).
esp_label=pveuki-esp; root_label=pveuki-root
esp_end=$( case "$ESP_SIZE" in rest|max|100%*|"") echo 0 ;; *) echo "+${ESP_SIZE}" ;; esac )
case "$PART_MODE" in
  auto)
    log "partitioning $TARGET_DISK (auto wipe; ESP ${ESP_SIZE} + root ${ROOT_PART_SIZE})"
    # dd-zero first + last 16 MiB: nukes stale ZFS vdev labels, mdraid superblocks,
    # LUKS headers and the GPT backup so wipefs/sgdisk/mkfs can't trip over ghosts
    # (same approach as cache22's installer). AUTO ONLY: it destroys the whole disk.
    dd if=/dev/zero of="$TARGET_DISK" bs=1M count=16 conv=fsync 2>/dev/null || true
    dsz=$(blockdev --getsize64 "$TARGET_DISK" 2>/dev/null || echo 0)
    if [ "$dsz" -gt 33554432 ]; then
      dd if=/dev/zero of="$TARGET_DISK" bs=1M count=16 seek=$(( dsz/1048576 - 16 )) conv=fsync 2>/dev/null || true
    fi
    wipefs -a "$TARGET_DISK" 2>/dev/null || true
    sgdisk --zap-all "$TARGET_DISK" >/dev/null 2>&1 || true
    partprobe "$TARGET_DISK" 2>/dev/null || true; sleep 1
    sgdisk -n1:0:"${esp_end}" -t1:ef00 -c1:"$esp_label" "$TARGET_DISK"
    case "$ROOT_PART_SIZE" in
      rest|max|100%|100%FREE|"") sgdisk -n2:0:0 -t2:8304 -c2:"$root_label" "$TARGET_DISK" ;;
      *)                         sgdisk -n2:0:+"${ROOT_PART_SIZE}" -t2:8304 -c2:"$root_label" "$TARGET_DISK" ;;
    esac
    partprobe "$TARGET_DISK"; udevadm settle 2>/dev/null || sleep 1
    ESP=$(readlink -f "/dev/disk/by-partlabel/$esp_label")
    P2=$(readlink -f "/dev/disk/by-partlabel/$root_label")
    ;;
  freespace)
    log "partitioning $TARGET_DISK (freespace; keeping existing partitions)"
    # NEVER --zap-all here. partnum 0 = next free; sector 0 = next aligned free start.
    if [ -n "$ESP_PART" ]; then
      ESP="$(readlink -f "$ESP_PART")"     # reuse an existing ESP (set FORMAT_ESP=yes to reformat)
      [ "${FORMAT_ESP:-}" = yes ] || FORMAT_ESP=no
    else
      sgdisk -n0:0:"${esp_end}" -t0:ef00 -c0:"$esp_label" "$TARGET_DISK"
    fi
    case "$ROOT_PART_SIZE" in
      rest|max|100%|100%FREE|"") sgdisk --largest-new=0 -t0:8304 -c0:"$root_label" "$TARGET_DISK" ;;
      *)                         sgdisk -n0:0:+"${ROOT_PART_SIZE}" -t0:8304 -c0:"$root_label" "$TARGET_DISK" ;;
    esac
    partprobe "$TARGET_DISK"; udevadm settle 2>/dev/null || sleep 1
    [ -n "$ESP_PART" ] || ESP=$(readlink -f "/dev/disk/by-partlabel/$esp_label")
    P2=$(readlink -f "/dev/disk/by-partlabel/$root_label")
    ;;
  custom)
    log "using existing partitions (custom): ESP=$ESP_PART root=$ROOT_PART"
    ESP="$ESP_PART"; P2="$ROOT_PART"
    ;;
esac
{ [ -b "$ESP" ] && [ -b "$P2" ]; } || { echo "failed to resolve ESP ($ESP) / root ($P2)"; exit 1; }

# safety: the target partitions must not be mounted/held (custom mode may hand us
# partitions that are currently mounted). Never touch the live root, though.
for _d in "$P2" "$ESP"; do
  if [ "$(findmnt -nro TARGET --source "$_d" 2>/dev/null | head -1)" = / ]; then
    echo "refusing: $_d is mounted at / (the live root)"; exit 1
  fi
  for _mp in $(findmnt -nro TARGET --source "$_d" 2>/dev/null); do
    umount -R "$_mp" 2>/dev/null || umount -l "$_mp" 2>/dev/null || true
  done
done
# custom/freespace may reuse a partition carrying an old filesystem the kernel
# still has registered (btrfs auto-scan) or signatures that make mkfs/luksFormat
# report "Device or resource busy". Clear them. (auto wiped the whole disk above.)
if [ "$PART_MODE" != auto ]; then
  btrfs device scan --forget "$P2" 2>/dev/null || true
  wipefs -a "$P2" 2>/dev/null || true
fi

# ---------------- 2. ESP filesystem ----------------
if [ "${FORMAT_ESP:-yes}" = yes ]; then
  log "mkfs ESP $ESP"
  mkfs.vfat -F32 -n ESP "$ESP"
else
  log "reusing existing ESP $ESP (not formatting)"
fi

# ---------------- 3. LUKS (optional) ----------------
LUKS_UUID=""
BASE="$P2"
if [ "$USE_LUKS" = yes ]; then
  log "LUKS2 format+open on $P2"
  printf '%s' "$LUKSPW" | cryptsetup luksFormat --type luks2 --batch-mode "$P2" -
  printf '%s' "$LUKSPW" | cryptsetup open "$P2" cryptroot -
  LUKS_UUID=$(blkid -s UUID -o value "$P2")
  BASE=/dev/mapper/cryptroot
fi

# ---------------- 4. LVM (optional; thin or thick root) ----------------
if [ "$USE_LVM" = yes ]; then
  pvcreate -ff -y "$BASE"
  vgcreate "$VG" "$BASE"
  if [ "$LVM_THIN" = yes ]; then
    log "LVM thin: pool ${VG}/thinpool, thin root LV (size ${ROOT_SIZE})"
    lvcreate -y --type thin-pool -l 100%FREE -n thinpool "$VG"
    local_vsize="$ROOT_SIZE"; [ "$ROOT_SIZE" = "100%FREE" ] && local_vsize="$(lvs --noheadings -o lv_size --units b --nosuffix ${VG}/thinpool | tr -d ' ')b"
    lvcreate -y --type thin -V "$local_vsize" --thinpool "${VG}/thinpool" -n root "$VG"
  else
    log "LVM thick: root LV (size ${ROOT_SIZE})"
    if [ "$ROOT_SIZE" = "100%FREE" ]; then
      lvcreate -y -l 100%FREE -n root "$VG"
    else
      lvcreate -y -L "$ROOT_SIZE" -n root "$VG"
    fi
  fi
  ROOTDEV=/dev/$VG/root
else
  ROOTDEV="$BASE"
fi

# ---------------- 5. root filesystem ----------------
log "mkfs root ($FS) on $ROOTDEV"
case "$FS" in
  ext4)  mkfs.ext4 -F -L proxroot "$ROOTDEV" ;;
  xfs)   mkfs.xfs  -f -L proxroot "$ROOTDEV" ;;
  btrfs) mkfs.btrfs -f -L proxroot "$ROOTDEV" ;;
  *) echo "unknown FS=$FS"; exit 1 ;;
esac
ROOT_UUID=$(blkid -s UUID -o value "$ROOTDEV")
ESP_UUID=$(blkid -s UUID -o value "$ESP")

# ---------------- 6. mount target ----------------
log "mount target at $MNT"
mkdir -p "$MNT"
if [ "$FS" = btrfs ]; then
  mount "$ROOTDEV" "$MNT"
  btrfs subvolume create "$MNT/@" >/dev/null
  umount "$MNT"
  mount -o "subvol=@,$BTRFS_OPTS" "$ROOTDEV" "$MNT"
else
  mount "$ROOTDEV" "$MNT"
fi
mkdir -p "$MNT/boot/efi"
mount "$ESP" "$MNT/boot/efi"

# ---------------- 7. debootstrap ----------------
log "debootstrap $SUITE"
debootstrap --arch=amd64 "$SUITE" "$MNT" "$MIRROR"

# ---------------- 8. build kernel cmdline ----------------
CMDLINE="root=UUID=${ROOT_UUID} ro rootfstype=${FS}"
[ "$FS" = btrfs ] && CMDLINE="$CMDLINE rootflags=subvol=@,$BTRFS_OPTS"
[ "$USE_LVM" = yes ] && CMDLINE="$CMDLINE rd.lvm.lv=${VG}/root"
# NOTE: LUKS is driven by /etc/crypttab (tpm2-device=auto), NOT rd.luks.uuid.
# rd.luks.uuid alone makes the systemd-cryptsetup generator create a unit with
# no tpm2 option (so it never tries the TPM and falls to the passphrase); and
# having BOTH crypttab + rd.luks.uuid creates two conflicting units. stage2
# writes /etc/crypttab and bakes it into the initrd.
CMDLINE="$CMDLINE $EXTRA_CMDLINE"
CMDLINE=$(echo "$CMDLINE" | tr -s ' ')

# ---------------- 9. write env + stage2 into target ----------------
log "writing stage2 config"
cat > "$MNT/root/install.env" <<EOF
FS="${FS}"
USE_LVM="${USE_LVM}"
LVM_THIN="${LVM_THIN}"
USE_LUKS="${USE_LUKS}"
UNLOCK="${UNLOCK}"
SECUREBOOT="${SECUREBOOT}"
HOSTONLY="${HOSTONLY}"
SKIP_NVRAM="${SKIP_NVRAM}"
HOSTNAME_="${HOSTNAME_}"
ROOTPW="${ROOTPW}"
LUKSPW="${LUKSPW}"
MOKPW="${MOKPW}"
BTRFS_OPTS="${BTRFS_OPTS}"
ROOT_UUID="${ROOT_UUID}"
ESP_UUID="${ESP_UUID}"
LUKS_UUID="${LUKS_UUID}"
P2="${P2}"
CMDLINE="${CMDLINE}"
EOF

cp "$(dirname "$0")/stage2.sh" "$MNT/root/stage2.sh"
chmod +x "$MNT/root/stage2.sh"

# ---------------- 10. bind mounts + chroot ----------------
log "entering chroot for stage2"
cp /etc/resolv.conf "$MNT/etc/resolv.conf"
for d in proc sys dev dev/pts run; do
  mkdir -p "$MNT/$d"
  mount --rbind "/$d" "$MNT/$d"
  mount --make-rslave "$MNT/$d" 2>/dev/null || true
done
# efivarfs for bootctl/efibootmgr
mount -t efivarfs efivarfs "$MNT/sys/firmware/efi/efivars" 2>/dev/null || true

chroot "$MNT" /bin/bash /root/stage2.sh

# ---------------- 11. done ----------------
log "unmounting"
umount -R "$MNT" 2>/dev/null || true
[ "$USE_LVM" = yes ] && vgchange -an "$VG" 2>/dev/null || true
[ "$USE_LUKS" = yes ] && cryptsetup close cryptroot 2>/dev/null || true
log "INSTALL COMPLETE (FS=$FS LVM=$USE_LVM LUKS=$USE_LUKS UNLOCK=$UNLOCK SB=$SECUREBOOT)"
echo "cmdline was: $CMDLINE"
