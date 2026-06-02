#!/bin/sh

set -e

# No bootloader: UEFI firmware boots the EFI-stub kernel directly from the ESP.
# The kernel (bzImage, a valid PE/COFF UEFI app thanks to CONFIG_EFI_STUB=y) is
# left in $BINARIES_DIR/bzImage by Buildroot and written to /EFI/BOOT/BOOTX64.EFI
# by fwup.conf. It also stays in the rootfs at /boot/bzImage (bundled with its
# modules) for the Phase 2 kexec path.

# Create the fwup ops script to handle runtime operations (factory-reset,
# validate, status). revert.fw is a backwards-compatible alias.
mkdir -p $TARGET_DIR/usr/share/fwup
NERVES_SYSTEM=$BASE_DIR $HOST_DIR/usr/bin/fwup -c -f $NERVES_DEFCONFIG_DIR/fwup-ops.conf -o $TARGET_DIR/usr/share/fwup/ops.fw
ln -sf ops.fw $TARGET_DIR/usr/share/fwup/revert.fw

# Copy the fwup includes to the images dir
cp -rf $NERVES_DEFCONFIG_DIR/fwup_include $BINARIES_DIR
