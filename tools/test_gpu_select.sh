#!/bin/sh
# Shell unit test of the GPU decision and bind logic in usb/hook.sh (fake /sys and fake /new trees, no root, no mounts).
#   sh tools/test_gpu_select.sh
# Pulls the gbos_gpu_* block out of hook.sh between its marker comments, so what is tested is what boots.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOOK=$HERE/../usb/hook.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/gpusel.XXXXXX"); trap 'rm -rf "$T"' EXIT
sed -n '/^# --- GPU driver selection/,/^# --- end GPU driver selection ---/p' "$HOOK" > "$T/block.sh"
[ -s "$T/block.sh" ] || { echo "FAIL: marker block not found in hook.sh"; exit 1; }
fails=0; n=0
log() { echo "$*" >> "$T/log"; }
sleep() { :; }
mount() { echo "$*" >> "$T/mounts"; return ${MOUNT_RC:-0}; }
sha256sum() { case "$1" in */libminigbm_gralloc.so) echo "${FAKE_GRALLOC_SHA:-d48536951fd0e9643e71a5c8843e90833ce3e212e182782185470e2fbbfad673}  $1";; */libgbm.so) echo "${FAKE_LIBGBM_SHA:-64a0f2537a5917822cb3f538dc74229e7ccf4ca45a30265bb97f742678ba294e}  $1";; */vulkan.intel.so) echo "${FAKE_VK_SHA:-5c687450523ea9ed9e8d4d9cc98ef4fef6c8d592d46db4bf425ad571dc6f7c73}  $1";; *) command sha256sum "$@" 2>/dev/null || shasum -a 256 "$@";; esac; }
. "$T/block.sh"

# fake sysfs: $1 = list of "cardN:driver[:conn]" (conn = the display is on this card), $2 = list of "vendor:class" PCI devices
mk() {
  rm -rf "$T/sys" "$T/log" "$T/mounts"; mkdir -p "$T/sys/class/drm" "$T/sys/bus/pci/devices" "$T/drivers"
  for mc in $1; do
    mn=${mc%%:*}; rest=${mc#*:}; md=${rest%%:*}; cn=${rest#*:}
    mkdir -p "$T/sys/class/drm/$mn/device" "$T/sys/class/drm/$mn-eDP-1"
    [ "$md" = none ] || { mkdir -p "$T/drivers/$md"; ln -s "$T/drivers/$md" "$T/sys/class/drm/$mn/device/driver"; }
    if [ "$cn" = conn ]; then echo connected > "$T/sys/class/drm/$mn-eDP-1/status"; else echo disconnected > "$T/sys/class/drm/$mn-eDP-1/status"; fi
  done
  mi=0
  for mp in $2; do mi=$((mi+1)); mkdir -p "$T/sys/bus/pci/devices/0000:00:0$mi.0"; echo "${mp%%:*}" > "$T/sys/bus/pci/devices/0000:00:0$mi.0/vendor"; echo "${mp#*:}" > "$T/sys/bus/pci/devices/0000:00:0$mi.0/class"; done
}
# The Mesa EGL that the nouveau path needs, on the fake stick.
mkmesa() { G=$T/gbos; mkdir -p $G/mesa; for f in libEGL_mesa.so libGLESv1_CM_mesa.so libGLESv2_mesa.so libgallium_dri.so libgbm.so.1; do : > $G/mesa/$f; done; }
check() { # name expected(GPU_SW) expected(GPU_NV) cards pci [GPU_SOFTWARE] [GPU_NVIDIA]
  n=$((n+1)); mk "$4" "$5"; SYSFS=$T/sys; GPU_SOFTWARE=${6:-auto}; GPU_NVIDIA=${7:-auto}; GPU_SW=x; GPU_NV=x
  # a fake Android root: the Mesa install mounts a tmpfs over $NEWROOT/vendor/lib64
  G=$T/gbos; NEWROOT=$T/new; mkdir -p $NEWROOT/vendor/lib64/hw
  gbos_gpu_decide 3
  if [ "$GPU_SW" = "$2" ] && [ "$GPU_NV" = "$3" ]; then echo "ok   $1 -> sw=$GPU_SW nv=$GPU_NV ($(tail -n1 $T/log | cut -c1-110))"
  else echo "FAIL $1: wanted sw=$2 nv=$3, got sw=$GPU_SW nv=$GPU_NV"; cat "$T/log"; fails=$((fails+1)); fi
}
AMD=0x1002:0x030000; INTEL=0x8086:0x030000; NV=0x10de:0x030200
mkmesa
check "Intel i915 laptop"              0 0 "card0:i915:conn"          "$INTEL"
check "Intel xe"                       0 0 "card0:xe:conn"            "$INTEL"
check "Intel, i915 not bound yet"      0 0 "card0:simpledrm:conn"    "$INTEL"
check "Intel + AMD dGPU (hybrid)"      0 0 "card0:i915:conn card1:amdgpu" "$INTEL $AMD"
check "AMD amdgpu (reporter's laptop)" 1 0 "card0:amdgpu:conn"        "$AMD"
check "AMD, simpledrm replaced"        1 0 "card1:amdgpu:conn card0:simpledrm" "$AMD"
check "AMD but amdgpu did not bind"    0 0 "card0:simpledrm:conn"    "$AMD"
check "AMD, no card at all"            0 0 ""                        "$AMD"
check "forced on Intel"                1 0 "card0:i915:conn"          "$INTEL" 1
check "disabled on AMD"                0 0 "card0:amdgpu:conn"        "$AMD" 0
check "vkms only"                      0 0 "card0:vkms:conn"          ""
# NVIDIA: the display is on the nouveau card -> Mesa's gallium nouveau draws with the GPU
check "nouveau, display on it"         0 1 "card0:nouveau:conn"       "$NV"
check "nouveau + Intel iGPU, display on NVIDIA" 0 1 "card0:i915 card1:nouveau:conn" "$INTEL $NV"
check "nouveau + Intel iGPU, display on Intel"  0 0 "card0:i915:conn card1:nouveau" "$INTEL $NV"
check "nouveau, GPU_NVIDIA=0"          1 0 "card0:nouveau:conn"       "$NV" auto 0
check "nouveau, GPU_NVIDIA=1 forced"   0 1 "card0:i915:conn card1:nouveau" "$INTEL $NV" auto 1
rm -f $G/mesa/libEGL_mesa.so
check "nouveau without Mesa on the stick" 1 0 "card0:nouveau:conn"    "$NV"
mkmesa

# enable: binds only over the exact originals, skips quietly when the stick has no files
# runenable NAME GRALLOC LIBGBM VULKAN SW_AFTER: expected 1 = bind attempted
runenable() {
  n=$((n+1)); rm -f "$T/log" "$T/mounts"; GPU_SW=1; gbos_gpu_enable
  m=$(cat "$T/mounts" 2>/dev/null)
  g=0; b=0; v=0; case "$m" in *libminigbm_gralloc.so*) g=1;; esac; case "$m" in *lib64/libgbm.so*) b=1;; esac; case "$m" in *vulkan.intel.so*) v=1;; esac
  if [ $g = $2 ] && [ $b = $3 ] && [ $v = $4 ] && [ "$GPU_SW" = $5 ]; then echo "ok   enable: $1 (gralloc=$g gbm=$b vk=$v sw=$GPU_SW)"
  else echo "FAIL enable: $1: gralloc=$g gbm=$b vk=$v sw=$GPU_SW"; cat "$T/log"; fails=$((fails+1)); fi
}
G=$T/gbos; NEWROOT=$T/new; mkdir -p $G/patched $NEWROOT/vendor/lib64/hw
: > $NEWROOT/vendor/lib64/libgbm.so; : > $NEWROOT/vendor/lib64/libminigbm_gralloc.so; : > $NEWROOT/vendor/lib64/hw/vulkan.intel.so
runenable "stick without the files (old stick)" 0 0 0 0
: > $G/patched/libgbm.amdgpu.so; : > $G/patched/vulkan.swiftshader.so; : > $G/patched/libminigbm_gralloc.amdgpu.so
runenable "all files, originals match" 1 1 1 1
FAKE_VK_SHA=deadbeef; runenable "unknown vulkan.intel.so (new Google build)" 1 1 0 0; unset FAKE_VK_SHA
FAKE_GRALLOC_SHA=deadbeef; runenable "unknown libminigbm_gralloc.so" 0 1 1 0; unset FAKE_GRALLOC_SHA
FAKE_LIBGBM_SHA=deadbeef; runenable "unknown libgbm.so (not essential)" 1 0 1 1; unset FAKE_LIBGBM_SHA
rm $G/patched/vulkan.swiftshader.so
runenable "no SwiftShader HAL on the stick" 1 1 0 0
: > $G/patched/vulkan.swiftshader.so; MOUNT_RC=1; runenable "bind fails" 1 1 1 0; unset MOUNT_RC

# NVIDIA: the Vulkan driver for Vulkan apps is SwiftShader (the CPU one); nothing else is replaced
n=$((n+1)); rm -f "$T/log" "$T/mounts"; GBOS_GPU_LOG="hook: nvidia:"; gbos_gpu_nvidia_enable
m=$(cat "$T/mounts" 2>/dev/null); v=0; case "$m" in *vulkan.swiftshader.so*) v=1;; esac
case "$m" in *libminigbm_gralloc*) g=1;; *) g=0;; esac
if [ $v = 1 ] && [ $g = 0 ]; then echo "ok   nvidia: SwiftShader bound for Vulkan apps, gralloc untouched"
else echo "FAIL nvidia enable: vk=$v gralloc=$g"; cat "$T/log"; fails=$((fails+1)); fi
n=$((n+1)); rm -f "$T/log" "$T/mounts"; rm -f $G/patched/vulkan.swiftshader.so; gbos_gpu_nvidia_enable
if [ ! -s "$T/mounts" ] && grep -q "no Vulkan driver" "$T/log"; then echo "ok   nvidia: no SwiftShader on the stick -> logged, nothing bound"
else echo "FAIL nvidia enable (no SwiftShader)"; cat "$T/log"; fails=$((fails+1)); fi
: > $G/patched/vulkan.swiftshader.so

# RADV: used when it is on the stick and amdgpu is bound; GPU_VULKAN forces either; falls back to SwiftShader when RADV cannot be bound
radvmount() { grep -q "vulkan.radv.so" "$T/mounts" 2>/dev/null && echo radv || { grep -q "vulkan.swiftshader.so" "$T/mounts" 2>/dev/null && echo swiftshader || echo none; }; }
rv() { # name expected GPU_VULKAN
  n=$((n+1)); runenable_quiet; r=$(radvmount)
  if [ "$r" = "$2" ]; then echo "ok   vulkan: $1 -> $r"; else echo "FAIL vulkan: $1: wanted $2, got $r"; cat "$T/log"; fails=$((fails+1)); fi
}
runenable_quiet() { rm -f "$T/log" "$T/mounts"; GPU_SW=1; gbos_gpu_enable; }
mk "card0:amdgpu:conn" "$AMD"; SYSFS=$T/sys; : > $G/patched/vulkan.swiftshader.so
rv "amdgpu, no RADV on the stick" swiftshader
: > $G/patched/vulkan.radv.so
rv "amdgpu + RADV on the stick" radv
GPU_VULKAN=swiftshader; rv "forced SwiftShader" swiftshader
GPU_VULKAN=radv; rv "forced RADV" radv; unset GPU_VULKAN
mk "card0:nouveau:conn" "$NV"; SYSFS=$T/sys; rv "other GPU driver, RADV present" swiftshader
mk "card0:amdgpu:conn" "$AMD"; SYSFS=$T/sys; FAKE_VK_SHA=deadbeef; rv "unknown vulkan.intel.so" none; unset FAKE_VK_SHA

# vendor build.prop rewrite: in software-GPU mode Google's enable_color_pipeline=true must become false (drm_hwcomposer rejects every amdgpu plane otherwise)
sed -n '/^DROP=/,/^} > \/tmp\/vendor.build.prop/p' "$HOOK" | sed "s#/new/vendor/build.prop#$T/vendor.build.prop#g; s#/tmp/vendor.build.prop#$T/out.prop#g; s#^} > .*#}#" > "$T/prop.sh"
bp() { # name GPU_SW expected(enable_color_pipeline in the result)
  n=$((n+1)); printf 'vendor.hwc.drm.enable_color_pipeline=true\nvendor.hwc.use_log_gamma_lut=true\nro.sf.lcd_density=260\n' > "$T/vendor.build.prop"; rm -f "$T/out.prop"
  ( GPU_SW=$2; DENSITY=; DEVICE_MODEL=; . "$T/prop.sh" > "$T/out.prop" ) 2>/dev/null
  r=$(grep '^vendor.hwc.drm.enable_color_pipeline=' "$T/out.prop" | tr '\n' ' ')
  if [ "$r" = "vendor.hwc.drm.enable_color_pipeline=$3 " ]; then echo "ok   build.prop: $1 -> color_pipeline=$3"; else echo "FAIL build.prop: $1: got '$r'"; cat "$T/out.prop"; fails=$((fails+1)); fi
}
bp "software GPU mode (AMD)" 1 false
n=$((n+1)); printf 'ro.hwui.use_vulkan=true\nvendor.hwc.drm.enable_color_pipeline=true\n' > "$T/vendor.build.prop"
( GPU_SW=1; DENSITY=; DEVICE_MODEL=; . "$T/prop.sh" > "$T/out.prop" ) 2>/dev/null
if [ "$(grep -c '^ro.hwui.use_vulkan=' "$T/out.prop")" = 1 ] && grep -q '^ro.hwui.use_vulkan=false$' "$T/out.prop"; then echo "ok   build.prop: software GPU mode -> ro.hwui.use_vulkan=false (once)"; else echo "FAIL build.prop hwui"; cat "$T/out.prop"; fails=$((fails+1)); fi
n=$((n+1)); printf 'ro.hwui.use_vulkan=true\n' > "$T/vendor.build.prop"; ( GPU_SW=0; DENSITY=; DEVICE_MODEL=; . "$T/prop.sh" > "$T/out.prop" ) 2>/dev/null
if grep -q '^ro.hwui.use_vulkan=true$' "$T/out.prop"; then echo "ok   build.prop: Intel keeps ro.hwui.use_vulkan=true"; else echo "FAIL build.prop hwui Intel"; fails=$((fails+1)); fi
bp "Intel (stock, unchanged)" 0 true

# the NVIDIA path: ANGLE is replaced by Mesa's EGL, SurfaceFlinger and the apps use OpenGL
n=$((n+1)); printf 'ro.hardware.egl=angle\ndebug.renderengine.vulkan=true\nro.hwui.use_vulkan=true\nvendor.hwc.drm.enable_color_pipeline=true\n' > "$T/vendor.build.prop"; rm -f "$T/out.prop"
( GPU_SW=0; GPU_NV=1; DENSITY=; DEVICE_MODEL=; . "$T/prop.sh" > "$T/out.prop" ) 2>/dev/null
if grep -q '^ro.hardware.egl=mesa$' "$T/out.prop" && grep -q '^debug.renderengine.vulkan=false$' "$T/out.prop" \
   && grep -q '^ro.hwui.use_vulkan=false$' "$T/out.prop" \
   && grep -q '^vendor.hwc.drm.enable_color_pipeline=false$' "$T/out.prop" \
   && [ "$(grep -c '^ro.hardware.egl=' "$T/out.prop")" = 1 ] && [ "$(grep -c '^debug.renderengine.vulkan=' "$T/out.prop")" = 1 ]; then
  echo "ok   build.prop: NVIDIA -> ro.hardware.egl=mesa, GL render engine, no Vulkan in HWUI, color pipeline off"; else echo "FAIL build.prop nvidia"; cat "$T/out.prop"; fails=$((fails+1)); fi
n=$((n+1)); printf 'ro.hardware.egl=angle\n' > "$T/vendor.build.prop"; rm -f "$T/out.prop"
( GPU_SW=0; GPU_NV=0; DENSITY=; DEVICE_MODEL=; . "$T/prop.sh" > "$T/out.prop" ) 2>/dev/null
if grep -q '^ro.hardware.egl=angle$' "$T/out.prop"; then echo "ok   build.prop: Intel keeps ro.hardware.egl=angle"; else echo "FAIL build.prop egl Intel"; fails=$((fails+1)); fi

[ $fails = 0 ] && echo "GPU_SELECT_TEST_PASS ($n checks)" || { echo "$fails FAILED"; exit 1; }
