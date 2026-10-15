# gbos-x86

Google's **Googlebook OS** (the `lapis` Android desktop build) running on an ordinary laptop: a
**Dell Latitude 5300** (Intel i5-8365U "Whiskey Lake", UHD 620, 16 GB). It boots from a USB stick or
from the internal NVMe, reaches the desktop, and runs Play Store apps.

> **Keep this repository private.** `usb/patched/` and `usb/libkm_compat.so` are modified copies of
> Google's proprietary libraries. The OS images themselves are not in the repo (they are GBs and
> Google's); you rebuild them from Google's official recovery download.

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

| Not done / limited | |
|---|---|
| Speed | Some instructions are still emulated in the kernel (see "Why it's slow") |
| Linux Terminal (AVF) | Secretkeeper hang fixed; VM boot not yet confirmed |
| Auth-bound keystore keys | `soft_gk`'s auth tokens aren't trusted by the software KeyMint |
| OS updates | Built-in OTA can't work; manual process only (see "Updating Googlebook OS") |
| Other laptops | Only the Latitude 5300 is tested. The CPU-emulation kernel should help any pre-2021 Intel CPU |

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
| Everything too big | `ro.sf.lcd_density=260` for Google's panel | `DENSITY` in `gbos.cfg` (default 180) |

Laptop-specific drivers that Google's vendor modules can't provide (they're built for Google's kernel):
battery/AC, Intel LPSS I2C (touchpad), legacy HDA audio and `btusb` are built into our kernel
(`kernel/configure_whl.py`). Wi-Fi and Bluetooth firmware are in `usb/firmware/`.

`HANDOFF.md` is the chronological engineering log: every bug, its evidence and its fix. Read it before
changing anything.

## Repository map

| Path | What |
|---|---|
| `usb/stage0_init.sh` | stage0: volume detection, logging, partition mounts, switch_root |
| `usb/hook.sh` | Android workarounds, run by stage0 before switch_root; writes `gbos.rc` (init services) |
| `usb/install.sh` | NVMe installer and updater (`MODE=install`) |
| `usb/apex_patch.sh` | binds the patched libcrypto over the APEX copies (run from init.rc) |
| `usb/gbos.cfg` | user settings: `MODE`, `DENSITY`, `LOAD_I915`, `SHELL_AT`, ... |
| `usb/audio/` | audio HAL config for the HDA card |
| `usb/out/BOOTX64.EFI` | **current kernel** (build #23), boots directly from UEFI |
| `usb/patched/`, `usb/libkm_compat.so` | patched Google libraries (private) |
| `usb/kmod/` | `btusb`, `btintel`, `btrtl` built for kernel #23 |
| `usb/installer/` | Alpine `sfdisk`/`mke2fs`/`e2fsck`/`mkfs.fat`/`blkid` + musl (`tools/fetch_installer_tools.sh`) |
| `usb/firmware/` | Intel Wi-Fi + Bluetooth firmware, `regulatory.db` |
| `usb/soft_gk`, `gatekeeper/` | software Gatekeeper binary and source |
| `usb/make_super.py`, `make_bootdisk.py`, `make_initramfs.py` | build `super.img`, the fake ChromeOS boot disk, the stage0 initramfs |
| `kernel/configure_whl.py` | kernel config for this laptop (from Google's recovery kernel config) |
| `kernel/isa_emu_patch/` | instruction emulator + `apply.sh`/`build.sh`, `debug_cmdline.txt` |
| `kernel/ashmem_shim/` | C memfd ashmem shim |
| `kernel/isa_emu_test/` | QEMU test of the emulator (16 instructions) |
| `isa-emu/` | emulator core + host known-answer tests |
| `tools/` | image extraction (`lp_extract.py`), ISA scanner (`isa_scan.py`), binary patchers |
| `lapis/` | download script, ISA scan results, QEMU userspace harness |

## Using it

### Boot from the USB stick
The stick has two partitions: **`EFI`** (FAT, `EFI/BOOT/BOOTX64.EFI`) and **`GBOS`** (FAT32: `/busybox`,
`gbos/`). The firmware boots the **EFI partition's** copy. Pick the stick with **F12** at the Dell logo.

`gbos/` holds: `super.img` + `super.layout`, `hook.sh`, `install.sh`, `apex_patch.sh`, `gbos.cfg`,
`bootdisk.img`, `crossystem`, `libkm_compat.so`, `system_ext_manifest.xml`, `soft_gk`, and the
`firmware/`, `patched/`, `audio/`, `installer/`, `kmod/` folders. Logs go to `gbos/logs/boot-N/`.

### Install to the internal NVMe
Set `MODE=install` in `gbos/gbos.cfg` and boot the stick.
- **No gbos on the NVMe:** it shows the disk's model/serial/size and **erases the whole disk** only after
  you type the serial number. Layout: `GBOS_EFI` 512M (ESP), `GBOSSYS` 8G FAT32 (the `gbos/` files),
  `GBOS_META` 64M ext4, `GBOS_DATA` rest ext4. Every copied file is sha256-verified.
- **gbos already installed:** it asks **1) Update** (keeps data, copies new files and kernel, and saves the
  install's last 3 boots of logs to the stick) or **2) Reinstall** (erase; still asks for the serial).

The installed system boots normally without the stick. With the stick plugged in and `MODE=install`,
booting the stick always goes to that menu.

### Debugging workflow
The installed system writes logs to its own `GBOSSYS` partition. To read them, boot the stick, choose
**1 (Update)**, and read `gbos/logs/boot-N/nvme-logs/` on the stick from a computer. Each boot dir has
`kmsg.log`, `stage0-dmesg.txt` (look for `hook:` lines), rotated `logcat.txt*` (oldest = highest
number), `crash.txt`, `hw.txt`, `audio.txt`, and `pstore-prev/` (the previous boot's kernel panic, if
any). FAT has no journal: shut down from Android's power menu, not the power button.

### Display size
`DENSITY=180` in `gbos.cfg` (lower = smaller). After changing it, reset Settings → Display → Display size
to Default, because a forced size overrides it.

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
   `i915_edp_colorspace.sh` (eDP always gets default colorimetry; BT.2020 made the panel pale).
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
- `install.sh` erases the **entire** NVMe on a fresh install. The serial-number prompt is the only guard.
- SELinux runs **permissive**, and the security services are software stand-ins. Don't treat this as a
  secure device.
- The ISA emulator runs in the kernel's `#UD` handler; a bug there is a kernel bug.
