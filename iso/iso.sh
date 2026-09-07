#!/usr/bin/env bash


source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


#    Check


set -Eeuo pipefail


## Config

if [[ ! -f "$CONFIG" ]]; then
	read -rp "Hostname: " h
	read -rp "Username: " u
	[[ -n "$h" && -n "$u" ]] || { echo "Both required" >&2; exit 1; }
	printf 'HOSTNAME="%s"\nUSERNAME="%s"\n' "$h" "$u" > "$CONFIG"
	source "$CONFIG"
fi


## Console

loadkeys "$KEYMAP"

timedatectl set-ntp true


## Link

if ! ping -c2 -W3 archlinux.org &>/dev/null; then
	echo
	echo "No network."
	echo "iwctl is the live ISO tool for wifi. Connect, then run this again."
	echo
	exit 1
fi


section_done "Check"



#    Preflight


## Tools

check "sgdisk"       command -v sgdisk
check "partprobe"    command -v partprobe
check "mkfs.btrfs"   command -v mkfs.btrfs
check "mkfs.fat"     command -v mkfs.fat
check "pacstrap"     command -v pacstrap
check "arch-chroot"  command -v arch-chroot
check "genfstab"     command -v genfstab
check "reflector"    command -v reflector

if [[ "$ENCRYPT" == yes ]]; then
	check "cryptsetup" command -v cryptsetup
fi


## Firmware

check "UEFI 64 bit" test "$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null)" = 64

warn "clock synced" test "$(timedatectl show -p NTPSynchronized --value)" = yes


## Report

verify_done


section_done "Preflight"



#    Partitions


## Pick

lsblk -o NAME,SIZE,MODEL,TRAN,TYPE,MOUNTPOINTS

echo

SYSTEM_DISK="$(pick_disk 'System disk: ')"

require_disk "$SYSTEM_DISK"

DISK_ID="$(disk_id "$SYSTEM_DISK")"


## Confirm

echo
echo =============================
echo
echo "WILL BE WIPED: $SYSTEM_DISK $(lsblk -dno SIZE "$SYSTEM_DISK")"
echo "Model:         $(lsblk -dno MODEL "$SYSTEM_DISK")"
echo "Transport:     $(lsblk -dno TRAN "$SYSTEM_DISK")"
echo "Stable id:     $DISK_ID"
echo "Encryption:    $ENCRYPT"
echo

confirm


## Layout

if [[ "$ENCRYPT" == yes ]]; then
	ROOT_LABEL="cryptsystem"
else
	ROOT_LABEL="system"
fi

sgdisk --zap-all "$SYSTEM_DISK"
sgdisk -n1:0:+4G -t1:EF00 -c1:"EFI"          "$SYSTEM_DISK"
sgdisk -n2:0:0   -t2:8300 -c2:"$ROOT_LABEL"  "$SYSTEM_DISK"

partprobe "$SYSTEM_DISK"


## Names

SYS_ESP="$(partname "$SYSTEM_DISK" 1)"
SYS_ROOT="$(partname "$SYSTEM_DISK" 2)"

udevadm settle

wait_for 10 test -b "$SYS_ESP"
wait_for 10 test -b "$SYS_ROOT"


## Encrypt

if [[ "$ENCRYPT" == yes ]]; then
	clear
	echo Encryption setup
	echo Set Password
	retry cryptsetup luksFormat --type luks2 "$SYS_ROOT"

	clear
	echo Encryption open
	echo Retype Password
	retry cryptsetup open "$SYS_ROOT" cryptsystem
	clear

	ROOT_DEV="/dev/mapper/cryptsystem"
else
	ROOT_DEV="$SYS_ROOT"
fi


## Format

mkfs.fat -F32 "$SYS_ESP"

step "Format root" mkfs.btrfs -L system "$ROOT_DEV"


## Subvols

mount "$ROOT_DEV" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt


## Mount

mount -o compress=zstd:1,noatime,subvol=@ "$ROOT_DEV" /mnt

mount --mkdir -o compress=zstd:1,noatime,subvol=@snapshots "$ROOT_DEV" /mnt/.snapshots

mount --mkdir -o compress=zstd:1,noatime,subvol=@home "$ROOT_DEV" /mnt/home

mount --mkdir "$SYS_ESP" /mnt/boot


## Review

clear
lsblk

echo
echo
echo =============================
echo
echo

findmnt -R /mnt

confirm


section_done "Partitions"



#    Installs


## Mirrors

slow "Mirrors" reflector --latest 10 --protocol https --age 12 --sort rate --save /etc/pacman.d/mirrorlist

	# reflector rate tests mirrors and prints nothing while it does
	# slow gives it a heartbeat so it does not look hung


## Pacstrap

step "Kernel and firmware" pacstrap -K /mnt base linux linux-firmware intel-ucode

step "Filesystem and build tools" pacstrap -K /mnt btrfs-progs sudo base-devel git

step "Network" pacstrap -K /mnt networkmanager wpa_supplicant iwd

step "Snapshots and zram" pacstrap -K /mnt zram-generator snapper snap-pac

step "Bootloader" pacstrap -K /mnt limine efibootmgr dosfstools mtools

step "Shell tools" pacstrap -K /mnt nano bash-completion openssh gobject-introspection

if [[ "$ENCRYPT" == yes ]]; then
	step "Encryption tools" pacstrap -K /mnt cryptsetup tpm2-tools
fi


## Fstab

genfstab -U /mnt > /mnt/etc/fstab


section_done "Installs"



#    Chroot


## Verify

arch-chroot /mnt pacman -Q limine efibootmgr btrfs-progs


## Console

arch-chroot /mnt sh -c "echo 'KEYMAP=$KEYMAP' > /etc/vconsole.conf"


## Modules

arch-chroot /mnt sed -i \
  's/^MODULES=.*/MODULES=(xhci_pci usb_storage uas nvme)/' \
  /etc/mkinitcpio.conf

	# autodetect trims to hardware seen at build time
	# forcing usb here is what lets an external root be found at boot


## Hooks

if [[ "$ENCRYPT" == yes ]]; then
	HOOKLIST="base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck"
else
	HOOKLIST="base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck"
fi

arch-chroot /mnt sed -i "s/^HOOKS=.*/HOOKS=($HOOKLIST)/" /etc/mkinitcpio.conf

step "Initramfs" arch-chroot /mnt mkinitcpio -P


## Network

arch-chroot /mnt systemctl enable NetworkManager


section_done "Chroot"



#    Users


## Names

[[ "$HOSTNAME" != CHANGEME ]] || { echo "Set a hostname" >&2; exit 1; }

[[ "$USERNAME" != CHANGEME ]] || { echo "Set a username" >&2; exit 1; }


## Root

echo Set Root Passwd
retry arch-chroot /mnt passwd


## User

if ! arch-chroot /mnt id -u "$USERNAME" &>/dev/null; then
	arch-chroot /mnt useradd -m -G wheel "$USERNAME"
fi

clear
echo Set User Passwd
retry arch-chroot /mnt passwd "$USERNAME"
clear


## Sudo

arch-chroot /mnt sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers


section_done "Users"



#    Bootloader


## Script

cat > /mnt/root/_setup.sh << CHROOTEOF
set -euo pipefail

mkdir -p /boot/EFI/limine
mkdir -p /boot/EFI/BOOT

cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/limine_x64.efi

cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI

find /boot -iname "*.efi"

efibootmgr --create --disk $SYSTEM_DISK --part 1 --label "Arch Linux Limine Boot Loader" --loader '\EFI\limine\limine_x64.efi' --unicode || echo "No NVRAM entry created, removable fallback will be used" >&2

efibootmgr -v || true

ROOT_UUID=\$(blkid -s UUID -o value $ROOT_DEV)

systemd-machine-id-setup

cat > /boot/limine.conf << ENTRYEOF
timeout: 3
/+Arch Linux
    comment: machine-id=\$(cat /etc/machine-id)
    //Linux
        protocol: linux
        path: boot():/vmlinuz-linux
        module_path: boot():/intel-ucode.img
        module_path: boot():/initramfs-linux.img
        cmdline: root=UUID=\$ROOT_UUID rootflags=subvol=@ rw
    //Snapshots
ENTRYEOF

rm -f /boot/EFI/limine/limine.conf
CHROOTEOF


## Run

arch-chroot /mnt bash /root/_setup.sh
rm /mnt/root/_setup.sh


section_done "Bootloader"



#    End


## Logs

clear

cp /var/log/install/iso.log /mnt/var/log/

cp "$CONFIG" /mnt/home/"$USERNAME"/.install-config
	sudo chown 1000:1000 /mnt/home/"$USERNAME"/.install-config


## Repo

step "Copy repo" cp -a "$REPO" /mnt/home/"$USERNAME"/

chown -R 1000:1000 /mnt/home/"$USERNAME"/"$(basename "$REPO")"

	# .git comes with it, so the installed system can pull and push
	# no second clone after the reboot


## Unmount

umount -R /mnt

lsblk

echo
echo ============================
echo "Reboot"
echo 
echo "Pull the install stick, leave the SSD in"
echo
echo "Run bs.sh after"
echo ============================
echo


section_done "End"
