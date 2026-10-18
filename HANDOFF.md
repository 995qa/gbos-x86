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
- 2026-10-15: user confirms sound and Bluetooth work on the NVMe install (after 445b5ce). Density change (DENSITY=180) deployed to the stick.
- Display looks washed out (grey blacks even in dark UIs). Added gbos_displaydiag -> logs/boot-N/display.txt (DRM state, i915 info, EDID, SurfaceFlinger, colour settings). Suspect limited RGB range or a colour matrix.
- Pale display: panel is an LG LP133WF6 (8-bit, ~105% sRGB area per EDID), so not the hardware. SurfaceFlinger
  outputs sRGB with an identity matrix, but drm_hwcomposer set eDP-1 colorspace=BT2020_RGB, so i915 sent a VSC SDP
  with BT.2020 colorimetry and the panel gamut-mapped it (pale). kernel/isa_emu_patch/i915_edp_colorspace.sh:
  eDP always uses default colorimetry (property kept). Kernel #23 (16/16 QEMU), on the stick; #20 kept as
  usb/out/BOOTX64.EFI.prev-20.
- User wanted stock density back (believes it caused the paleness). DENSITY now optional (unset = stock 260); new RESOLUTION=2400x1350 -> 'wm size' at boot_completed (gbos_wmsize) scales the UI without changing density.
- User reverted to DENSITY=180, RESOLUTION empty (native).
- hook: vendor build.prop now sets ro.surface_flinger.has_wide_color_display=false and has_HDR_display=false (were true), so SF offers only sRGB and the HWC has no reason to tag eDP BT.2020. Complements kernel #23.
- User reports #23 + sRGB-only props did not fix the paleness. Kernel #25 (i915_edp_no_colorspace.sh): no Colorspace property on eDP at all. 16/16 QEMU. On the stick in TEST mode (MODE=boot, BOOT_FROM=stick: stick's own system, tmpfs data); NVMe still has #23. #23 kept as usb/out/BOOTX64.EFI.prev-23. Note: no logs yet confirm #23/sRGB were active on the boot the user judged.
- Test boot (stick, boot-42) on #25: user confirms colors are good. Stick switched back to MODE=install for the NVMe update.
- Correction: after updating the NVMe to #25, colours in the fully booted desktop look no different (good-looking was the setup screens only). Paleness unresolved but deprioritised by the user. #25 + sRGB-only props kept (harmless). Next idea if revisited: Material You theme/wallpaper (muted palette) vs panel; compare a display.txt from a full boot on #25.
- User: video/UI still has a 'white veil' (lifted blacks) and says the panel looks right under Windows/Linux/BSD. Kernel #27 (i915_edp_full_range.sh): eDP always full-range RGB. hook: drm.debug=0x04 until boot_completed, so kmsg.log has i915's per-modeset gamma/CSC/range dump. #25 kept as usb/out/BOOTX64.EFI.prev-25. On the stick (MODE=install -> pick 1).
- Timeline correction: the "still veil" verdict was on NVMe boot-12 = kernel #25; #27 was only installed at stick
  boot-45 and never tested. boot-12 diag: eDP colorspace Default, SF wide colour 0, SRGB, identity CTM, so the
  colour-space fixes worked and weren't the cause.
- REAL CAUSE (likely): logcat "drmhwc: Missing optional LOG_GAMMA_LUT property, falling back to GAMMA_LUT" x32523,
  i.e. the HWC writes its xe log-gamma curve into i915's linear GAMMA_LUT every commit, lifting the shadows.
  Kernel #29 (i915_ignore_gamma.sh): hw degamma/gamma/CTM always NULL (linear). Includes #25/#27 changes.
  On the stick (MODE=install -> 1). #27 kept as usb/out/BOOTX64.EFI.prev-27. Cost: Night Light won't work.
- 2026-10-15 CONFIRMED by the user on kernel #29: the white veil / pale colours are gone. Cause: drm_hwcomposer's
  LOG_GAMMA_LUT -> GAMMA_LUT fallback (an xe log-gamma curve in i915's linear LUT). Fix: i915_ignore_gamma.sh.
  The colour-space (#23/#25), full-range (#27) and sRGB-only SF props weren't the cause but are kept (harmless,
  more correct for this sRGB panel). Known cost: Night Light has no effect.
- gbOS86 branding + boot menu in stage0 (kernel #30, initramfs-only change): with the stick in, a 10 s menu offers
  1 live / 2 install-or-update / 3 boot the installed system (default 3 if installed, else 1). gbos.cfg MODE=ask|live|
  install|boot (old BOOT_FROM=stick = live). Menu timeout path tested in QEMU. tools/make_gbos86_image.sh builds
  dist/gbOS86-YYYYMMDD.img (GPT: 256M EFI + 6G GBOS FAT32, super.img rebuilt from lapis/parts). First image
  gbOS86-20261016.img built; not boot-tested (user declined).
- 2026-10-16: usb/early_patch.sh (sourced from gbos.cfg) wraps `chroot` so the patched libz/libcrypto are bound before
  stage0's first `dmctl` (avoids ~3.7M SHA-NI traps at boot); hook.sh skips re-binding ("already patched"). install.sh
  FILES and make_gbos86_image.sh now ship it, so Update copies it to the NVMe. Stick deployed with kernel #30.
  Not yet verified on hardware: look for "early: patched system libcrypto" before "running gbos/hook.sh" in stage0-dmesg.txt.
- 2026-10-16: **Generic Intel gen6+ support (kernel #32, not yet booted on hardware).** `configure_whl.py --generic` adds ~400
  modules (Wi-Fi: iwldvm/iwlmvm/rtw88/rtw89/mt76/ath10k/ath11k/brcmfmac; BT: btusb+vendors, btintel_pcie; HDA codecs + SOF/SoundWire;
  I2C-HID/ISH/RMI4/PS2; dell/hp/thinkpad/ideapad/asus/... platform drivers; card reader, UVC, ethernet). `usb/hwdetect.sh` (from
  hook.sh) bind-mounts `gbos/modules` over /lib/modules, coldplugs by modalias (up to 4 passes) with firmware from `gbos/firmware`,
  and writes `logs/boot-N/hwdetect.txt`. The old Wi-Fi/BT sequence stays as a fallback when `gbos/modules` is absent.
  `snd_intel_dspcfg.dsp_driver=1` was REMOVED from the cmdline (HDA vs SOF is now automatic; on the Dell, Dell vendor + no DMIC should
  still pick HDA. **Verify sound on the 5300**; rollback = the #30 BOOTX64.EFI from git history, `e2207d9`). Firmware is not committed:
  `tools/fetch_firmware.sh` (linux-firmware d5455717 + sof-bin 2026.09.2, ~290 MB); iwlwifi files live at the firmware root
  (this kernel doesn't use the intel/iwlwifi/ prefix). Audio HAL config is generated for non-PCH cards (best effort).
  QEMU: ISA_EMU_TEST_PASS; `kernel/isa_emu_test/run_hwdetect.py` loaded e1000e/i2c_i801/rapl/wmi/video by modalias.
- 2026-10-16: dist/gbOS86-20261016.img rebuilt with kernel #32, usb/modules (396 modules), usb/firmware (~290 MB), hwdetect.sh,
  early_patch.sh (sha256 f20823e0…; 6.7 GB, 2.2 GB free on its GBOS partition). Not boot-tested. The Dell stick still has kernel #30
  until it is re-synced (copy usb/ -> stick incl. modules/ and firmware/, BOOTX64.EFI to both EFI copies).
- 2026-10-16 AI features (Magic Pointer says "Gemini is not available at this moment"), from NVMe boot-19 (kernel #30, in stick boot-1/nvme-logs):
  gPointer asks AICore for feature 713 (`AiCoreException ... 606-FEATURE_NOT_FOUND: Feature 713 is not available`), at boot and on every launch.
  AICore (Play-updated, runs as uid 10107) never gets its feature manifest: `Failed to fetch manifest config ... Unable to resolve host
  ondevicesafety-pa.googleapis.com` x55, then "Required labels are missing from the protected download manifest. Download will not be
  triggered". The first tries (15:54:33) were before Wi-Fi came up (15:54:33.97), but 15:54:43/48/53 were 10-20 s after it validated, and
  as.oss (10118, same Google AI stack) was online then, so it is not just "no network yet". The host resolves fine on a Mac. Cause undetermined:
  AICore's uid (PCC-allowed package, `PccSandboxManagerInternal: Updated allowed PCC Packages ... com.google.android.aicore`) may be
  network-blocked, or lacks INTERNET in netd's map. Nothing else on the device failed to resolve a host (only android.googleapis.com, pre-Wi-Fi).
  Separate and unfixable here: Private Inference attestation (`AttestAndSign ... PERMISSION_DENIED`; keystore2 `HARDWARE_TYPE_UNAVAILABLE`
  for the RKP IRPC x361, because Trusty KeyMint/RKP are hidden) and as.oss `PcsAi__enable_genai_inference_service` (AICore forwarding off).
  Added `usb/aidiag.sh` + `gbos_aidiag`/`gbos_aidns_*` services in hook.sh: `logs/boot-N/ai-1.txt` (90 s) and `ai-2.txt` (4 min) with
  ping-as-uid (10107 AICore, 10118 as.oss, 10119 as, 2000 shell), package/permission/gids dumps, connectivity/netpolicy/PCC state. Not yet run
  on hardware. install.sh FILES and make_gbos86_image.sh ship aidiag.sh. The dev stick was re-made this day (GPT, EFI 200 MB + GBOS 30 GB;
  mount the EFI partition with `sudo diskutil mount disk8s1`; the ESP image was written with dd so it keeps the EFI System type).
- 2026-10-16 **Wi-Fi regression on kernel #32 (NVMe boot-20): root cause found and fixed.** hwdetect loaded iwlwifi by PCI alias and it took
  its firmware (`loaded firmware version 46... op_mode iwlmvm`), but nothing loaded `iwlmvm`: the kernel's request_module() for the op_mode is a
  silent no-op in the stage0 initramfs (the old hook.sh did an explicit `modprobe iwlmvm`). No iwlmvm/mac80211 in lsmod, no wlan0 (`wifi=` empty in
  hwdetect.txt), so ai-1/ai-2 were taken with no network at all (every ping "unknown host", also as root) and say nothing about DNS.
  Fix: `gbos_load_opmodes` in usb/hwdetect.sh modprobes whatever `op_mode iwl*` the dmesg announces, after every coldplug pass and every second of the
  device wait while there is no wl* interface. hook.sh now also honours HWDETECT=0 by using the old sequence (it used to skip Wi-Fi entirely). I had
  briefly staged a revert (#30 + HWDETECT=0), then undid it: #32 and HWDETECT=1 are back (usb/out/BOOTX64.EFI.32 is a copy of #32). Untested on hardware:
  look for `hwdetect: loaded iwlmvm` and `wifi=wlan0` in stage0-dmesg.txt / hwdetect.txt.
  aidiag.sh now waits (up to 5 min) for the network before dumping and pings www.google.com as each uid too, so ai-1/ai-2 become meaningful.
- 2026-10-16 AI, from boot-20 dumps: AICore (prod_aicore_20260917.00_RC01, uid 10107) does NOT request android.permission.INTERNET (gids=[3013] only;
  as.oss has INTERNET + 3003, gpointer has 3003). Its feature-manifest fetch runs a gRPC DnsNameResolver in the AICore process itself (stack ioh/ihi in
  pid of com.google.android.aicore), so "Unable to resolve host ondevicesafety-pa.googleapis.com" (55x in boot-19, with Wi-Fi up) fits an app with no
  INTERNET: netd blocks its DNS. AICore also binds as.oss AstreaGrpcService (act=grpc.io.action.BIND), and as.oss hardcodes that host and has
  PccSecurity__aicore_package_security_info / PcsAi__enable_genai_inference_service flags, so the intended route is probably via as.oss and depends on a
  flag/security policy delivered by Phenotype. NOT fixed: no safe way found to give AICore network (INTERNET is set by ConnectivityService from the manifest;
  ndc only sets NETWORK/SYSTEM). Needs a run with working Wi-Fi: compare ping www.google.com / ondevicesafety as uid 10107 vs 10118 in ai-1/ai-2.
- 2026-10-16 "Extract logs": boot menu **2** -> sub-menu now has **3) Only save its logs** (usb/install.sh, `ACTION=logs`, `LOG_BOOTS`, default 3): mounts GBOSSYS
  read-only, copies the last N boots to the stick's boot-N/nvme-logs, powers off on Enter; seconds instead of Update's copy+verify of ~4 GB. `save_logs` (cp, falling
  back to dd conv=noerror,sync for FAT-truncated files) is also used by Update. A top-level menu key 4 was written for stage0 but dropped: the menu lives in the kernel's
  initramfs, so it needs a kernel rebuild (usb/make_initramfs.py reproduces #32's cpio byte for byte, so it would be an incremental relink). install.sh is a stick script, no kernel change.
- 2026-10-16 **Wi-Fi fix CONFIRMED on hardware (NVMe boot-21, kernel #32):** `hwdetect: loaded iwlmvm (op_mode announced by iwlwifi)`, `devices after 0s: wifi=wlan0`.
- 2026-10-16 **AI root cause (boot-21, Wi-Fi up, Magic Pointer tried): Google's server rejects AICore's feature-manifest request because there is no key attestation.**
  Retire the earlier "AICore has no INTERNET" theory: AICore (user-0 pid) does reach ondevicesafety-pa.googleapis.com. After a first pre-network `Unable to resolve host`
  (17:24:30), every attempt from 17:25:01 on fails with `ien: INVALID_ARGUMENT: Request contains an invalid argument`, immediately after as.oss (the gateway, pid 2876)
  logs `AttestationClientImpl: Failed to generate key with ID attestation, retrying without it` (java.security.ProviderException: Failed to generate key pair). Cause:
  keystore2 `Failed to get rpc for sec level TRUSTED_ENVIRONMENT: HARDWARE_TYPE_UNAVAILABLE` (115x in this boot): remote key provisioning has no IRemotelyProvisionedComponent
  (Trusty KeyMint/RKP are hidden in hook.sh, software KeyMint serves keys but cannot attest). With no manifest, AICore registers no features: gPointer `Feature 713 is not
  available`, notification summary `Feature 253`, ModelDownloadManager `Feature 2007`. The device identity is fine (ASUS/lapis, "ASUS Googlebook 14"). Same blocker as BSA
  `AttestAndSign ... PERMISSION_DENIED`. Fixing it would need a Google-accepted hardware attestation chain; not possible on this laptop, and faking one is not something to build.
  aidiag ping-as-uid results (user-0 uids 10107/10118/10119 "unknown host", shell 2000 fine) are an artifact: the foreground user is 10; test user-10 uids (1010107...) if this is revisited.
  Cloud-only features (Gemini app chat, Search) do not depend on AICore. Not yet checked on hardware: whether the Gemini app itself answers.
- 2026-10-16 **Discord report: Acer Aspire Lite AL15-52 (i5-1235U), kernel #32, "no Wi-Fi", everything else works. Two causes, both fixed in the repo.**
  (1) Their image predates `3626366`: the published/built `dist/gbOS86-20261016.img` (13:17) has no `gbos_load_opmodes` in `hwdetect.sh`, so iwlwifi loads but
  `iwlmvm` never does (same as NVMe boot-20). Kernel is byte-identical, so a stick is fixed by copying `usb/hook.sh` + `usb/hwdetect.sh` to `gbos/` (or rebuild).
  (2) `tools/fetch_firmware.sh` regex for `rtw89/` only matched `rtw8922a`: no firmware for RTL8852A/B/BT/C or 8851B (RTL8852BE is the usual Wi-Fi 6 card in budget Acers),
  so the v32 firmware release had none. Regex fixed; those 12 files added; release **v33** carries `gbos86-firmware-d5455717-sof2026.09.2-r2.tar.xz`
  (sha256 877f6fe9…), and `build.sh` now fetches firmware from v33 and re-downloads it if `usb/firmware/rtw89/rtw8852b_fw.bin` is missing (so existing checkouts upgrade).
  The reporter's card model is unknown (their report had no lspci): ask for `gbos/logs/boot-N/hwdetect.txt` after the rebuild (`wifi=` line, "pci devices without a driver", "missing firmware").
  Not verified on hardware (no such laptop here); AX201/AX211 (so-a0-hr/gf firmware) and RTL8852BE (rtw89_8852be) are both now covered.
- 2026-10-16 **Acer Aspire Lite AL15-52 Bluetooth (Intel AX201, USB 8087:0026): firmware name was a WHENCE link we never shipped.** Reporter's hwdetect.txt: btusb bound and
  `hci0` exists, but `Bluetooth: hci0: Failed to load Intel firmware file intel/ibt-0040-1050.sfi (-2)`. linux-firmware's WHENCE has `Link: intel/ibt-0040-1050.sfi -> ibt-0040-0041.sfi`
  (and .ddc); Links only exist after linux-firmware's install script, and `tools/fetch_firmware.sh` reads `git ls-tree`, so every Link was skipped. Same for `ibt-0040-4150 -> 0040-0041`
  and `ibt-0040-2120 -> 0040-1020`. `fetch_firmware.sh` now copies the target for each WHENCE Link whose target we ship (FAT has no symlinks). Local `usb/firmware/intel` has the six
  files; stick fix for the reporter = `dist/gbos-bt-fix-ibt-0040-1050.zip` (merge into the stick's `gbos/`, then Update). Permanent fix 2026-10-17: release **v34** carries `gbos86-firmware-d5455717-sof2026.09.2-r3.tar.xz`
  (v33 + those six files, 38 MB, sha256 653a6a22…); `build.sh` fetches it and re-downloads when `usb/firmware/intel/ibt-0040-1050.sfi` is missing (existing checkouts upgrade). Other Links (not only Bluetooth) are now picked up on the next full fetch; not yet re-run (needs the 1.5 GB linux-firmware clone). Not verified on hardware.
- 2026-10-16 **Local AI replacement for AICore (new, optional; `localai/`, not yet booted on hardware).** Since Google's servers refuse AICore without
  key attestation (entry above), `localai/` builds a stand-in with package `com.google.android.aicore` (APK, ~20 KB) that answers gPointer's binder calls
  and runs **Gemma 4 E2B** (official QAT q4_0 GGUF, 3.35 GB) through `llama-server` (llama.cpp v0.7.0, Android x86_64, AVX2 only). Protocol read from gPointer's
  own client code (jadx in docker; the Mac's Homebrew Java 17 crashes with SIGBUS, use docker): bind `…service.multiuser.AiCoreMultiUserService` → provider →
  `IAICoreService` (apiVersion >= 7, `getFeatureOrControl(713,1)`, status 3, `getLLMLegionService`) → `runCancellableInferenceWithInfo`. Feature 713 is the
  Legion server model. gPointer sends its 14 KB instruction prompt as a system message plus "with OCR text: '…'" per selected area (image-only regions are
  bitmaps, which the text-only service ignores) and splits the reply on newline then tab, so `Chips.java` repairs the format.
  Installer: `usb/install.sh` asks **on every install and update** ("Install or keep the local AI replacement? [y/N]"; n removes it); yes copies the APK/server
  to GBOSSYS `gbos/localai/` and the model to `/data/gbos-localai/model.gguf` (not enough room next to super.img) and sets `LOCAL_AI=1` in the installed gbos.cfg.
  `hook.sh` then bind-mounts the APK over `/product/priv-app/AICorePrebuilt*/`, `usb/localai/prep.sh` removes a Play-updated AICore from `/data/app` in post-fs-data,
  `run.sh` starts the server at boot_completed, `diag.sh` writes `logs/boot-N/localai.txt` (package state, services, our logcat). Tested off-hardware only:
  model + real prompt in docker (cold 23 s on an M-series Mac, ~1 s once the prompt prefix is cached), chip-format unit tests, wire format vs Google's SafeParcel code.
  **First thing to check on the laptop:** `pm path com.google.android.aicore` in localai.txt must be our APK (if a Play-updated copy still wins, fix `prep.sh`;
  PackageManager's handling of a system package with a changed signature is unverified). Put `model.gguf` in the stick's `gbos/localai/` before choosing yes
  (`localai/fetch_model.sh`). Build: `localai/fetch_toolchain.sh`, `build_apk.sh`, `build_llama.sh` (all docker).
- 2026-10-16 **Local AI, boot 26: AICore side works; Magic Pointer then exits on its RobinKit capability check; gPointer patch added (not yet booted).** prep.sh (read-only APK on /data bound over the
  AICore stub + Play update removed + package-cache entry removed) made PackageManager use our APK; gPointer logged `Successfully prepared PrivateInferenceService features`, our service answered
  getFeatureOrControl(713)/getFeatureStatus/getLLMLegionService for users 0 and 10. Earlier failures, all fixed: scripts not copied by the installer (exit 127), "Writable dex file is not allowed" (FAT
  files are world-writable; ART refuses), stale PackageManager parse cache of the stub (`AiCoreMultiUserService: not found`), and a /tmp source file deleted at switch_root (apps got ENOENT).
  New blocker: `gPointer/MainActivity: RobinKit capability check failed for returning user` = Gemini app offers only TEXT_QUERY, gPointer requires TEXT_QUERY + TEXT_QUERY_WITH_ATTACHMENTS
  (`ErrorsKt.requiredCapabilities`, one use: `containsAll`). `localai/patch_gpointer.py` (1 byte + dex/zip checksums, signature block untouched) + `localai/build_gpointer.sh`;
  installer/prep.sh/diag.sh extended. The running gPointer on the SSD is a Play-updated split APK (26091600), so prep.sh removes it to fall back to the patched system copy.
  Check next: `pm path`/package state for gpointer in localai.txt (does PackageManager accept the unverified signature?), RobinKit lines, then whether our service logs `inference:`.
- 2026-10-16 **Local AI, boot 29: the patched Magic Pointer runs (PackageManager accepted the APK with Google's signature block left unverifiable; Gemini app logs "Robin is eligible and opted-in"), user reached the "ask Gemini" send; our service then got its first real inference request and rejected it.**
  Cause: my parcel reader took `p.dataPosition() + sizeOf(p, h)` with the position read BEFORE the size int (Java evaluates left to right), so every big-field/object end was 4 bytes short; the callback binder after the request read as null
  (`IllegalArgumentException: null request or callback`, transaction 6). Fixed with `Wire.endOf`; `localai/test.sh` now round-trips a realistic request/result/feature through a stand-in Parcel and a reference reader written from gPointer's SafeParcel code
  (verified to fail on the old code). Noted for later: `gPointer/OcrTextRecog: NPU compilation failed` (selections may then arrive as bitmaps only, which the text-only model can't read).
- 2026-10-16 **Local AI: vision measured, deliberately NOT enabled (branch `local-ai`).** Gemma 4 E2B is multimodal and Google's repo ships the projector (`gemma-4-E2B-it-mmproj.gguf`, 986,833,664 bytes, sha256 021059cc…eb14; llama.cpp v0.7.0 has the GEMMA4V projector and
  `--mmproj`/`--image-max-tokens`). Measured in docker on an M2 Pro (4 threads, CPU only), gPointer's real prompt + a 900x1599 photo: text only cold 23 s; with an image at 70 / 140 / 280 image tokens: 45 / 63 / 112 s cold (the image step is ~22 / 40 / 88 s;
  it scales with detail), later requests with the same image ~1 s. The i5-8365U is estimated 3 to 5x slower, so an image request would take minutes, close to gPointer's 240 s limit. To enable later: decode LLMMessage field 3 (a Bitmap parcelable, type 1)
  in `Messages`, shrink it, send it as an `image_url` data URI (merge consecutive same-role messages first), start `llama-server` with `-mm /data/gbos-localai/mmproj.gguf --image-max-tokens 70`, and have the installer copy the 0.99 GB file.
  gPointer sends text when its OCR works (`OcrTextRecog: NPU compilation failed` was logged, so check whether selections arrive as bitmaps) and a bitmap only for image regions.
  Gboard (`LatinIMEGoogleDesktopPrebuilt`) also uses AICore: `ILLMService`, `IMagicRewriteService`, `ITextEmbeddingService` (flag `writing_tools_pi_aicore_feature_id_override`); our stand-in implements only the LLM service.
- 2026-10-16 **AI features now go through a user-provided API (branch `api-ai`, off `local-ai`); the local model is gone.** User decision: the local model was too slow on the i5-8365U (measured: a cold request with one image 63 to 112 s on an M2 Pro), so `Llama.java`/llama-server/run.sh/model scripts/NDK
  are removed and the service calls any OpenAI-compatible chat API with the user's address, key and model (`Api.java`, `Config.java`, `Json.java`, `Settings.java`). `usb/install.sh` `localai_step`: asks on every install/update; y = settings file on the stick (`gbos/localai/api.conf`), or keep the saved
  ones, or prompts on the laptop (key typed with echo off via `ask_secret`, never logged); n = remove everything incl. the saved key; the old model/mmproj/llama-server files are deleted on every run. `prep.sh` copies `/data/gbos-localai/api.conf` (root, 600) into
  `/data/user_de/<user>/com.google.android.aicore/files/` owned by the app uid (the app reads it per request). Pictures: `Messages.imageDecoder` (Bitmap parcelable field 3 -> JPEG <= 1024 px -> data URI), consecutive same-role messages merged, errors mapped to AICore codes, hourly cap `MAX_PER_HOUR`.
  Tests (`localai/test.sh`, docker): chips, wire (reference reader), API client incl. a real HTTP round trip and key-never-leaks checks, and the installer step under busybox (found a real bug: the "keep saved settings?" question was skipped because LOCAL_AI is reset to 0 inside the function). Vision checked live with `test/VisionLive.java` against Gemma 4 + its vision file
  speaking the same API: a laptop photo and a bar chart both read correctly and came back in the chip format. Not checkable off-device: Bitmap decoding inside Android, a real provider. The patched Magic Pointer stays (it was accepted by PackageManager and reached the selection UI in boot 29).
- 2026-10-16 **Faster update/verify loop.** An Update took ~10 min because it cmp'd the whole 5 GB super.img against the SSD, re-copied firmware (309 MB, 1751 files) and modules (94 MB, 410 files) on FAT every time, then sha256'd both sides of every file with busybox's software sha256.
  Now: (1) `check()` is a byte compare (page cache dropped first), no hashing; (2) super.img, firmware and modules are skipped when their "stamp" (hash of file names, sizes and mtimes on the stick) equals the one saved on the SSD (`gbos/.stamps/`) after the last VERIFIED copy
  (fresh installs save stamps too; `UPDATE_FULL=1` or a missing stamp forces the full path; the first update after this change is still a full one); (3) `tools/deploy_stick.sh` copies only changed files to the stick, verifies after a remount, ejects the right disk (also removes the old local-model files);
  (4) diag snapshots at 40 s/120 s (nothing to wait for any more); (5) the Update already saves the previous boots' logs first, so one stick boot reads the last test AND applies the next change; `LOCAL_AI=1` in gbos.cfg removes the AI prompts. Stamps and the byte-compare are tested under busybox (`localai/test.sh`). Not measured on the laptop yet.
- 2026-10-17 **Firmware for every driver we ship (release v35).** Instead of fixing one missing name per bug report: `tools/fw_wanted.py` reads the `firmware=` strings out of every `.ko` in
  `usb/modules` (MODULE_FIRMWARE) and resolves them against linux-firmware (exact file, WHENCE Link target, wildcard, iwlwifi "newest API <= the driver's max"); `fetch_firmware.sh` ships all of that plus the
  families whose names are built at run time (ath10k/ath12k WCN7850, rtw88/rtw89, rtl_bt, rtl_nic, qca, brcm, cypress, cirrus, xe, intel/ish). Before: amdgpu (575 files, no AMD GPU could initialise), r8169/r8152 `rtl_nic/*`
  (the reporter's RTL8168 had none), btmtk/mt7615/mt76x2, brcmfmac, most cirrus amp tuning, ath12k. 309 -> 484 MB on the stick, 70 MB download. linux-firmware 12dfe670 (was d5455717; files re-extracted over the old).
  Still absent because linux-firmware has no such file: pre-production iwlwifi steppings (bz-a0, ma-a0, sc-a0...), SDIO-only brcm/rtl8723*s boards, amdgpu `*_cap.bin`/ip_discovery, ca0132 ctefx-desktop/r3di
  (list: `unresolved.txt` in the fetch work dir). Release **v35** `gbos86-firmware-12dfe670-sof2026.09.2-r4.tar.xz` (sha256 8ad4ce62…); `build.sh` fetches it and re-downloads when `usb/firmware/rtl_nic/rtl8168h-2.fw`
  is missing. Not verified on hardware; the Update path copies firmware only when the stamp changes (it will, this once).
- 2026-10-17 **eMMC support (installer + boot), kernel #33, tested in QEMU only.** `usb/install.sh` now takes an internal NVMe *or eMMC* as the target: eMMC = `mmcblkN` whose `device/type` is `MMC`
  (SD cards/readers and the stick are never candidates; `mmcblkNbootX`/`rpmb` don't match), serial = MMC `serial` (CID if empty/zero), partitions `mmcblk0p1..4`, `INSTALL_DISK=` in gbos.cfg chooses among several
  disks. The host controller driver `sdhci-pci` is a module, so: install.sh binds the stick's module tree and `modprobe`s it if the kernel doesn't have it (works on #32), and **stage0 now loads it before the
  volume search** (needs the initramfs in the kernel: #33 = #32 + `sdhci`, `sdhci-uhs2`, `cqhci`, `sdhci-pci` in `usb/modroot`, depmod'ed in gbos-kbuild, relinked with `kernel/isa_emu_patch/build.sh`;
  `usb/out/BOOTX64.EFI` is now #33, `.32` kept). Not supported: ACPI-enumerated eMMC (`MMC_SDHCI_ACPI` is off; some AMD/older Atom). Test: `kernel/isa_emu_test/run_installer_emmc.py usb/out/BOOTX64.EFI --boot`
  prints `ISA_EMU_INSTALLER_EMMC_PASS` (22 checks: wrong-serial cancel writes nothing, install, GPT/FAT/ext4 verified on the host, update, boot from the eMMC alone, NVMe still works, SD card refused).
  Test traps: QEMU's emulated eMMC *erases by really writing 0xFF*, so mke2fs's discard of the 25 GB data partition filled a Mac's disk (the test now passes `-E nodiscard` when `gbos_install_confirm=` is set,
  and aborts if the image passes 6 GB); QEMU stores the eMMC boot partitions first in the image, so the user area (GPT) is not at offset 0. Never run on a real eMMC laptop.
- 2026-10-17 **Framework 13 Pro (Core Ultra 5 325, Panther Lake, PCI 8086:b090) black screen after choosing live boot; kernel #32 hwdetect.** Cause: `xe 0000:00:02.0: GuC firmware xe/ptl_guc_70.bin not found`;
  xe cannot probe without its GuC, so there was no DRM device/backlight/console. The reporter's stick predates firmware v35 (v32-v34 shipped `i915/` only, no `xe/`). v35 already carries `xe/ptl_{guc_70,huc,gsc_1}.bin` and `i915/xe3lpd*_dmc.bin`
  (xe.ko 6.18.21 lists exactly these); rebuilding with v35 fixes it. Stick fix for the reporter: `dist/gbos-xe-fix-ptl.zip` (2.3 MB, merge into the stick's `gbos/`; live boot needs nothing else). Checked off-device only: xe.ko has the b090 alias,
  Google's `libminigbm_gralloc.so`/`vulkan.intel.so` contain the PTL ids. **Not verified on the laptop.** Still open from the same hwdetect, all downstream of the dead GPU or separate:
  no soundcard (SOF PTL modules loaded, firmware/topology present; check again once the screen works), and Wi-Fi 8086:e440 has no driver bound: this kernel's iwlwifi asks only for `-c99` core files (`iwlwifi-sc-a0-fm-c0-c99`,
  `sc-a0-wh-a0-c99`, `sc2-*`), while linux-firmware's newest are c101..c108 (too new for it) and the numeric `sc-a0-wh-b0-101` is not requested, so PTL Wi-Fi probably needs a newer iwlwifi (unconfirmed).
- 2026-10-17 **XPS 16 (2026) report: slow refresh rate, no Wi-Fi, no camera; HP 14-ne0013dx "no luck"; ThinkPad T470 works out of the box. Tooling added, not the fixes (no logs from those machines).**
  Reporter says a Linux kernel-command-line option fixes the XPS screen but does not remember which. `gbos.cfg` now takes `MODOPTS="xe.param=value ..."` (`gbos_modopts` in `usb/hwdetect.sh`: `modprobe module param=value` before the coldplug,
  not /etc/modprobe.d because /etc is read-only under Android's init; a module stage0 already loaded keeps its parameters and the log says so; tested under busybox with stubbed modprobe only). hwdetect.txt now also has the DRM connectors' modes,
  video4linux devices, xe/i915 parameters and 250 lines of wifi/graphics/camera/audio/Bluetooth dmesg (until now only "firmware not found" lines, which is why PTL Wi-Fi `8086:e440` has no cause yet). Stick update: `dist/gbos-hwdetect-modopts.zip`.
  Panther Lake Wi-Fi facts from this kernel's source: iwlwifi asks `-c99` core files, then numeric API 101/100 (`IWL_SC_UCODE_API_MIN` 100); linux-firmware has numeric `sc-a0-wh-b0-101` (shipped) but for `sc-a0-fm-c0` only c101+ (rejected as newer than core 99),
  and no pnvm for `sc`. Which RF the laptops have is unknown until a hwdetect shows the iwlwifi lines. Camera: a USB webcam works (Framework: uvcvideo); a MIPI/IPU7 camera needs ipu7 drivers and an Android camera HAL: not started.
- 2026-10-17 **Tested-laptops list published (README "Tested laptops", gbos86.com/hardware, docs page `tested-laptops`, overview/safety/FAQ/home wording).** One data file, `website/laptops.py`, feeds the site; README has a hand copy.
  Rows: Latitude 5300 (works), Acer Aspire Lite AL15-52 (works, BT after the ibt-0040-1050 fix), ThinkPad T470 (works, short report), HP OmniBook 7 / Core Ultra 5 225U (partly: no Wi-Fi, BE201), XPS 16 (partly: refresh rate, Wi-Fi, camera),
  Framework 13 Pro (fix pending: xe firmware), HP 14-ne0013dx (no, no logs). Reporters' Discord names are not published. Not deployed to the server from here (needs HOST/SSH_KEY).
- 2026-10-17 Tested-laptops list: added Intel NUC8BEH (i3-8109U, live USB kernel #32: Wi-Fi, Bluetooth, display, USB work; SATA SSD so no install). Now 8 machines, 4 fully working.
- 2026-10-17 **SATA (M.2 SATA / 2.5") install support, tested in QEMU only.** `usb/install.sh` takes a SATA disk as the target: `sdX` whose sysfs path goes through a libata `ataN/hostM` port (USB sticks, USB-SATA bridges, virtio disks are
  `sdX` too but never match). SATA is only a candidate when there is no NVMe/eMMC (an NVMe + SATA data disk keeps installing to the NVMe, as before); `INSTALL_DISK=sda` picks it explicitly. No kernel change (`SATA_AHCI`, `SCSI`, `BLK_DEV_SD` are `=y` in #33),
  and `stage0_init.sh` is unchanged (it is inside the kernel image). Serial: `device/vpd_pg80` is **empty** on libata disks in this kernel, so the serial (and the full model) come from `device/wwid`, which is `t10.ATA` + vendor + 40-char model + serial; the sysfs `model` is cut to 16 chars.
  Partition names `sda1..4` (no `p`): the partition listing/umount greps were `^${T}p` and are now `^${T}p\?[0-9]`. Test: `kernel/isa_emu_test/run_installer_sata.py usb/out/BOOTX64.EFI` prints `ISA_EMU_INSTALLER_SATA_PASS` (8 steps: cancel, install, update, boot from SATA alone, NVMe+SATA,
  INSTALL_DISK=sda, two SATA refused, USB disk refused). NOT tried on real hardware (the NUC8BEH is the obvious candidate; its BIOS must be in AHCI, not RST/RAID). Known gap: with the stick in and gbos already installed on SATA, libata may enumerate after the stick, so the boot
  menu could miss "Boot the installed gbOS86"; a short wait in `stage0_init.sh` would fix it but needs a kernel rebuild, not done. The eMMC test's "no internal ..." message strings were updated to the new wording.
- 2026-10-18 **Surface Laptop 7 for Business (Intel, Core Ultra 7 266V, Lunar Lake, PCI 8086:64a0) black screen after choosing live boot; kernel #32 hwdetect.** Same cause as the Framework 13 Pro: `xe 0000:00:02.0: GuC firmware xe/lnl_guc_70.bin not found`, an old stick
  without firmware v35 (which has `xe/lnl_{guc_70,huc,gsc_1}.bin` and `i915/xe2lpd_dmc.bin`; xe.ko 6.18.21 lists exactly these). Stick fix: `dist/gbos-xe-fix-lnl.zip` (2.2 MB, merge into the stick's `gbos/`). **Not verified on the laptop.**
  Open, from the same hwdetect: (1) no keyboard input device (only the `MSHW0554:00 04F3:4384` touch devices and an external USB mouse); PCI `8086:a848` / `8086:a84b` (class 0x0901, unbound) look like Lunar Lake Touch Host Controllers
  (QuickI2C/QuickSPI), and `CONFIG_INTEL_THC_HID`, `MFD_INTEL_LPSS_PCI`, `I2C_DESIGNWARE_PCI`, `SURFACE_AGGREGATOR` are all off in `kernel/out/.config`: **unconfirmed guess**, needs the PCI IDs checked against the 6.18 source (docker was not running) and a log from a working screen.
  (2) no soundcard (SoundWire codecs, `cs42l43`/`cs35l56`-class firmware; the untracked `usb/firmware/cs42l43.bin`/`ctefx.bin` are unrelated work in progress). (3) Wi-Fi `8086:a840` shows as having no driver (no iwlwifi dmesg in this old hwdetect).
  linux-surface (github.com/linux-surface) does **not** list the Laptop 7 Intel as supported ("unsupported"; its SL7 pointer is `bryce-hoehn/linux-surface-laptop-7`, which is the Snapdragon/ARM model), so it is not a ready-made patch set for this machine.
  Tested-laptops list (README, `website/laptops.py`, counts now nine) has the Surface as "fix pending".
- 2026-10-18 **Porting to a new Google build is now a tool, not a checklist (`porting.md`).** Until now every patch was pinned by a sha256 typed into `hook.sh`/`early_patch.sh`/`apex_patch.sh`, the `libkm_compat` patch had no
  script at all (a hand edit), `system_ext_manifest.xml` and the gPointer patch were copies/offsets from one build, and a new Google build disabled them silently. Now: (1) `tools/patch_km_compat.py` (new) finds the patch by the exported
  `KeystoreCompatService::getKeyMintDevice` symbol (the level copy `mov %edx,%r15d` -> `xor %r15d,%r15d`, 3 bytes at 0x302f5 in this build); (2) `tools/port_build.sh` (+ `extract_build.py`, `port_build.py`, runs in the gbos-erofs container) unpacks
  system/vendor/system_ext (+product) and every erofs APEX payload, re-applies libz/libcrypto/libkm_compat/Conscrypt-APEX patches, regenerates `usb/system_ext_manifest.xml` (Google's manifest minus the three Trusty KeyMint/RKP/SecureClock `<hal>`s)
  and writes `usb/patched/MANIFEST` (kind, device path, sha256 of the original, patched file; plus `watch` hashes of the files our overlays were copied from: VINTF manifest, audio config, fstab); it also checks ~30 anchors the boot scripts rely on
  (init.rc line, the VINTF/rc files hook.sh hides, vold rule, build.prop keys, Trusty VM image, AICore/Magic Pointer paths) and with `--isa` compares the instruction scan with `lapis/scan/*.json`;
  (3) the three device scripts read the MANIFEST (no hashes in them) and log `NOT patched (original is <sha>, patch was made for <sha>)` plus one `PATCH-STATUS N applied, M not applied` line in `stage0-dmesg.txt`
  (`apex_patch:` logs APEX libcrypto copies it leaves alone); (4) `localai/patch_gpointer.py` finds its site structurally (ErrorsKt.<clinit>, field `TEXT_QUERY_WITH_ATTACHMENTS_CAPABILITY`) instead of sha + offset 0x289870;
  (5) `lapis/BUILD` is the one place with the build id/URL (build.sh, lapis/dl.sh read it); `tools/check_new_build.sh` looks for a newer lapis build.
  **Retested on build 16452207 (the one we ship):** all six patches and the VINTF manifest regenerate byte-identical to the shipped files, the rebuilt 235 MB `gpointer.apk` is byte-identical to the one built before, and
  `tools/test_port_scripts.sh` (the real script code under the stick's busybox, stubbed mount; 26 checks) prints PORT_SCRIPTS_PASS. **Not run on the laptop:** the rewritten `hook.sh`/`early_patch.sh`/`apex_patch.sh` have not booted yet. First check after the next
  Update: `PATCH-STATUS 5 applied, 0 not applied` and `early: patched /new/system/lib64/libcrypto.so` in `stage0-dmesg.txt`, `apex_patch: patched` lines in logcat. Rollback = the previous `usb/hook.sh`, `early_patch.sh`, `apex_patch.sh` from git.
  No newer lapis build exists yet (2026-10-18): dl.google.com still serves 16452207 (7,728,873,477 bytes) and neither aluminium-os.com nor cros.tech lists a later id, so there was nothing to re-patch for. Found on the way: three vendor APEXes
  (clearkey, crosfp, StrongBox) carry their own libcrypto with SHA-NI that no patch covers (`INFO other APEX libcrypto` in the port output).
