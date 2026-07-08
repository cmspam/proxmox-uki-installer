#!/bin/bash
# Runs inside the chroot on the freshly debootstrapped target.
#
# Boot design (locked in):
#   firmware -> shim + MOK -> systemd-boot -> signed UKI
#   UKI = dracut initrd wrapped by ukify, signed for Secure Boot (MOK) AND
#         carrying a signed PCR policy (.pcrsig/.pcrpkey) so the TPM LUKS seal is
#         bound to the PCR-signing public key and survives kernel upgrades.
#   One MOK signs the UKI, systemd-boot, and DKMS modules.
#   Proxmox's own boot hooks (zz-systemd-boot / zz-proxmox-boot / zz-update-grub)
#   are dpkg-diverted (durable across upgrades); our zz-ukify hook builds the UKI.
set -euo pipefail
. /root/install.env
export DEBIAN_FRONTEND=noninteractive
KDIR=/var/lib/sbkeys

log(){ printf '\n\033[1;33m--- %s\033[0m\n' "$*"; }

# ---------- apt noninteractive ----------
cat > /etc/apt/apt.conf.d/90noninteractive <<'EOF'
APT::Get::Assume-Yes "true";
Dpkg::Options { "--force-confdef"; "--force-confold"; }
EOF

# ---------- identity + fstab ----------
log "hostname + fstab"
echo "$HOSTNAME_" > /etc/hostname
printf '127.0.0.1 localhost\n10.0.0.10 %s.localdomain %s\n' "$HOSTNAME_" "$HOSTNAME_" > /etc/hosts
btrfs_opts=""
[ "$FS" = btrfs ] && btrfs_opts=",subvol=@,${BTRFS_OPTS:-compress=zstd:1,noatime,space_cache=v2,discard=async}"
{
  echo "UUID=$ROOT_UUID / $FS defaults${btrfs_opts} 0 1"
  echo "UUID=$ESP_UUID /boot/efi vfat umask=0077 0 2"
} > /etc/fstab

# ---------- apt sources: debian + proxmox ----------
log "apt sources"
cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib
deb http://deb.debian.org/debian trixie-updates main contrib
deb http://security.debian.org/debian-security trixie-security main contrib
EOF
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg >/dev/null
curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg \
  -o /etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg
echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" \
  > /etc/apt/sources.list.d/pve.list
apt-get update -qq

# ---------- durably divert Proxmox's boot hooks BEFORE their packages install.
#            We manage the ESP + UKI ourselves via systemd-boot + zz-ukify.
#              zz-systemd-boot : runs `kernel-install add` (a second, competing
#                                UKI/initrd builder -> the "two initramfs" trap)
#              zz-proxmox-boot : proxmox-boot-tool ESP sync (errors w/o grub)
#              zz-update-grub  : grub-install to the ESP
#            dpkg-divert survives package upgrades: the updated hook is written to
#            the .disabled name and the live path stays empty. Nothing is pinned. ----------
log "divert proxmox boot hooks (durable)"
for h in zz-systemd-boot zz-proxmox-boot zz-update-grub; do
  dpkg-divert --add --rename --divert "/etc/kernel/postinst.d/${h}.disabled" \
    "/etc/kernel/postinst.d/${h}" >/dev/null
done
# ALSO the initramfs post-update hooks: /etc/initramfs/post-update.d/systemd-boot
# runs `kernel-install add` on every initrd rebuild, which creates a competing
# Type-1 BLS loader entry (loose kernel+initrd) that shows up in the menu next to
# our UKI. proxmox-boot-sync calls proxmox-boot-tool. Divert both.
for h in systemd-boot proxmox-boot-sync; do
  dpkg-divert --add --rename --divert "/etc/initramfs/post-update.d/${h}.disabled" \
    "/etc/initramfs/post-update.d/${h}" >/dev/null 2>&1 || true
done

# ---------- prevent service starts during chroot config ----------
cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d

# ---------- boot + UKI toolchain (tpm2-tools pulls libtss2, needed by ukify's
#            PCR signing; dracut satisfies the kernel initramfs alternative so
#            initramfs-tools is never pulled) ----------
log "install boot/UKI toolchain"
apt-get install -y -qq \
  dracut systemd-boot systemd-boot-efi systemd-ukify sbsigntool shim-signed \
  cryptsetup lvm2 tpm2-tools efibootmgr openssl

# ---------- dracut: initrd with crypt/lvm/tpm2 for the signed-PCR unlock.
#            HOSTONLY=yes -> host-specific (smaller, tied to this hardware);
#            no -> generic (boots on varied hardware). The signed PCR policy
#            covers PCR11 either way, so hostonly doesn't affect the unlock. ----------
log "dracut config (hostonly=${HOSTONLY:-no})"
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/10-uki.conf <<EOF
hostonly="${HOSTONLY:-no}"
add_dracutmodules+=" crypt lvm tpm2-tss systemd "
EOF

# ---------- crypttab for TPM auto-unlock. This is what makes systemd-cryptsetup
#            actually try the TPM: rd.luks.uuid alone generates a unit with no
#            tpm2 option. We name the mapper 'cryptroot' and force the crypttab
#            into the (generic) initrd via install_items so the generator sees it. ----------
if [ "$USE_LUKS" = yes ]; then
  log "crypttab (tpm2-device=auto)"
  echo "cryptroot UUID=${LUKS_UUID} none luks,discard,tpm2-device=auto" > /etc/crypttab
  echo 'install_items+=" /etc/crypttab "' > /etc/dracut.conf.d/15-crypttab.conf
fi

# ---------- signing keys: MOK (Secure Boot + DKMS) and PCR (policy) ----------
log "generate MOK + PCR keys"
mkdir -p "$KDIR"
if [ ! -f "$KDIR/MOK.key" ]; then
  # NON-CA (CA:FALSE) leaf code-signing cert. This one MOK signs the UKI,
  # systemd-boot, and (via DKMS) out-of-tree modules. shim enrolls it and the
  # kernel puts it in the .platform keyring; enrolling trust for it (mokutil
  # --trust-mok, below) links it into the .machine keyring, which module
  # signature verification under lockdown=integrity trusts (.builtin + .machine).
  # This is the generic/mainline path. (Proxmox's Ubuntu-derived kernel also
  # trusts .platform for modules, so enrollment alone would suffice there, but
  # we do not rely on that kernel-specific shortcut.) A leaf cert matches the
  # Debian DKMS convention and is accepted into .machine because Proxmox's kernel
  # leaves CONFIG_INTEGRITY_CA_MACHINE_KEYRING unset (no CA restriction).
  openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$KDIR/MOK.key" -out "$KDIR/MOK.crt" -subj "/CN=Proxmox UKI MOK/" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning"
  openssl x509 -in "$KDIR/MOK.crt" -outform DER -out "$KDIR/MOK.cer"
fi
if [ ! -f "$KDIR/pcr.key" ]; then
  openssl genrsa -out "$KDIR/pcr.key" 2048
  openssl rsa -in "$KDIR/pcr.key" -pubout -out "$KDIR/pcr.pub"
fi
chmod 600 "$KDIR"/*.key

# ---------- kernel cmdline (authoritative source for the UKI; admins append here) ----------
echo "$CMDLINE" > /etc/kernel/cmdline

# ---------- our UKI hook: dracut already built /boot/initrd.img-<ver>; wrap+sign it ----------
log "install zz-ukify hook"
mkdir -p /etc/kernel/postinst.d /etc/kernel/postrm.d /boot/efi/EFI/Linux
cat > /etc/kernel/postinst.d/zz-ukify <<'HOOK'
#!/bin/sh
set -e
version="$1"
[ -n "$version" ] || exit 0
KDIR=/var/lib/sbkeys
mkdir -p /boot/efi/EFI/Linux
exec /usr/lib/systemd/ukify build \
  --linux="/boot/vmlinuz-$version" \
  --initrd="/boot/initrd.img-$version" \
  --cmdline="@/etc/kernel/cmdline" \
  --uname="$version" \
  --secureboot-private-key="$KDIR/MOK.key" \
  --secureboot-certificate="$KDIR/MOK.crt" \
  --pcr-private-key="$KDIR/pcr.key" \
  --pcr-public-key="$KDIR/pcr.pub" \
  --pcrpkey="$KDIR/pcr.pub" \
  --pcr-banks=sha256 \
  --output="/boot/efi/EFI/Linux/proxmox-$version.efi"
HOOK
cat > /etc/kernel/postrm.d/zz-ukify <<'HOOK'
#!/bin/sh
version="$1"
[ -n "$version" ] || exit 0
rm -f "/boot/efi/EFI/Linux/proxmox-$version.efi"
HOOK
chmod +x /etc/kernel/postinst.d/zz-ukify /etc/kernel/postrm.d/zz-ukify

# ---------- rebuild helper (regenerate + re-sign the UKI after config changes) ----------
log "install pve-uki-rebuild helper"
install -d /usr/local/sbin
cat > /usr/local/sbin/pve-uki-rebuild <<'HELP'
#!/bin/sh
# Rebuild and re-sign the UKI after editing /etc/kernel/cmdline or the dracut
# config. With no argument it rebuilds every installed kernel; pass a version to
# rebuild just one (e.g. pve-uki-rebuild "$(uname -r)"). It regenerates the
# initrd, then rebuilds the UKI through the zz-ukify hook, which re-signs it for
# Secure Boot and regenerates the signed TPM2 PCR policy. Reboot afterwards.
set -e
HOOK=/etc/kernel/postinst.d/zz-ukify
[ -x "$HOOK" ] || { echo "missing $HOOK"; exit 1; }
build() {
  v="$1"
  [ -e "/boot/vmlinuz-$v" ] || { echo "no kernel /boot/vmlinuz-$v"; return 1; }
  echo "rebuilding initrd + UKI for $v"
  dracut --force "/boot/initrd.img-$v" "$v"
  "$HOOK" "$v"
}
if [ -n "$1" ]; then
  build "$1"
else
  for k in /boot/vmlinuz-*; do [ -e "$k" ] || continue; build "${k#/boot/vmlinuz-}"; done
fi
echo "done. reboot to apply."
HELP
chmod +x /usr/local/sbin/pve-uki-rebuild

# ---------- DKMS modules signed with the same MOK (loadable under Secure Boot) ----------
log "dkms signing via MOK"
mkdir -p /etc/dkms
cat > /etc/dkms/framework.conf <<EOF
mok_signing_key=$KDIR/MOK.key
mok_certificate=$KDIR/MOK.crt
EOF

# ---------- install the full Proxmox VE stack (fires zz-ukify -> builds the UKI) ----------
log "install proxmox-ve"
apt-get install -y proxmox-ve </dev/null || { rc=$?; echo "proxmox-ve apt rc=$rc; settling"; dpkg --configure -a || true; }

# ---------- place the loader in the ESP ----------
log "install loader (SECUREBOOT=$SECUREBOOT)"
mkdir -p /boot/efi/EFI/systemd /boot/efi/EFI/BOOT /boot/efi/loader/entries
# MOK-sign systemd-boot (harmless when SB is off)
sbsign --key "$KDIR/MOK.key" --cert "$KDIR/MOK.crt" \
  --output /boot/efi/EFI/systemd/systemd-bootx64.efi \
  /usr/lib/systemd/boot/efi/systemd-bootx64.efi
if [ "$SECUREBOOT" = yes ]; then
  # shim (MS-signed) -> grubx64.efi (== our MOK-signed systemd-boot)
  cp /usr/lib/shim/shimx64.efi.signed /boot/efi/EFI/BOOT/BOOTX64.EFI
  cp /usr/lib/shim/mmx64.efi.signed  /boot/efi/EFI/BOOT/mmx64.efi
  cp /boot/efi/EFI/systemd/systemd-bootx64.efi /boot/efi/EFI/BOOT/grubx64.efi
  BOOT_LOADER='\EFI\BOOT\BOOTX64.EFI'
else
  cp /boot/efi/EFI/systemd/systemd-bootx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
  BOOT_LOADER='\EFI\BOOT\BOOTX64.EFI'
fi
cat > /boot/efi/loader/loader.conf <<'EOF'
timeout 3
console-mode max
EOF

# NVRAM entry (test harness selects the disk via hypervisor boot-order, so skip)
if [ "${SKIP_NVRAM:-no}" != yes ]; then
  DISK=$(echo "$P2" | sed -E 's/p?2$//')
  efibootmgr -c -d "$DISK" -p 1 -L "Proxmox UKI" -l "$BOOT_LOADER" 2>/dev/null || \
    echo "note: efibootmgr NVRAM write skipped (EFI/BOOT fallback in use)"
fi

# ---------- MOK enrollment + trust request (Secure Boot) ----------
# Two staged requests, both confirmed in a single MokManager session at first
# boot (password = MOKPW):
#   1. --import     enrolls the MOK cert (kernel loads it into .platform).
#   2. --trust-mok  sets MokListTrustedRT so the kernel links the MOK into the
#                   .machine keyring, which module-signature verification trusts
#                   under lockdown=integrity. This is the generic/portable path;
#                   without it, MOK-signed modules load only on kernels that also
#                   trust .platform for modules (Proxmox's does, mainline does not).
MOKPW="${MOKPW:-$LUKSPW}"
if [ "$SECUREBOOT" = yes ]; then
  log "request MOK enrollment + trust (MokManager will prompt at first boot)"
  printf '%s\n%s\n' "$MOKPW" "$MOKPW" | mokutil --import "$KDIR/MOK.cer" || \
    echo "note: mokutil --import staged (enroll at console)"
  printf '%s\n%s\n' "$MOKPW" "$MOKPW" | mokutil --trust-mok || \
    echo "note: mokutil --trust-mok staged (confirm at console)"
fi

# ---------- TPM2 LUKS auto-unlock: NOT enrolled at install time ----------
# Enrollment is a post-boot, user-driven step: the machine must first boot the
# real UKI so PCR 11 reflects the actual measured boot. We install a helper the
# admin runs once after the first (passphrase) boot.
#
# CRITICAL: use --tpm2-public-key-pcrs (SIGNED policy on PCR 11, phase-independent
# — any value the UKI's .pcrsig signs validates, so it survives kernel upgrades),
# NOT --tpm2-pcrs=11 (a RAW bind to PCR 11's value at enroll time; PCR 11 is
# extended every boot phase, so a bind made in userspace never matches the
# initrd's enter-initrd phase and the unlock silently falls back to passphrase).
# The default raw bind lands on PCR 7 (Secure Boot state), which is stable across
# phases. Net policy = 7 (raw) + 11 (signed).
if [ "$USE_LUKS" = yes ]; then
  log "install post-boot TPM enroll helper (enrollment is NOT done at install time)"
  install -d /usr/local/sbin
  cat > /usr/local/sbin/pve-tpm-enroll <<EOF
#!/bin/sh
# Enroll the LUKS root for TPM2 auto-unlock. Run ONCE after the first boot
# (unlocked with the passphrase), so PCR 11 reflects the real measured boot.
set -e
DEV=\$(cryptsetup status cryptroot 2>/dev/null | sed -n 's/^ *device: *//p')
[ -n "\$DEV" ] || { echo "cryptroot not active"; exit 1; }
systemd-cryptenroll --wipe-slot=tpm2 "\$DEV" 2>/dev/null || true
systemd-cryptenroll --tpm2-device=auto \\
  --tpm2-public-key=${KDIR}/pcr.pub --tpm2-public-key-pcrs=11 "\$DEV"
echo "Enrolled. Reboot; it should unlock via TPM with no passphrase."
EOF
  chmod +x /usr/local/sbin/pve-tpm-enroll
fi

# ---------- root password + serial console ----------
log "root password + serial getty"
echo "root:$ROOTPW" | chpasswd
systemctl enable serial-getty@ttyS0.service >/dev/null 2>&1 || true

# ---------- remove chroot service guard ----------
rm -f /usr/sbin/policy-rc.d

# ---------- report ----------
log "RESULT"
echo "kernel(s):"; ls /boot/vmlinuz-* 2>/dev/null || echo "  NONE"
echo "UKI(s):"; ls -la /boot/efi/EFI/Linux/ 2>&1
echo "UKI sections:"; for u in /boot/efi/EFI/Linux/*.efi; do objdump -h "$u" 2>/dev/null | grep -oE "\.(linux|initrd|cmdline|osrel|pcrsig|pcrpkey|sbat|uname)" | tr '\n' ' '; echo; done
echo "UKI SB-signed by MOK?"; for u in /boot/efi/EFI/Linux/*.efi; do sbverify --cert "$KDIR/MOK.crt" "$u" 2>&1 | head -1; done
echo "diverted hooks (want .disabled present, live path gone):"; ls /etc/kernel/postinst.d/ | grep -E "zz-|dracut" | tr '\n' ' '; echo
echo "grub installed (dormant, hook diverted):"; dpkg -l grub-efi-amd64 2>/dev/null | grep -q ^ii && echo yes || echo no
echo "initramfs-tools installed? (want no):"; dpkg -l initramfs-tools 2>/dev/null | grep -q ^ii && echo yes || echo no
echo "embedded cmdline:"; for u in /boot/efi/EFI/Linux/*.efi; do objcopy -O binary --only-section=.cmdline "$u" /dev/stdout 2>/dev/null; echo; done
