#!/bin/sh

set -e

# No bootloader/GRUB. UEFI firmware boots the uefi_ab_chooser from the ESP
# fallback path /EFI/BOOT/BOOTX64.EFI (installed by its Buildroot package into
# $BINARIES_DIR/chooser.efi). The chooser reads bootstate and starts the active
# slot's kernel /EFI/nerves/vmlinuz-<slot>.efi (the bzImage, a valid PE/COFF EFI
# app thanks to CONFIG_EFI_STUB=y), supplying root=PARTUUID=<slot> via
# LoadOptions. The kernel also stays in the rootfs at /boot/bzImage (bundled with
# its modules) for the Phase 2 kexec warm-update path.

# Seed the chooser's bootstate into the images dir so fwup.conf can write it to
# the ESP at /EFI/nerves/bootstate. A fresh install cold-boots slot A (no trial
# in flight). During an update uefi_ab_agent adds try=/try_count=, the chooser
# counts attempts, and the agent promotes try->active on validation (Option B).
printf 'active=a\n' > $BINARIES_DIR/bootstate

# Create the fwup ops script to handle runtime operations (factory-reset,
# validate, status). revert.fw is a backwards-compatible alias.
mkdir -p $TARGET_DIR/usr/share/fwup
NERVES_SYSTEM=$BASE_DIR $HOST_DIR/usr/bin/fwup -c -f $NERVES_DEFCONFIG_DIR/fwup-ops.conf -o $TARGET_DIR/usr/share/fwup/ops.fw
ln -sf ops.fw $TARGET_DIR/usr/share/fwup/revert.fw

# Copy the fwup includes to the images dir
cp -rf $NERVES_DEFCONFIG_DIR/fwup_include $BINARIES_DIR
