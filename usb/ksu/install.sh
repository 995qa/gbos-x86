#!/system/bin/sh
# KernelSU userspace setup. Started by gbos.rc (post-fs-data and again after boot_completed).
#
# Two things live on the Android side of KernelSU:
#   /data/adb/ksud      the daemon the kernel starts (it runs "su" for allowed apps)
#   the manager app     the official KernelSU app; the kernel only accepts an APK whose signing
#                       certificate is the official one, so the APK from the KernelSU release is
#                       used (a Play Store copy is signed by Google and would be rejected)
#
# Both come from the stick (gbos/ksu/, installed by build.sh) and are copied into /data, which
# is persistent on an NVMe install and a tmpfs on a live boot.
G=/postinstall/gbos
N=$1
MANAGER=${2:-1}
LOG=$G/logs/boot-$N/ksu.txt
PKG=me.weishu.kernelsu

mkdir -p /data/local/tmp
mkdir -p "$(dirname "$LOG")"
: > "$LOG"
say() { echo "$*" >> "$LOG"; echo "ksu: $*"; }

# KSU_MANAGER=0 in gbos.cfg: the kernel has KernelSU, but no app is installed (the daemon still is).
if [ "$MANAGER" = 0 ]; then
  say "manager app not installed (KSU_MANAGER=0)"
  exit 0
fi

# 1. ksud: the kernel's injected init.rc runs it at post-fs-data, so it must be in place early.
if [ -f $G/ksu/ksud ]; then
  mkdir -p /data/adb
  if [ ! -f /data/adb/ksud ] || ! cmp -s $G/ksu/ksud /data/adb/ksud; then
    cp $G/ksu/ksud /data/adb/ksud && chmod 755 /data/adb/ksud && say "ksud installed in /data/adb ($(stat -c %s /data/adb/ksud 2>/dev/null) bytes)"
  else
    say "ksud already in /data/adb"
  fi
else
  say "no ksud on the stick (gbos/ksu/ksud)"
fi

# 2. the manager app. pm needs the package manager, which only exists after the framework is up,
#    so this part is done on the boot_completed run.
if [ -f $G/ksu/manager.apk ]; then
  if pm path $PKG >/dev/null 2>&1; then
    say "manager $PKG already installed"
  else
    cp $G/ksu/manager.apk /data/local/tmp/ksu-manager.apk
    out=$(pm install -r -g /data/local/tmp/ksu-manager.apk 2>&1)
    say "pm install: $out"
    rm -f /data/local/tmp/ksu-manager.apk
  fi
else
  say "no manager APK on the stick (gbos/ksu/manager.apk)"
fi

# 3. what the kernel thinks of it
say "kernel: $(dmesg 2>/dev/null | grep -i -m3 -E 'KernelSU|ksu' | tr '\n' ' ')"
