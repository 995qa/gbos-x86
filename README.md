# gbos-x86 (gbOS86)

<p align="center"><img src="docs/demo.gif" alt="gbOS86 running on a Dell Latitude 5300" height="420">&nbsp;&nbsp;<img src="docs/screenshot-dell-latitude-5300.jpg" alt="Googlebook OS on a Dell Latitude 5300" height="420"></p>
<p align="center"><b>Googlebook OS on a Dell Latitude 5300.</b> Full 43 s demo: <a href="https://gbos86.com/static/demo.mp4">gbos86.com/static/demo.mp4</a></p>

Google's **Googlebook OS** (the `lapis` Android desktop build) running on an ordinary laptop: a
**Dell Latitude 5300** (Intel i5-8365U "Whiskey Lake", UHD 620, 16 GB). It boots from a USB stick or
from the internal NVMe, reaches the desktop, and runs Play Store apps.

**Website and community:** https://gbos86.com (guides, hardware list, forum) | Discord: https://discord.gg/h9AD9fSnDT

> `usb/patched/` and `usb/libkm_compat.so` are modified copies of Google's proprietary libraries, included
> because the build needs them; Google's terms apply to them. The OS images themselves are not in the repo (they are
> GBs and Google's); you rebuild them from Google's official recovery download. gbOS86 is an independent project, not
> affiliated with or endorsed by Google.

## Try it: build and flash in 3 steps

You need macOS or Linux with **docker** (running), **python3**, curl and about **35 GB** of free disk. Nothing from Google is
stored in this repository: the script downloads Google's public recovery image itself.

```sh
git clone https://github.com/linuxkid473/gbos-x86 && cd gbos-x86
./build.sh                      # asks before downloading; writes dist/gbOS86-YYYYMMDD.img (6.7 GB)
# flash it: balenaEtcher / Rufus, or  sudo dd if=dist/gbOS86-*.img of=/dev/rdiskN bs=4m
```
Then boot the laptop from the stick (F12), turn Secure Boot off, and choose **1** (live, nothing is written to the laptop).
`./build.sh --dry-run` shows what it would download (Google's 7.7 GB image, ~1 MB busybox, 14 MB of kernel modules and 53 MB of firmware
from this repo's [release](https://github.com/linuxkid473/gbos-x86/releases)). It streams only the six partitions it needs out of
Google's zip, so the 19 GB disk image inside is never unpacked. Allow 30 to 60 minutes, mostly the download. Nine machines have been
tried (see [Tested laptops](#tested-laptops)); if you try another, please post its `gbos/logs/boot-N/hwdetect.txt` in an issue.
Fedora/RHEL with SELinux enforcing: the scripts add `:z` to the docker bind mounts of this repo's own folders automatically; don't disable SELinux.

## Status

| Works | Notes |
|---|---|
| Boot to desktop, setup, Google sign-in | From USB or NVMe |
| Persistent data | NVMe install: `/data` and `/metadata` are ext4 partitions |
| Wi-Fi | Intel 9560 (CNVi `8086:9df0`) + linux-firmware |
| Bluetooth | Intel 9560 USB (`8087:0aaa`) via our `btusb` |
| Sound | Legacy HDA + Realtek ALC3254, speakers, headset jack, internal mic, HDMI |
| Touchpad with scrolling/gestures, keyboard | Intel LPSS I2C HID |
| Battery / AC | ACPI battery |
| Play Store installs | With the patched libcrypto (SHA-256 no longer emulated) |
| Screen-lock password | Software Gatekeeper (`gatekeeper/soft_gk.c`) |
| Correct display colours / black levels | Kernel #29: i915 ignores the HWC's gamma tables (see below) |

| Not done / limited | |
|---|---|
| Speed | Some instructions are still emulated in the kernel (see "Why it's slow") |
| Night Light | Gamma tables from userspace are ignored (that's the colour fix), so it has no effect |
| Linux Terminal (AVF) | Secretkeeper hang fixed; VM boot not yet confirmed |
| Auth-bound keystore keys | `soft_gk`'s auth tokens aren't trusted by the software KeyMint |
| Google's on-device AI (Magic Pointer, AICore) | Google's servers refuse it without hardware key attestation, which no non-Google laptop can provide. Optional replacement, chosen in the installer: the AI features answer through an OpenAI-compatible API **you** provide (address, key, model; a Gemini API key works). Text and pictures you point at go to that provider; see [`localai/README.md`](localai/README.md) (**experimental, not yet confirmed on hardware**) |
| OS updates | Built-in OTA can't work; manual process only (see "Updating Googlebook OS") |
| Other laptops | Four of nine tried machines work fully, four partly or pending, one not; see [Tested laptops](#tested-laptops). The CPU-emulation kernel should help any pre-2021 Intel CPU |

## How it works

```
UEFI firmware
 └─ EFI/BOOT/BOOTX64.EFI      our kernel (android17-6.18 + patches) with stage0 built in as initramfs
     └─ stage0 (usb/stage0_init.sh, busybox)
         ├─ finds the gbos volume: USB stick (FAT label GBOS) or NVMe install (GBOSSYS)
         ├─ loads i915, logs to gbos/logs/boot-N/
         ├─ MODE=install → gbos/install.sh (NVMe installer/updater), never boots Android
         ├─ mounts super.img's erofs partitions (system, vendor, product, ...) via loop + dm-linear
         ├─ runs gbos/hook.sh (all Android-side workarounds, editable without a kernel rebuild)
         ├─ mounts /data, /metadata (NVMe ext4, else tmpfs)
         └─ switch_root → /system/bin/init selinux_setup   (Google's Android init, unmodified)
```

**The core problem:** lapis binaries use CPU instructions this CPU lacks: GFNI, AVX-VNNI, SHA-NI,
256-bit VAES/VPCLMULQDQ, AVX-IFMA. Two layers deal with that:

1. **Kernel emulation** (`kernel/isa_emu_patch/`). The `#UD` (invalid opcode) handler decodes the
   instruction, emulates it on the saved FPU state (`isa_emu_core.c`, 13k known-answer tests), and
   continues. It is correct but slow, about a microsecond per instruction.
2. **Binary patches** for the hottest code (`usb/patched/`, bind-mounted by `hook.sh`, and only
   applied when the original's sha256 matches):
   - `libz.so`: `adler32_z` always takes its scalar path (was ~50% of all emulation).
   - `libcrypto.so` ×3 (system, vendor, Conscrypt APEX): SHA-NI SHA-256 → scalar SHA-256 (was ~50%).

   **When they are bound.** `usb/early_patch.sh` (sourced from `gbos.cfg`) wraps `chroot` in stage0 and binds the
   system/vendor `libz` + `libcrypto` just before the first `dmctl` call. Without it, every `dmctl` process
   (one per partition) loads libcrypto and runs BoringSSL's load-time module hash through SHA-NI, about 3.7M
   emulated instructions, ~2 s of boot, before `hook.sh` could bind anything. `hook.sh` still does the same binds
   later as a fail-safe and logs `already patched (early_patch.sh)` when the early pass got there first. Both
   are gated on the sha256 of the exact original, so a new Google build silently disables them
   (`NOT patched` in `stage0-dmesg.txt`).
   *To verify on hardware:* `stage0-dmesg.txt` must show `early: patched system libcrypto` before
   `running gbos/hook.sh`.
   *Shipping:* `early_patch.sh` is in `install.sh`'s `FILES` (so **1 Update** copies it to the NVMe) and in the
   image builder. The `gbos.cfg` source line is guarded by `[ -f ... ]`, so a stick without the file still boots.

**Google hardware the laptop doesn't have**, mostly the GSC security chip and the pKVM Trusty VM:
`hook.sh` hides or replaces each service that would otherwise hang the boot:

| Symptom | Cause | Fix (in `usb/hook.sh` unless noted) |
|---|---|---|
| "System process not responding" | LockSettings waits forever for Weaver (Trusty) | hide Weaver's VINTF declaration |
| Setup crashes ("Failed to create shared Bitmap") | no `/dev/ashmem` (Rust ashmem driver, `RUST=n`) | `kernel/ashmem_shim/` (C memfd ashmem ioctls) + `sys.use_memfd=true` |
| Setting a password hangs Settings | Trusty Gatekeeper never answers | `gatekeeper/soft_gk.c` software Gatekeeper |
| keystore2 aborts / KeyMint hangs | Trusty/StrongBox KeyMint need the GSC | patched `libkm_compat.so` (software KeyMint), StrongBox APEX hidden |
| Linux Terminal never starts its VM | Trusty Secretkeeper never answers | hide Secretkeeper's VINTF declaration |
| Logs truncated, stick corrupted | vold `fsck_msdos`'d the stick while mounted | remove vold's `voldmanaged=usb` fstab rule |
| No sound | Google uses SOF; our kernel has legacy HDA | `usb/audio/` config for the `dras` audio HAL (card id `PCH`) |
| White veil, lifted blacks (even video) | drm_hwcomposer loads its xe `LOG_GAMMA_LUT` curve into i915's linear `GAMMA_LUT` every frame | `kernel/isa_emu_patch/i915_ignore_gamma.sh` (kernel #29) |
| Everything too big | `ro.sf.lcd_density=260` for Google's panel | `RESOLUTION` in `gbos.cfg` (default 2400x1350, stock density); `DENSITY` optional |

Laptop-specific drivers that Google's vendor modules can't provide (they're built for Google's kernel):
battery/AC, Intel LPSS I2C (touchpad), legacy HDA audio and `btusb` are built into our kernel
(`kernel/configure_whl.py`). Wi-Fi and Bluetooth firmware are in `usb/firmware/`.

`HANDOFF.md` is the chronological engineering log: every bug, its evidence and its fix. Read it before
changing anything.

## Tested laptops

Reports from people who booted the stick (2026-10-17). A row says what was reported, not what the newest build can do. The same list is on
[gbos86.com/hardware](https://gbos86.com/hardware); the source of truth is [`website/laptops.py`](website/laptops.py).

| Laptop | CPU | Result | Works | Does not work / notes |
|---|---|---|---|---|
| Dell Latitude 5300 | Core i5-8365U, 16 GB | **Works** | Everything tested: Wi-Fi, Bluetooth, sound, touchpad, brightness, battery, install | Suspend. The maintainer's machine |
| Acer Aspire Lite AL15-52 | Core i5-1235U, 8 GB | **Works** | Wi-Fi, display, touchpad, keyboard, sound, brightness, camera, Bluetooth | Needed two firmware fixes (Realtek Wi-Fi; Intel AX201 Bluetooth name `ibt-0040-1050.sfi`), both in firmware v34+. Older sticks need a rebuild or an Update from a fresh stick |
| Lenovo ThinkPad T470 | Intel 7th gen | **Works** | Reported as working with no setup | Short report |
| Intel NUC8BEH (mini PC) | Core i3-8109U, 8 GB | **Works** (live) | Wi-Fi, Bluetooth, display and brightness (external monitor), keyboard (external), USB ports | Sound not tested. SATA M.2 SSD: install support for SATA disks added afterwards (QEMU-tested only, not yet tried on this NUC) |
| HP OmniBook 7 | Core Ultra 5 225U, 16 GB | Partly | Touchpad, keyboard, brightness, display | Wi-Fi (Intel BE201). Sound, webcam, Bluetooth not tested |
| Dell XPS 16 (2026) | Intel Core Ultra | Partly | Boots and runs | Screen refresh rate, Wi-Fi, camera. A kernel option reportedly fixes the screen: try it with `MODOPTS` in `gbos.cfg` |
| Framework Laptop 13 Pro | Core Ultra 5 325 (Panther Lake), 16 GB | Fix pending | Boots | Black screen on sticks without the Panther Lake `xe` firmware (GuC); firmware v35 has it. Awaiting confirmation |
| Microsoft Surface Laptop 7 (Intel) | Core Ultra 7 266V (Lunar Lake), 16 GB | Fix pending | Boots | Black screen on sticks without the Lunar Lake `xe` firmware (GuC); firmware v35 has it. Built-in keyboard not detected; Wi-Fi, sound unknown. Awaiting logs |
| HP 14-ne0013dx | Intel | Does not work | | No logs yet |

Pattern: 2017 to 2022 business and mainstream laptops work with little setup; newer Core Ultra machines boot but hit missing firmware (`xe`)
or Wi-Fi 7 cards without a working driver and firmware pair. Missing firmware is listed in `hwdetect.txt` under "missing firmware".
To try a driver option on your own laptop, put e.g. `MODOPTS="xe.enable_panel_replay=0"` in `gbos/gbos.cfg` (modules only; see the file's comments).

## Other laptops (generic Intel gen 6+ support)

The kernel (#31) builds drivers for most Intel-era laptops as **modules**, and boot detects what is present:

1. `usb/hwdetect.sh` (called by `hook.sh`) bind-mounts the stick's full module tree (`gbos/modules/`, depmod'ed for
   the running kernel) over `/lib/modules`, then does a udev-style *coldplug*: it reads every device's sysfs `modalias`
   and `modprobe -a`'s them, repeating until no new module loads (a loaded driver creates new devices).
2. The kernel's firmware loader is pointed at `gbos/firmware` (a trimmed linux-firmware + sof-bin, ~300 MB).
3. `logs/boot-N/hwdetect.txt` records DMI vendor/model, PCI/USB devices **without a driver**, input devices, network and
   Bluetooth interfaces, backlight, sound cards, rfkill, missing-firmware messages and `lsmod`. Send it back when
   something doesn't work.

| Area | Covered |
|---|---|
| CPU | Anything the ISA-emulation kernel handles: 6th gen (Skylake) and newer; the Googlebook OS needs instructions older CPUs lack, so it is emulated (slow on pre-2021 CPUs) |
| Graphics / display / brightness | `i915` (Gen9 to Raptor Lake) + ACPI video/backlight; `xe` for newer parts (needs its own firmware, in firmware release v35; the colour/gamma fixes are i915-only) |
| Wi-Fi | Intel (`iwldvm`: 7260/7265, `iwlmvm`: 8265 to AX211/BE200), Realtek rtw88/rtw89, MediaTek mt7921/7922/7925, Qualcomm ath10k/ath11k, Broadcom brcmfmac |
| Bluetooth | `btusb` with Intel/Realtek/MediaTek/Qualcomm/Broadcom, Intel PCIe BT |
| Sound | Legacy HDA with every common codec, **or** SOF (Intel DSP, DMIC, SoundWire); the kernel picks per machine (`snd_intel_dspcfg`). The audio HAL config is generated for the card that appears (`hook.sh`) |
| Touchpad / keyboard | Intel LPSS I2C-HID, ISH, PS/2 (Synaptics, ALPS, Elan, ...), Synaptics RMI4 |
| Hotkeys, fans, rfkill | Dell, HP, ThinkPad, IdeaPad, Asus, Acer, Samsung, MSI, Sony, Fujitsu, LG, Intel HID/VBTN |
| Other | SD card readers (Realtek, SDHCI), USB webcams (UVC), Ethernet (r8169, e1000e, igc, USB r8152 and friends) |

**Honest limits.** Nine machines have been booted (below); anything not on that list is built and wired but untested on
hardware. Sound on SOF machines needs the codec's mixer controls to match the generated config (best effort);
suspend/resume, fingerprint readers, IPU6 cameras and NVIDIA/AMD dGPUs are not covered. Build the payload with
`tools/fetch_firmware.sh` (firmware, not committed) and `kernel/isa_emu_patch/build_generic*.sh` (modules, not committed).

## Repository map

| Path | What |
|---|---|
| `usb/stage0_init.sh` | stage0: volume detection, logging, partition mounts, switch_root |
| `usb/hook.sh` | Android workarounds, run by stage0 before switch_root; writes `gbos.rc` (init services) |
| `usb/early_patch.sh` | Sourced from `gbos.cfg`; binds the patched libz/libcrypto before stage0's first `dmctl` |
| `usb/install.sh` | NVMe/eMMC/SATA installer and updater (`MODE=install`) |
| `usb/apex_patch.sh` | binds the patched libcrypto over the APEX copies (run from init.rc) |
| `usb/gbos.cfg` | user settings: `MODE` (ask/live/install/boot), `DENSITY`, `RESOLUTION`, `LOAD_I915`, ... |
| `tools/make_gbos86_image.sh` | builds the flashable gbOS86 USB image into `dist/` |
| `usb/audio/` | audio HAL config for the HDA card |
| `usb/out/BOOTX64.EFI` | **current kernel** (build #30: #29 + gbOS86 boot menu), boots directly from UEFI |
| `usb/patched/`, `usb/libkm_compat.so` | patched Google libraries |
| `usb/kmod/` | `btusb`, `btintel`, `btrtl` built for kernel #29 |
| `usb/installer/` | Alpine `sfdisk`/`mke2fs`/`e2fsck`/`mkfs.fat`/`blkid` + musl (`tools/fetch_installer_tools.sh`) |
| `usb/firmware/` | Intel Wi-Fi + Bluetooth firmware, `regulatory.db` |
| `usb/soft_gk`, `gatekeeper/` | software Gatekeeper binary and source |
| `usb/make_super.py`, `make_bootdisk.py`, `make_initramfs.py` | build `super.img`, the fake ChromeOS boot disk, the stage0 initramfs |
| `kernel/configure_whl.py` | kernel config for this laptop (from Google's recovery kernel config) |
| `kernel/isa_emu_patch/` | instruction emulator + `apply.sh`/`build.sh`, `debug_cmdline.txt` |
| `kernel/ashmem_shim/` | C memfd ashmem shim |
| `kernel/isa_emu_test/` | QEMU tests: the emulator (16 instructions), hwdetect, `run_installer_emmc.py` (installer on an emulated eMMC) and `run_installer_sata.py` (on emulated SATA disks) |
| `isa-emu/` | emulator core + host known-answer tests |
| `tools/` | image extraction (`lp_extract.py`), ISA scanner (`isa_scan.py`), binary patchers |
| `lapis/` | download script, ISA scan results, QEMU userspace harness |

## Using it

### gbOS86 USB image (live + installer)
`tools/make_gbos86_image.sh` builds `dist/gbOS86-YYYYMMDD.img` (~6.3 GiB) from the repo plus Google's
extracted partitions (`lapis/parts/*_a.img`). Write it to an 8 GB+ stick with balenaEtcher, Rufus or `dd`.
Booting it shows the **gbOS86 menu** (10 s timeout): **1** live from the USB (nothing saved), **2** install
or update on the internal SSD, **3** boot the installed system (offered, and the default, when one exists).
`MODE` in `gbos/gbos.cfg` skips the menu (`live`, `install`, `boot`; `ask` = menu). The image holds Google's
OS and patched Google libraries: for your own use only.

### Boot from the USB stick
The stick has two partitions: **`EFI`** (FAT, `EFI/BOOT/BOOTX64.EFI`) and **`GBOS`** (FAT32: `/busybox`,
`gbos/`). The firmware boots the **EFI partition's** copy. Pick the stick with **F12** at the Dell logo.

`gbos/` holds: `super.img` + `super.layout`, `hook.sh`, `install.sh`, `apex_patch.sh`, `gbos.cfg`,
`bootdisk.img`, `crossystem`, `libkm_compat.so`, `system_ext_manifest.xml`, `soft_gk`, and the
`firmware/`, `patched/`, `audio/`, `installer/`, `kmod/` folders. Logs go to `gbos/logs/boot-N/`.

### Install to the internal disk (NVMe, eMMC or SATA)
Set `MODE=install` in `gbos/gbos.cfg` and boot the stick. The target is the internal NVMe or **eMMC** disk (an eMMC is
recognised by its MMC device type: SD cards, card readers and the stick are never targets; the eMMC's boot/RPMB areas are left
alone). With more than one internal disk the installer refuses until `INSTALL_DISK=nvme0n1` (or `mmcblk0`) is set in `gbos.cfg`.
A **SATA disk** (M.2 SATA or 2.5") is a target when the machine has no NVMe/eMMC: it is recognised by being owned by the SATA driver (libata), so a USB stick, a USB-SATA
adapter or a card reader is never a target. A laptop with an NVMe *and* a SATA disk keeps installing to the NVMe; to use the SATA disk set `INSTALL_DISK=sda` in `gbos.cfg`.
The BIOS must show the disk in **AHCI** mode (not Intel RST/RAID or VMD), otherwise Linux cannot see it. The serial to type is the drive's own serial.
Minimum disk size 24 GB. eMMC controllers on the PCI bus work (`sdhci-pci`); ACPI-only ones (some AMD and older Atom parts) are not supported.
- **No gbos on the disk:** it shows the disk's model/serial/size and **erases the whole disk** only after
  you type the serial number (eMMC: the MMC serial, or its CID when that is empty or zero; SATA: the drive's serial). Layout: `GBOS_EFI` 512M (ESP), `GBOSSYS` 8G FAT32 (the `gbos/` files),
  `GBOS_META` 64M ext4, `GBOS_DATA` rest ext4. Every copied file is sha256-verified.
- **gbos already installed:** it asks **1) Update** (keeps data, copies new files and kernel, and saves the
  install's last 3 boots of logs to the stick), **2) Reinstall** (erase; still asks for the serial) or
  **3) Only save its logs** (read-only on the NVMe, takes seconds; `LOG_BOOTS=N` in `gbos.cfg` = how many boots).

The installed system boots normally without the stick. With the stick plugged in and `MODE=install`,
booting the stick always goes to that menu.

### Debugging workflow
The installed system writes logs to its own `GBOSSYS` partition. To read them, boot the stick, choose
menu **2**, then **3 (Only save its logs)** (or 1 to update too), and read `gbos/logs/boot-N/nvme-logs/` on the stick from a computer. Each boot dir has
`kmsg.log`, `stage0-dmesg.txt` (look for `hook:` lines), rotated `logcat.txt*` (oldest = highest
number), `crash.txt`, `hw.txt`, `audio.txt`, and `pstore-prev/` (the previous boot's kernel panic, if
any). FAT has no journal: shut down from Android's power menu, not the power button.

### Display size
Density stays Google's stock 260. `RESOLUTION=2400x1350` in `gbos.cfg` makes Android render at a larger
logical size that the display scales to the 1920x1080 panel: bigger = smaller UI (empty = native).
`DENSITY=` can still override the density but is unset by default. If you changed Settings → Display →
Display size, reset it to Default.

## Building from scratch

Needs macOS or Linux with docker, python3, qemu (for tests) and ~30 GB free. The build images used:
`gbos-kbuild` (`kernel/docker/Dockerfile`) and `gbos-erofs` (`tools/erofs-docker/Dockerfile`).

1. **Google's OS image:** `lapis/dl.sh` downloads `lapis-user/16452207/recovery.zip` from
   `dl.google.com`. Extract the recovery disk image from it, then pull the logical partitions (system,
   vendor, product, system_ext, system_dlkm, vendor_dlkm; slot `_a`) out of `super` with
   `tools/lp_extract.py DISK.raw lapis/parts NAME...` (run it with just `DISK.raw` to list the names).
2. **`super.img`:** `usb/make_super.py OUT/super.img OUT/super.layout system_a=... vendor_a=...`
   (system_a first). It must stay under 4 GB (FAT32).
3. **Kernel source:** AOSP `kernel/common`, branch `android17-6.18`, commit
   `3938c8d97142d5cf31543aa96f864a2cf832dda0`, and AOSP prebuilt `clang-r584948c`. Both were fetched into
   the docker volume `gbos-ksrc` (`/build/{src,inputs,out}`) by `gbrunch/tools/prepare_amd_build_inputs.py`.
4. **Config:** `kernel/configure_whl.py RECOVERY_KERNEL.config /build/out/.config`, then `make olddefconfig`;
   set `CONFIG_CMDLINE` from `kernel/isa_emu_patch/debug_cmdline.txt` (`debug_config.sh`) and
   `CONFIG_INITRAMFS_SOURCE=/build/out/gbos_stage0.cpio`.
5. **Patches:** in the volume, `kernel/isa_emu_patch/apply.sh`, `kernel/ashmem_shim/apply.sh`, and the i915
   scripts `kernel/isa_emu_patch/i915_color_pipeline.sh` (dummy plane COLOR_PIPELINE for the HWC) and
   `i915_edp_colorspace.sh` (eDP always gets default colorimetry; BT.2020 made the panel pale) and
   `i915_edp_no_colorspace.sh` (no Colorspace property on eDP at all, from kernel #25) and
   `i915_edp_full_range.sh` (eDP always full-range RGB, from kernel #27) and `i915_ignore_gamma.sh`
   (ignore userspace gamma/degamma/CTM: the HWC loads an xe LOG_GAMMA_LUT curve into GAMMA_LUT, kernel #29).
6. **Build:** `kernel/isa_emu_patch/build.sh` (in `gbos-kbuild`), then `make modules_install` into
   `usb/modroot`, then `usb/make_initramfs.py usb/modroot usb/stage0.cpio`, copy it to
   `/build/out/gbos_stage0.cpio`, and build again so it's embedded. `arch/x86/boot/bzImage` is
   `BOOTX64.EFI`. `btusb.ko`/`btintel.ko`/`btrtl.ko` from `/build/out/drivers/bluetooth/` go in `usb/kmod/`.
7. **Test the emulator:** `kernel/isa_emu_test/run_qemu.py BOOTX64.EFI` (expects 16/16 PASS).
8. **Userspace pieces:** `tools/fetch_installer_tools.sh`; `gatekeeper/build.sh` (needs `gatekeeper/libs/`
   from the image: `libc`, `libdl` from the runtime APEX, `libbinder_ndk`, `libcrypto`, `liblog`);
   patched libraries with `tools/patch_libz_adler.py` and `tools/sha_redirect.py`. The hashes in
   `hook.sh`/`apex_patch.sh` pin the exact originals they apply to.
9. **Firmware:** from linux-firmware (`intel/iwlwifi/iwlwifi-9000-pu-b0-jf-b0-46.ucode`,
   `intel/ibt-17-16-1.{sfi,ddc}`); `regulatory.db*` from the vendor image.

## Updating Googlebook OS
Android's built-in updater can't work here (it expects Google's A/B partitions and kernel). To move to a
newer lapis build:
1. download the new recovery image, re-extract, rebuild `super.img`;
2. `tools/isa_scan.py` it for instructions the emulator doesn't cover (AVX-512, AMX, ...);
3. re-check every hash-pinned patch in `hook.sh` (`libz`, `libcrypto`, `libkm_compat`): a new build has new
   files, so patches silently stop applying until regenerated, and renamed vendor files stop being hidden;
4. copy to the stick and run **1 (Update)**. Data carries over; going back to an older build requires a
   data wipe.

## Safety
- `install.sh` erases the **entire** internal disk (NVMe, eMMC or SATA) on a fresh install. The serial-number prompt is the only guard.
- SELinux runs **permissive**, and the security services are software stand-ins. Don't treat this as a
  secure device.
- The ISA emulator runs in the kernel's `#UD` handler; a bug there is a kernel bug.
