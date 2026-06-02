################################################################################
#
# uefi-ab-chooser
#
# Minimal read-only UEFI A/B boot selector installed at /EFI/BOOT/BOOTX64.EFI.
#
# Source: github.com/oshlabs/uefi_ab_chooser. During Phase 2 bring-up we build
# from the sibling local checkout (SITE_METHOD = local) so the chooser and this
# system can co-evolve without a push/tag/hash round-trip. Before release this
# switches to a pinned github ref + hash (see the system PLAN.md).
#
################################################################################

UEFI_AB_CHOOSER_VERSION = local
UEFI_AB_CHOOSER_SITE = $(realpath $(NERVES_DEFCONFIG_DIR)/../uefi_ab_chooser)
UEFI_AB_CHOOSER_SITE_METHOD = local
UEFI_AB_CHOOSER_LICENSE = MIT
UEFI_AB_CHOOSER_LICENSE_FILES = main.c
UEFI_AB_CHOOSER_DEPENDENCIES = gnu-efi

# Built with the cross toolchain against the staged gnu-efi (libs + crt0 + lds
# in $(STAGING_DIR)/usr/lib, headers in $(STAGING_DIR)/usr/include/efi). The
# result, bootx64.efi, is a freestanding x86_64 PE/COFF EFI app.
#
# `clean` first: with SITE_METHOD = local the checkout's stray bootx64.efi (from
# standalone docker test builds) is rsynced in with its mtime, and make would
# otherwise consider it up to date and skip the cross rebuild.
UEFI_AB_CHOOSER_MAKE_OPTS = \
	CC="$(TARGET_CC)" \
	LD="$(TARGET_LD)" \
	OBJCOPY="$(TARGET_OBJCOPY)" \
	EFIINC="$(STAGING_DIR)/usr/include/efi" \
	EFILIB="$(STAGING_DIR)/usr/lib"

define UEFI_AB_CHOOSER_BUILD_CMDS
	$(MAKE) -C $(@D) $(UEFI_AB_CHOOSER_MAKE_OPTS) clean
	$(MAKE) -C $(@D) $(UEFI_AB_CHOOSER_MAKE_OPTS) all
endef

# Boot artifact, not a rootfs file: drop it in the images dir so fwup.conf can
# write it to the ESP as /EFI/BOOT/BOOTX64.EFI.
UEFI_AB_CHOOSER_INSTALL_TARGET = NO
UEFI_AB_CHOOSER_INSTALL_IMAGES = YES

define UEFI_AB_CHOOSER_INSTALL_IMAGES_CMDS
	$(INSTALL) -D -m 0644 $(@D)/bootx64.efi $(BINARIES_DIR)/chooser.efi
endef

$(eval $(generic-package))
