#!/bin/sh

set -e

# No bootloader/GRUB. UEFI firmware boots the uefi_ab_chooser from the ESP
# fallback path /EFI/BOOT/BOOTX64.EFI (installed by its Buildroot package into
# $BINARIES_DIR/chooser.efi). The chooser reads bootstate and starts the active
# slot's kernel /EFI/nerves/vmlinuz-<slot>.efi (the bzImage, a valid PE/COFF EFI
# app thanks to CONFIG_EFI_STUB=y), supplying root=PARTUUID=<slot> via
# LoadOptions. The kernel also stays in the rootfs at /boot/bzImage (bundled with
# its modules) for the Phase 2 kexec warm-update path.

# Seed the chooser's bootstate files into the images dir so fwup.conf can write
# them to the ESP at /EFI/nerves/bootstate (Option B):
#   bootstate        - a fresh install: cold-boot slot A, no trial in flight.
#   bootstate-try-a  - written by `upgrade.a` (running B): start a trial of A.
#   bootstate-try-b  - written by `upgrade.b` (running A): start a trial of B.
# Starting a trial is what makes `fwup -t upgrade` (and so `mix firmware.upload`)
# boot the freshly-written slot. The chooser counts attempts and reverts to
# `active` on failure; uefi_ab_agent promotes try->active on validation.
printf 'active=a\n' > $BINARIES_DIR/bootstate
printf 'active=b\ntry=a\ntry_count=0\n' > $BINARIES_DIR/bootstate-try-a
printf 'active=a\ntry=b\ntry_count=0\n' > $BINARIES_DIR/bootstate-try-b

# Create the fwup ops script to handle runtime operations (factory-reset,
# validate, status). revert.fw is a backwards-compatible alias.
mkdir -p $TARGET_DIR/usr/share/fwup
NERVES_SYSTEM=$BASE_DIR $HOST_DIR/usr/bin/fwup -c -f $NERVES_DEFCONFIG_DIR/fwup-ops.conf -o $TARGET_DIR/usr/share/fwup/ops.fw
ln -sf ops.fw $TARGET_DIR/usr/share/fwup/revert.fw

# Copy the fwup includes to the images dir
cp -rf $NERVES_DEFCONFIG_DIR/fwup_include $BINARIES_DIR
