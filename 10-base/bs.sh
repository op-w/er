#!/usr/bin/env bash


source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


#    Check


set -Eeuo pipefail

retry ping -c2 archlinux.org


section_done "Check"



#    Timezone


## Zone

sudo ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime


## Clock

sudo hwclock --systohc


section_done "Timezone"



#    Locale


## Generate

sudo sed -i "s/^#\($LOCALE\)/\1/" /etc/locale.gen

sudo locale-gen

locale -a | grep -q "en_US.utf8" || { echo "Locale not generated" >&2; exit 1; }


## Write

echo "LANG=$LOCALE" | sudo tee /etc/locale.conf

echo "KEYMAP=$KEYMAP" | sudo tee /etc/vconsole.conf


section_done "Locale"



#    Hostname


## Set

sudo hostnamectl set-hostname "$HOSTNAME"


## Hosts

grep -q "$HOSTNAME" /etc/hosts || sudo tee -a /etc/hosts > /dev/null << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF


section_done "Hostname"



#    TPM2


## Enroll

if [[ "$ENCRYPT" == yes ]]; then
	echo Encryption Pass
	sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "/dev/disk/by-partlabel/cryptsystem"
else
	echo "Encryption parked, nothing to enroll"
fi


section_done "TPM2"



#    Power


## Install

step "Power packages" sudo pacman -S --needed --noconfirm tlp thermald


## Conflict

sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket

	# tlp handles radio switching, systemd-rfkill fights it for the same state


## Enable

sudo systemctl enable --now tlp.service

sudo systemctl enable thermald.service

	# enable, not --now
	# thermald reads real thermal zones, there are none in a VM
	# starting it there fails and takes the whole stage with it


## Parked

	# lid and idle behaviour comes from hypridle in stage 20
	# battery thresholds are HP firmware dependent, not set here


section_done "Power"



#    zram


## Config

sudo tee /etc/systemd/zram-generator.conf > /dev/null << EOF
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF


section_done "zram"



#    yay


## Install

if ! command -v yay >/dev/null; then
	  step "Build deps" sudo pacman -S --needed --noconfirm git base-devel
	  step "Clone yay" git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
	  step "Build yay" bash -c "cd /tmp/yay-bin && makepkg -si --noconfirm"
fi


## Parked

	# yay -S limine-mkinitcpio-hook
	# ^ commented out


	# possible fixes

		# yay -S limine-mkinitcpio-hook-git

	# or

		# yay -S jdk21-graalvm-bin

		# yay -S limine-mkinitcpio-hook


	# if ! pacman -Qi limine-mkinitcpio-hook &>/dev/null; then
	    # echo "limine-mkinitcpio-hook didn't install"
	    # exit 1
	# fi

		# exits because of commented install


section_done "yay"



#    Verify


## Wireless

shopt -s nullglob
WIFI=(/sys/class/net/*/wireless)
shopt -u nullglob

	# Arch uses predictable names, wlan0 was never going to be there
	# any interface with a wireless directory counts


## Checks

check "hostname"       test "$(hostnamectl --static)" = "$HOSTNAME"
check "locale.conf"    test -f /etc/locale.conf
check "vconsole"       test -f /etc/vconsole.conf
check "networkmanager" systemctl is-active NetworkManager
check "tlp enabled"    systemctl is-enabled tlp
check "thermald set"   systemctl is-enabled thermald
warn  "thermald live"  systemctl is-active thermald
warn  "yay"            command -v yay
warn  "wifi device"    test "${#WIFI[@]}" -gt 0

verify_done


section_done "Verify"



#    End


stage_done 10-base

echo "Run de.sh"


section_done "End"
