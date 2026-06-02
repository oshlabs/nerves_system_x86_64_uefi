# Include project-specific packages for this Nerves system.
# Pulled in by nerves_system_br's external.mk via NERVES_DEFCONFIG_DIR.
include $(sort $(wildcard $(NERVES_DEFCONFIG_DIR)/package/*/*.mk))
