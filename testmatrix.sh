#!/bin/bash
# Test-matrix driver for the Proxmox UKI installer. Runs each mode/option combo
# against the target disk (auto-detected as the whole disk NOT holding the live
# root; device names swap across reboots so never hardcode), then inspects the
# on-disk result. Writes a consolidated report to RESULTS.txt.
# All tests use SECUREBOOT=no except the SB build-path test (can't do MokManager
# unattended; the SB+LUKS+TPM boot+auto-unlock path is already proven separately).
set -u
INS=/mnt/insp
RES=/root/RESULTS.txt
: > "$RES"
say(){ printf '%s\n' "$*" | tee -a "$RES"; }

# The target is whichever whole disk is NOT holding the live root. Device names
# (sda/sdb) swap across reboots in this VM, so NEVER hardcode — compute it, and
# refuse if it somehow resolves to the live root.
LIVEDISK=$(findmnt -nro SOURCE / | sed -E 's/p?[0-9]+$//')
DISK=$(lsblk -dpno NAME | grep -vE '/dev/(loop|sr|zram)' | grep -v "^${LIVEDISK}$" | head -1)
say "live root disk: $LIVEDISK ; TARGET disk: $DISK"
{ [ -n "$DISK" ] && [ "$DISK" != "$LIVEDISK" ] && [ -b "$DISK" ]; } || { echo "REFUSING: bad target ($DISK) vs live ($LIVEDISK)"; exit 1; }

cleanup_disk(){
  umount -R "$INS" 2>/dev/null
  umount -R /mnt/target 2>/dev/null   # in case a prior install left it mounted
  swapoff -a 2>/dev/null
  cryptsetup close insp 2>/dev/null
  cryptsetup close cryptroot 2>/dev/null
  for vg in $(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' '); do
    vgchange -an "$vg" 2>/dev/null; vgremove -ff "$vg" 2>/dev/null
  done
  for p in ${DISK}*; do
    [ "$p" = "$DISK" ] && continue
    [ -b "$p" ] && { btrfs device scan --forget "$p" 2>/dev/null; wipefs -a "$p" 2>/dev/null; }
  done
  wipefs -a "$DISK" 2>/dev/null
  sgdisk --zap-all "$DISK" >/dev/null 2>&1
  partprobe "$DISK" 2>/dev/null; udevadm settle 2>/dev/null; sleep 1
}

# inspect FS LVM LUKS ROOTPART  -> emits fstab/cmdline/crypttab lines from the install
inspect(){
  local fs="$1" lvm="$2" luks="$3" rp="$4" base dev
  mkdir -p "$INS"; base="$rp"
  if [ "$luks" = yes ]; then printf 'proxmox' | cryptsetup open "$rp" insp - 2>/dev/null; base=/dev/mapper/insp; fi
  if [ "$lvm" = yes ]; then vgchange -ay pve >/dev/null 2>&1; dev=/dev/pve/root; else dev="$base"; fi
  if [ "$fs" = btrfs ]; then mount -o subvol=@ "$dev" "$INS" 2>/dev/null; else mount "$dev" "$INS" 2>/dev/null; fi
  say "  fstab  : $(grep -E ' / ' "$INS"/etc/fstab 2>/dev/null | tr -s ' ')"
  say "  cmdline: $(cat "$INS"/etc/kernel/cmdline 2>/dev/null)"
  [ "$luks" = yes ] && say "  crypttab: $(cat "$INS"/etc/crypttab 2>/dev/null)"
  # confirm crypttab is baked into the dracut conf when LUKS
  [ "$luks" = yes ] && say "  dracut-crypttab: $(grep -h crypttab "$INS"/etc/dracut.conf.d/*.conf 2>/dev/null | tr -s ' ')"
  umount -R "$INS" 2>/dev/null
  [ "$lvm" = yes ] && vgchange -an pve >/dev/null 2>&1
  [ "$luks" = yes ] && cryptsetup close insp 2>/dev/null
}

# run_test  NAME  "ENV=v ENV=v ..."   FS LVM LUKS  ROOTPART_for_inspect
run_test(){
  local name="$1" envs="$2" fs="$3" lvm="$4" luks="$5" rp="$6"
  say ""; say "======================================================================"
  say "TEST: $name"
  say "  env: $envs"
  local log="/root/t_${name}.log"
  # run each install in a PRIVATE mount namespace so its /mnt/target (+chroot binds)
  # can't propagate into systemd daemons' namespaces and leave the target partition
  # busy for the next test. The namespace (and all its mounts) is torn down on exit.
  ( export NONINTERACTIVE=yes SECUREBOOT=no; eval "export $envs"; unshare --mount --propagation private bash /root/install.sh ) > "$log" 2>&1
  local rc=$?
  say "  EXIT: $rc"
  say "  layout:"; lsblk -pno NAME,SIZE,PARTLABEL,FSTYPE "$DISK" 2>/dev/null | sed 's/^/    /' | tee -a "$RES" >/dev/null
  say "  UKI/RESULT:"
  grep -E "UKI SB-signed|proxmox-.*\.efi|diverted hooks|grub installed|initramfs-tools installed|INSTALL COMPLETE" "$log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g; s/^/    /' | tee -a "$RES" >/dev/null
  if [ "$rc" = 0 ]; then inspect "$fs" "$lvm" "$luks" "$rp"; else say "  (install failed; see $log)"; grep -iE "error|fail|busy|no such|cannot" "$log" | tail -4 | sed 's/^/    /' | tee -a "$RES" >/dev/null; fi
}

########## AUTO-mode matrix ##########
cleanup_disk
run_test "auto_ext4_rootsize6G" "PART_MODE=auto TARGET_DISK=$DISK FS=ext4 ROOT_PART_SIZE=6G USE_LVM=no USE_LUKS=no" ext4 no no ${DISK}2

cleanup_disk
run_test "auto_xfs_esp2G" "PART_MODE=auto TARGET_DISK=$DISK FS=xfs ESP_SIZE=2GiB USE_LVM=no USE_LUKS=no" xfs no no ${DISK}2

cleanup_disk
run_test "auto_btrfs" "PART_MODE=auto TARGET_DISK=$DISK FS=btrfs USE_LVM=no USE_LUKS=no" btrfs no no ${DISK}2

cleanup_disk
run_test "auto_ext4_lvm_thick_4G" "PART_MODE=auto TARGET_DISK=$DISK FS=ext4 USE_LVM=yes LVM_THIN=no ROOT_SIZE=4G USE_LUKS=no" ext4 yes no ${DISK}2

cleanup_disk
run_test "auto_ext4_lvm_thin_luks_tpm2" "PART_MODE=auto TARGET_DISK=$DISK FS=ext4 USE_LVM=yes LVM_THIN=yes USE_LUKS=yes UNLOCK=tpm2 LUKSPW=proxmox" ext4 yes yes ${DISK}2

########## SB build-path (signed UKI + shim + MOK), btrfs + LUKS passphrase + hostonly ##########
cleanup_disk
say ""; say "======================================================================"
say "TEST: sb_btrfs_luks_pass_hostonly (SECUREBOOT=yes build path)"
( export NONINTERACTIVE=yes; export PART_MODE=auto TARGET_DISK=$DISK FS=btrfs USE_LUKS=yes UNLOCK=passphrase LUKSPW=proxmox SECUREBOOT=yes HOSTONLY=yes MOKPW=12345678; unshare --mount --propagation private bash /root/install.sh ) > /root/t_sb.log 2>&1
say "  EXIT: $?"
say "  layout:"; lsblk -pno NAME,SIZE,PARTLABEL,FSTYPE "$DISK" | sed 's/^/    /' | tee -a "$RES" >/dev/null
grep -E "UKI SB-signed|Signature verification|proxmox-.*\.efi|shim|diverted hooks|INSTALL COMPLETE" /root/t_sb.log | sed 's/\x1b\[[0-9;]*m//g; s/^/    /' | tee -a "$RES" >/dev/null
# verify the SB artifacts on the ESP
mkdir -p /mnt/esp; mount ${DISK}1 /mnt/esp 2>/dev/null
say "  ESP files: $(ls /mnt/esp/EFI/BOOT /mnt/esp/EFI/Linux 2>/dev/null | tr '\n' ' ')"
say "  BOOTX64 is shim?: $(sbverify --list /mnt/esp/EFI/BOOT/BOOTX64.EFI 2>/dev/null | grep -c signature || echo '?') sigs; $(mokutil --sb-state 2>/dev/null)"
umount /mnt/esp 2>/dev/null
inspect btrfs no yes ${DISK}2

########## FREESPACE mode: preserve a pre-existing partition ##########
cleanup_disk
say ""; say "======================================================================"
say "TEST: freespace_ext4 (preserve a foreign partition)"
# lay down a foreign 3G ext4 partition at the start, marker file, leave rest free
sgdisk -n1:0:+3G -t1:8300 -c1:foreign-data "$DISK" >/dev/null; partprobe "$DISK"; udevadm settle; sleep 1
mkfs.ext4 -F -L foreign ${DISK}1 >/dev/null 2>&1
mkdir -p /mnt/f; mount ${DISK}1 /mnt/f; echo "DO-NOT-DELETE" > /mnt/f/marker.txt; umount /mnt/f
run_test "freespace_ext4" "PART_MODE=freespace TARGET_DISK=$DISK FS=ext4 USE_LVM=no USE_LUKS=no" ext4 no no ""
# verify the foreign partition + marker survived
mkdir -p /mnt/f; mount ${DISK}1 /mnt/f 2>/dev/null
say "  foreign marker survived?: $(cat /mnt/f/marker.txt 2>/dev/null || echo MISSING)"
umount /mnt/f 2>/dev/null
say "  full layout after freespace:"; lsblk -pno NAME,SIZE,PARTLABEL,FSTYPE "$DISK" | sed 's/^/    /' | tee -a "$RES" >/dev/null
# resolve the freespace-created root by partlabel for inspection
FS_ROOT=$(readlink -f /dev/disk/by-partlabel/pveuki-root 2>/dev/null)
say "  freespace root part: $FS_ROOT"
[ -n "$FS_ROOT" ] && inspect ext4 no no "$FS_ROOT"

########## CUSTOM mode: reuse existing partitions, both FORMAT_ESP values ##########
# reuse the ESP + root that freespace just created
CUS_ESP=$(readlink -f /dev/disk/by-partlabel/pveuki-esp 2>/dev/null)
CUS_ROOT=$(readlink -f /dev/disk/by-partlabel/pveuki-root 2>/dev/null)
run_test "custom_btrfs_reuse_esp" "PART_MODE=custom ESP_PART=$CUS_ESP ROOT_PART=$CUS_ROOT FORMAT_ESP=no FS=btrfs USE_LVM=no USE_LUKS=no" btrfs no no "$CUS_ROOT"
run_test "custom_ext4_format_esp" "PART_MODE=custom ESP_PART=$CUS_ESP ROOT_PART=$CUS_ROOT FORMAT_ESP=yes FS=ext4 USE_LVM=no USE_LUKS=no" ext4 no no "$CUS_ROOT"

say ""; say "======================================================================"
say "MATRIX COMPLETE"
