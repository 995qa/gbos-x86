# gbos-x86 handoff

## Goal
Run the Googlebook `lapis` Android userspace on an i5-8365U (Whiskey Lake). That CPU lacks GFNI, AVX-VNNI,
SHA-NI, 256-bit VAES/VPCLMULQDQ, AVX-IFMA and AVX-512; the lapis binaries use them.

## Done
- `isa-emu/isa_emu_core.c`: software versions of those instructions. 13,373 known-answer checks pass.
- **Kernel emulation** (new): `kernel/isa_emu_patch/`. #UD handler in `arch/x86/kernel/traps.c` calls
  `isa_emu_handle_ud()` (`arch/x86/kernel/fpu/isa_emu.c`), which decodes the instruction, runs the core on the
  saved xsave image, and advances RIP. Covers GFNI (SSE+VEX), AVX-VNNI(-INT8), SHA-NI, VAES-256, VPCLMULQDQ-256,
  AVX-IFMA. Boot param `noisaemu` disables it. Source tree is in docker volume `gbos-ksrc`; `apply.sh` applies the
  patch, `build.sh` does the incremental build (image `gbos-kbuild`, clang r584948c).
- Kernel image: `kernel/out_isa/bzImage` (sha256 in `bzImage.sha256`; rebuilt since, so recompute). Original kernel
  is `kernel/out/bzImage`. Modules: `kernel/out/modules/6.18.21-gbos-whl+/` (110, incl. i915, iwlwifi).
- `kernel/isa_emu_test/`: freestanding test. 16/16 pass on QEMU Skylake-Client; the stock kernel SIGILLs.
- `lapis/patched/init`: init with SHA-NI routine redirected to the scalar one (optional speed-up; not needed with the
  kernel emulation). `tools/patch_init_sha.py`.
- QEMU boots of lapis userspace (`lapis/qemu/`): the real first-stage `init` runs unpatched on the emu kernel.
  `run_b.py` hand-does first stage (mounts real erofs images from `lapis/parts/`, fake dm devices) then runs
  `/system/bin/init selinux_setup`. Reached: SELinux policy loaded and enforcing, second-stage init, ueventd,
  apexd (APEXes mounted), logd, lmkd, servicemanager, BoringSSL self-tests, vold. ~15M instructions emulated,
  **zero illegal-instruction deaths**.

## Not done / unknown
- Never run on real hardware. i915/iwlwifi only checked for module load in QEMU. Firmware not packaged
  (i915 KBL DMC blob; Wi-Fi blob needs card model from `lspci -nn`).
- Boot never reached zygote/system_server. Last attempt had a stand-in `super` (extra disk copies as dm-linear
  devices) to stop vold's "could not find logical partition system_a" reboot; its full-boot result was not seen.
- No real boot chain: no bootloader/GRUB entry, boot/vendor_boot/vbmeta(AVB)/super for this laptop. Google's
  vendor modules won't load on our kernel (different build).
- AVX-512, AMX, AVX-NE-CONVERT, WAITPKG, PREFETCHI are not emulated (libjxl, openvino, cros_ml, camera,
  desktop_audio_effects). Likely gated by CPU checks, not confirmed.
- Perf: each trapped instruction is a kernel round trip. SHA-NI-heavy paths (init, apexd, prng_seeder) are slow;
  consider binary-patching them to scalar like `init`.
- `gbrunch/` has installer docs (INSTALLER.md, STANDALONE-INSTALLER.md, BUILD.md) not yet read this session.

## 2026-10-15: first real-hardware boot (Inspiron 5300), boot-15 log
- Reached system_server + SetupWizard. Graphics, keyboard and trackpad work.
- SetupWizard crash: `ashmem_create_region failed ... Unable to stat ashmem device`. In this kernel ashmem is
  Rust-only (`ASHMEM depends on RUST`) and `configure_whl.py` sets RUST=n. Fix: `kernel/ashmem_shim/`, a C port
  of `ashmem_memfd_ioctl()` (CONFIG_MEMFD_ASHMEM_SHIM) so libcutils uses memfd. Built as #17, on the stick.
  The previous EFI is saved as `usb/out/BOOTX64.EFI.prev-noashmem`.
- system_server Watchdog kill (66s in LockSettingsService waiting for IWeaver): hook.sh now hides the Weaver VINTF
  fragment.
- The kernel still has the always-on isa_emu trap profiler (prof_hit) from the QEMU perf work.
- The firmware boots the stick's separate EFI partition (disk7s1, "EFI"), NOT GBOS/EFI/BOOT. Put new kernels in
  /Volumes/EFI/EFI/BOOT/BOOTX64.EFI. Boots 16-19 ran the old #14 kernel; #17 (ashmem shim) is now on disk7s1.
- Android's vold took over the stick (fstab rule `/devices/*/usb* voldmanaged=usb`) and ran fsck_msdos on it
  while it was mounted, so logs were cut off, LOST.DIR appeared and standalone product_a.img got corrupted.
  hook.sh now removes that rule. logcat rotates at 1 MB; crash.txt holds the crash buffer.
- boot-19 crash loops: SetupWizard shared Bitmap (old kernel), Bluetooth HAL abort (no BT HAL),
  mmd_setup zram (hook now runs modprobe zram).
- boot-20 (#17 kernel): still "Failed to create shared Bitmap!". libcutils use_memfd() only picks memfd when
  sys.use_memfd=true, or memfd_class policycap + ro.vendor.api_level >= 202604 + app targetSdk >= 37.
  SetupWizard targets older SDK, so it goes to /dev/ashmem. hook.sh's gbos.rc now sets sys.use_memfd true.
  ANRs in gms / settings.intelligence in the same boot also showed ashmem failures (CursorWindow).
- boot-21: SetupWizard screen reached on the Inspiron 5300 (sys.use_memfd + ashmem shim).
- Panic at boot-21/22 ("Fatal exception in interrupt", pstore in boot-22/pstore-prev): isa_emu_handle_ud() ran
  with IRQs off but can sleep (mmap lock, kmalloc, d_path in the profiler, copy_from_user). After a sleep it
  returned to user with IF=1; an IPI between swapgs and iret ran with user GS and recursed into a stack overflow.
  Fix: handle_invalid_op enables IRQs around the emulator (kernel/isa_emu_patch/traps_irq.sed, in apply.sh).
  Built #18, 16/16 QEMU tests pass, on both EFI copies. #17 kept as usb/out/BOOTX64.EFI.prev-17.
- Speed: profiler shows libz.so adler32 (vpdpwssd, 50%), conscrypt APEX libcrypto SHA-256 (40%),
  system libcrypto SHA-256 (10%). libz: the je at adler32_z+0xb5 (0xa7d5) gates the SIMD path.
- Wi-Fi: card is CNVi 8086:9df0 (9560/9462). gbos/firmware/ has iwlwifi-9000-pu-b0-jf-b0-46.ucode (linux-firmware intel/iwlwifi/, sha256 9a0c5d93...) + regulatory.db; hook.sh loads iwlmvm (LOAD_WIFI stays 0).
- boot-24: signed into Google, Wi-Fi works. Setting a lock password hung: Trusty Gatekeeper enroll never returns (LSS stuck after 'Device does not support weaver'). hook.sh hides Trusty Gatekeeper (VINTF + rc) so Skip works; no lock-screen password until a software Gatekeeper exists. libz patch deployed to gbos/patched.
- boot-25: Setup lock step loops (Settings SetupChooseLockGeneric returns RESULT_CANCELED to Skip -> back to avatar).
- Software Gatekeeper: gatekeeper/soft_gk.c (no NDK; gatekeeper/build.sh in gbos-kbuild, links image libs in
  gatekeeper/libs). AIDL V1 wire format taken from android.hardware.gatekeeper-V1-ndk.so (codes 1-4, 0xffffff,
  0xfffffe). HMAC-SHA256 password handle (58-byte password_handle_t). Auth-token MAC uses its own key, so
  KeyMint won't accept its tokens (auth-bound keys won't work). Installed as gbos/soft_gk + gbos_soft_gk service
  (hal_gatekeeper_default); Trusty gatekeeper rc disabled. Not yet run on hardware.
- boot-26: reached the desktop with soft_gk; user reports it's smooth. Committed as 03a6a46 (new git repo, images/binaries gitignored).
- Laptop is a Dell Latitude 5300 (DMI), not an Inspiron. Kernel #20 adds ACPI battery/AC, Intel LPSS PCI
  (I2C touchpad was stuck on its PS/2 fallback), and legacy HDA audio (snd_hda_intel + ALC269 + HDMI,
  snd_intel_dspcfg.dsp_driver=1). Google's vendor modules for these never loaded (wrong kernel).
  usb/audio/: gbos-hda-pch config for the dras audio HAL (audio_default.xml -> card "HDA Intel PCH").
- NVMe installer: usb/install.sh (MODE=install in gbos.cfg), tools in usb/installer (Alpine sfdisk/mke2fs/
  mkfs.fat + musl). Layout: GBOS_EFI 512M, GBOSSYS 8G FAT32, GBOS_META 64M ext4, GBOS_DATA rest ext4.
  stage0 boots GBOSSYS when no stick (or stick lacks MODE=install/BOOT_FROM=stick) and mounts ext4 data.
  QEMU: cancel path tested (wrong serial -> nothing written). Full install and NVMe boot NOT tested (user
  chose to go straight to hardware; burner laptop). Stick has #20 + MODE=install.
- 2026-10-15: installed to the Latitude 5300's NVMe and boots from it. User reports everything works except
  sound (touchpad gestures, battery, Wi-Fi OK). Sound not investigated (user deprioritised): no logs taken.
  Next step if revisited: boot the stick with MODE=boot + BOOT_FROM=stick and dump /proc/asound, the codec
  info, tinymix and dras logcat. Suspects: dras card-name match ("HDA Intel PCH"), mixer control names,
  or the DSP still claiming the controller.
- The stick still has MODE=install; booting with it plugged in starts the installer (it asks for the serial).
- Bluetooth: our config had BT_HCIBTUSB unset (Google's chip is PCIe). Built btusb/btintel/btrtl as modules
  (usb/kmod, loaded by hook.sh) + linux-firmware intel/ibt-17-16-1.sfi/.ddc in gbos/firmware/intel. Untested.
- install.sh: if an install exists, it asks 1) update (keep data, save NVMe logs to stick) / 2) reinstall.
  A full reinstall first saves the old install's logs to the stick. ACTION=update|install in gbos.cfg skips
  the question. A stick left in MODE=install once reinstalled over the user's working system (they aborted
  it midway, NVMe corrupt -> full reinstall); Play-install-stuck-at-100% logs were lost with it.
- Sound: kernel side works (ALC3254 found). dras loaded our config but never matched "HDA Intel PCH":
  it compares <soundcard> to the ALSA card id (sof-soundwire -> id sofsoundwire). Now <soundcard>PCH</soundcard>.
- Play installs: not broken, slow. PP-Copy (SHA-256 via Conscrypt) took ~5 min for Spotify's 33 MB apk.
  With the libcrypto patches deployed, Spotify installs (user confirmed).
- Linux Terminal: Debian download+unpack took ~11 min. Then virtualizationservice.allocateInstanceId waited
  56 s for ISecretkeeper/default (Trusty). hook.sh now hides Secretkeeper (VINTF + rc).
- boot-3 (NVMe, collected in stick boot-34): dras now finds card PCH but rejected audio_config.xml:
  "missing field JackSwitch" (fields inside a section are required, sections are optional, cf. USB configs).
  Config now mirrors sof-soundwire field for field; jack is "HDA Intel PCH Headphone Mic" (combo).
  Codec has an internal mic on pin 0x12, so InternalMic is configured on PCM 0.
- Bluetooth: btintel loads firmware at probe (pre-switch_root) but the path was already /postinstall:
  "Failed to load Intel firmware file intel/ibt-17-16-1.sfi (-2)". hook now points at $G/firmware while
  btusb probes and waits for "Firmware loaded".
- audiodiag stdio_to_kmsg output was lost; now writes logs/boot-N/audio.txt.
- Display: Google sets ro.sf.lcd_density=260; hook now replaces it with DENSITY from gbos.cfg (default 180). Update path syncs gbos.cfg (minus MODE/ACTION) to the NVMe. A 'Display size' set in Settings is stored as a forced density and overrides this; reset it to Default.
