#!/usr/bin/env bash


source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"


#    Check


set -Eeuo pipefail

require_stage 10-base


section_done "Check"



#    Intel


## Detect

PCI="$(lspci)"

	# captured first, then matched
	# lspci piped into grep -q dies on SIGPIPE under pipefail


## Driver

if grep -qi 'VGA.*Intel' <<< "$PCI"; then
	sudo pacman -S --needed --noconfirm mesa vulkan-intel intel-media-driver libva-utils
fi


## Parked

	# no nvidia branch on this machine
	# UHD 620 is Gen9.5, intel-media-driver is the iHD path


section_done "Intel"



#    HyDE


## Deps

sudo pacman -S --needed --noconfirm luarocks gobject-introspection
    # both discovered missing mid-install last time - pre-installed now


## Clone

git clone --depth 1 https://github.com/HyDE-Project/HyDE ~/HyDE

cd ~/HyDE/Scripts


## Install

sudo pacman -S archlinux-keyring

./install.sh -n > /dev/tty 2>&1


section_done "HyDE"



#    Chaotic


## Remove

read -rp "Remove chaotic-aur now? (y/N): " REMOVE_CHAOTIC
if [[ "$REMOVE_CHAOTIC" == "y" ]]; then
    sudo sed -i '/\[chaotic-aur\]/,+1d' /etc/pacman.conf
    sudo pacman -Rns --noconfirm chaotic-keyring chaotic-mirrorlist
    sudo pacman -Syu
fi


section_done "Chaotic"



#    Keyboard


## Guard

HYPR="$HOME/.config/hypr/hyprland.lua"

[[ -f "$HYPR" ]] || { echo "No hyprland.lua, HyDE did not finish" >&2; exit 1; }


## Hyprland

grep -q colemak "$HYPR" || cat >> "$HYPR" <<- 'EOF'
hl.config({
  input = {
    kb_variant = "colemak"
  }
})
EOF


## Console

sudo localectl set-x11-keymap us pc105 colemak

	# TTY is still qwerty in the VM


section_done "Keyboard"



#    Touchpad


## Clear

sed -i '/-- REBUILD TOUCHPAD START/,/-- REBUILD TOUCHPAD END/d' "$HYPR"

	# deleted then reappended so a rerun cannot stack copies


## Write

cat >> "$HYPR" <<- 'EOF'
	-- REBUILD TOUCHPAD START
	hl.config({
	  input = {
	    touchpad = {
	      natural_scroll = true,
	      tap_to_click = true,
	      disable_while_typing = true,
	    },
	  },
	})
	-- REBUILD TOUCHPAD END
EOF


section_done "Touchpad"



#    Monitors


## Parked

	# monitors.lua is not written here yet
	# the panel on this unit is either 1920x1080 or 3000x2000
	# scaling and the desc: string both depend on which, so check hyprctl monitors first


section_done "Monitors"



#    Verify


## Checks

check "hyprland"   command -v Hyprland
check "mesa"       pacman -Q mesa
check "hyprland.lua" test -f "$HYPR"
warn  "vulkan"     pacman -Q vulkan-intel
warn  "media"      pacman -Q intel-media-driver

verify_done


section_done "Verify"



#    End


stage_done 20-desktop

echo "Reboot"


section_done "End"
