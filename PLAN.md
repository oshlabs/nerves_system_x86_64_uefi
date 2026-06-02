# PLAN — Generic UEFI x86_64 Nerves System

A Nerves 2.0+ system for x86_64 that boots via **UEFI** (no GRUB), runs from a
`dd`'d USB stick or onboard disk, aims to be **hardware-generic**, and does
atomic A/B firmware updates validated with **kexec** before commit.

## Status

- Repo: `github.com/oshlabs/nerves_system_x86_64_uefi`, forked from
  `nerves-project/nerves_system_x86_64`.
- Working branch: `feature/uefi-boot`.
- **Phase 1 COMPLETE and verified booting.** The system builds and boots the
  full chain under QEMU/OVMF (NVMe disk):
  `UEFI firmware -> ESP -> /EFI/BOOT/BOOTX64.EFI (EFI-stub kernel) -> NVMe ->
  GPT PARTUUID -> squashfs root mounted -> init`. All critical kernel symbols
  survived `olddefconfig` (EFI_STUB, EFI_PARTITION, BLK_DEV_NVME, SATA_AHCI,
  USB_UAS, FB_EFI, KEXEC_FILE, ITCO_WDT, IGC=m, CONFIG_CMDLINE). erlinit reaches
  userspace and only stops because the bare system has no Elixir app baked in
  (expected) and p4 isn't ext4 yet (nerves_runtime would format it).

  Build environment: must build in the Debian-bookworm container
  (`~/src/nerves/buildenv/`), because the Arch host (GCC 16 / cmake 4.x) breaks
  Buildroot's host-cmake. Image assembly + QEMU test run on the host (fwup,
  qemu, edk2-ovmf all present): `buildenv/mkimage.sh` + `buildenv/qemu-test.sh`.

  A real Nerves app (mix firmware against this system) **boots to an IEx prompt**
  under QEMU/OVMF (NVMe): nerves_runtime auto-formats the ext4 app partition (p4),
  the OTP release starts 38 applications, nerves_pack/vintage_net brings up eth0
  via DHCP, and IEx is interactive. Platform reports `x86_64_uefi x86_64`.

  Build notes: the Buildroot system must be built in the Debian container with the
  tree mounted at the SAME path as the host (host tools bake in their build path).
  Firmware assembly + image run on the host with host OTP pinned to the target's
  (28.5): ASDF_ERLANG_VERSION=28.5.0.1, source nerves-env.sh, MIX_TARGET=x86_64_uefi,
  mix firmware && mix firmware.image. Throwaway app: ~/src/nerves/uefi_test.

  Next: test on real N100 hardware (dd to USB, Secure Boot off); confirm igc NICs
  and iTCO watchdog bind. Then Phase 2 (kexec A/B).
- Base versions (inherited from the fork): `nerves_system_br` 1.33.7,
  Linux 6.12, musl toolchain.
- Reference only: `../nerves_system_x86_64_uefi-1.5.1` (Nerves 1.5, Linux 4.18)
  — used solely for its grub-efi/ESP recipe, NOT as a base.

## Goals

- Boot via UEFI on real hardware; image is `dd`-able to a USB stick and boots
  fully from it on (ideally) any machine.
- First test target: Intel Alder Lake **N100** mini PC, onboard **NVMe** root
  disk, 4× Intel **I226** 2.5GbE NICs (`igc`). Do not hard-code to it — stay
  generic.
- Boot-critical drivers built into the kernel; as many other drivers as possible
  as modules in the squashfs.
- A/B rootfs slots (like the rpi systems) with safe rollback.
- musl libc (already the x86_64 default — keep).
- Later: replace `eudev` and `vintage_net` with own components (would require a
  `nerves_system_br` fork — out of scope until base boots).

## Boot architecture (decided)

**GPT + FAT ESP + EFI-stub kernel at `/EFI/BOOT/BOOTX64.EFI` — no GRUB.**

Rationale: UEFI firmware locates the ESP by GPT type GUID (spec-guaranteed;
MBR-`0xEF` is only the legacy-BIOS/GRUB path). Booting the firmware **fallback
path** `/EFI/BOOT/BOOTX64.EFI` means a `dd`'d stick boots on any machine without
touching that machine's NVRAM. The Linux kernel built with `CONFIG_EFI_STUB=y`
is itself a valid UEFI executable, so no bootloader is needed.

Consequence: firmware can only read FAT, not squashfs, so **the kernel lives on
the FAT ESP**, not inside the rootfs.

### Update / validate / commit = kexec (not bootloader boot-counting)

The "is the new firmware good?" logic runs in Linux/Elixir, not in the boot
chain:

```
cold-boot committed slot A  →  receive update  →  fwup writes kernel+rootfs to slot B
  →  from running A:  kexec -l <B kernel> --append="root=PARTUUID=<B> …"  ;  kexec -e
  →  B boots (no firmware POST), runs Elixir health checks
       ├─ healthy → COMMIT: flip persistent `active` → B  (next cold boot = B)
       └─ fail/panic/hang → hardware watchdog resets
            → firmware → chooser → boots COMMITTED slot = still A   (rollback)
```

Why: rollback needs **no** boot counter in the bootloader — failure just hits the
watchdog and cold-boots the still-committed slot. This keeps the EFI chooser
trivial and puts the real logic in Elixir.

Requirements this imposes:
- `CONFIG_KEXEC_FILE=y` + `kexec-tools` (Buildroot package).
- A **hardware watchdog** (N100 chipset WDT) petted from Elixir — the linchpin of
  the rollback guarantee. Also `panic=<n>` as a backstop.
- Both UKIs kept permanently on the ESP; "commit" is a one-byte flip of `active`
  → atomic, no kernel copy at commit time.

### Update writes two artifacts, but stays atomic

Because firmware can't read squashfs, the kernel is no longer bundled inside the
rootfs (as it was under GRUB). An update therefore writes **two** artifacts: the
squashfs to the inactive rootfs slot, and that slot's UKI to the ESP. This is
NOT problematic:

- It is **one fwup transaction** (one `.fw` task with both steps), not two
  operator actions — same as how the current upgrade task already touches more
  than just the rootfs.
- The two UKIs have **distinct filenames** (`bootx64-a.efi` / `bootx64-b.efi`),
  so writing the inactive slot's UKI can never corrupt the running slot's.
- The **`active` flip is the single atomic gate**, performed last, only after
  both writes complete. Any power loss before the flip leaves the system on the
  still-committed slot (retry redoes both). Identical safety property to Nerves
  today (fully write inactive slot, then flip pointer) — just two artifacts to
  write before the one flip.
- New invariant: the ESP kernel and the rootfs `/lib/modules/<ver>` must match.
  Guaranteed because both come from the same build and the same `.fw`, written
  together; never update one without the other.

Refinement: keep the **bare `bzImage` + `/lib/modules`** inside each slot's
squashfs (kernel and modules versioned together, immutable). The kexec
warm-update path loads that bare bzImage from the new slot's squashfs with
`--append "root=PARTUUID=<slot>…"` (`kexec_file_load` wants a bare bzImage, not a
PE/UKI). The ESP UKI is the cold-boot copy of the same kernel with cmdline baked
in. Kernel stored twice (~10 MB, negligible) for clean separation.

### Cold-boot chooser

`github.com/oshlabs/uefi_ab_chooser` — a minimal (~80-line) read-only UEFI app
in C (Buildroot `gnu-efi`), installed at `/EFI/BOOT/BOOTX64.EFI`. It reads one
field (`active = a|b`) from a small state file on the ESP and
`LoadImage`/`StartImage`s the matching UKI (`bootx64-a.efi` / `bootx64-b.efi`).
No boot-counting, no writes from firmware context. Built as a separate repo,
pulled in as a Buildroot package pinned to a git ref.

Per-slot kernel command line is solved by making each kernel a **UKI** (kernel +
its own baked-in `root=PARTUUID=<slot>` cmdline) — the chooser only selects the
file, never parses cmdlines.

### ESP layout (Phase 3)

```
ESP  (FAT, shared, ~100 MiB):
  /EFI/BOOT/BOOTX64.EFI       <- the chooser (firmware fallback path = what UEFI loads)
  /EFI/nerves/bootx64-a.efi   <- UKI for slot A (kernel + baked root=PARTUUID=<A>)
  /EFI/nerves/bootx64-b.efi   <- UKI for slot B
  /EFI/nerves/bootstate       <- tiny state file: active = a|b
```

- The chooser is **shared, not A/B** — one stable binary that decides which slot
  to boot. The UKIs and `bootstate` are the per-update churn.
- `/EFI/BOOT/BOOTX64.EFI` is the **single point of failure for cold boot**
  (removable media has no on-disk second fallback). Therefore the chooser is
  written at **image/install time and is NOT part of normal OTA updates** — all
  per-update writes go to the UKIs and `bootstate`. A deliberate chooser update,
  if ever needed, is a separate temp-write-then-rename operation.
- **Phase 1 vs Phase 3:** in Phase 1 there is no chooser — `/EFI/BOOT/BOOTX64.EFI`
  *is* the EFI-stub kernel directly. At Phase 3 that path becomes the chooser and
  the kernels move to `/EFI/nerves/bootx64-{a,b}.efi`. The firmware-booted path
  (`/EFI/BOOT/BOOTX64.EFI`) is constant; only its contents change.

## Kernel config strategy

Built-in (`=y`) — must be present to reach the rootfs on generic hardware:
- `CONFIG_EFI`, `CONFIG_EFI_STUB`, `CONFIG_EFI_PARTITION` (GPT)
- `CONFIG_BLK_DEV_NVME` (onboard root), AHCI/SATA
- `xhci-hcd`, `ehci-hcd`, `usb-storage`, `uas` (USB-stick boot + recovery)
- `CONFIG_SQUASHFS`, `CONFIG_VFAT_FS`, `CONFIG_EXT4_FS`
- `efifb` / `simpledrm` (console on any machine)
- `CONFIG_KEXEC_FILE`, watchdog driver(s)

Modules (`=m`) in squashfs — everything else, widened toward distro-generic over
time:
- `igc` (I226 NICs — networking starts after root mounts, not boot-critical),
  other NICs, GPU (i915/Xe), sound, Wi-Fi, USB peripherals, …

squashfs is compressed, so a large module tree is cheap.

## Phased roadmap

| Phase | Boot path | A/B | Scope |
|-------|-----------|-----|-------|
| **1 — first boot** | `BOOTX64.EFI` = EFI-stub kernel, cmdline via `CONFIG_CMDLINE` | none (single slot) | GPT/ESP in fwup.conf; kernel EFI_STUB + NVMe/USB/KEXEC/WDT built-in; strip GRUB from defconfig/post-build; rebrand |
| **2 — kexec update** | same | warm A/B via kexec; cold boot picks committed slot | kexec-tools, UKI per slot on ESP, fwup A/B tasks, watchdog + validate/commit in Elixir |
| **3 — chooser** | `BOOTX64.EFI` = `uefi_ab_chooser` → UKI A/B | atomic cold-boot selection | build & integrate the separate chooser repo |

Phase-1 layout (GPT + ESP + kernel-on-ESP) is forward-compatible with Phases 2–3;
single-slot now costs no rework.

## Phase 1 — concrete file changes (in this repo)

- `nerves_defconfig`: remove `BR2_TARGET_GRUB2*` (BIOS/PC) bits; ensure
  `BR2_PACKAGE_HOST_DOSFSTOOLS=y`; add `kexec-tools`; keep musl.
- `linux-6.12.defconfig`: add EFI_STUB, EFI_PARTITION, NVMe, xhci/usb-storage/uas,
  KEXEC_FILE, watchdog, squashfs/vfat/ext4, efifb/simpledrm; set `CONFIG_CMDLINE`.
- `fwup.conf`: MBR→GPT; create FAT **ESP** (~100 MiB) holding the kernel as
  `/EFI/BOOT/BOOTX64.EFI`; A/B squashfs slots; ext4 app-data partition; drop MBR
  bootstrap-code / `grub.img` / grubenv machinery.
- `post-build.sh`: drop `i386-pc/boot.img` copy and grubenv creation; place the
  EFI-stub kernel onto the ESP image.
- `grub.cfg`: delete.
- `mix.exs` / `VERSION` / `README.md`: rebrand to `nerves_system_x86_64_uefi`.

## Open items / risks

- **Secure Boot** must be OFF (unsigned kernel/chooser). Signing via `shim` is a
  far-later concern.
- Watchdog selection on the N100 (iTCO vs. SoC WDT) — verify the right driver.
- kexec interrupts the running BEAM (faster reboot, not a live update).
- "Generic on any hardware" is an ongoing widening of the module set, not a
  one-shot config.
