#!/bin/busybox sh
# gbos USB debug stage0: find the GBOS USB volume, log everything to it,
# mount the lapis erofs images, create dm devices, switch to Android init.
export PATH=/bin:/sbin
/bin/busybox --install -s /bin
mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t tmpfs -o mode=0755 tmpfs /dev
mknod -m 600 /dev/console c 5 1; mknod -m 600 /dev/kmsg c 1 11; mknod -m 666 /dev/null c 1 3
mknod -m 620 /dev/tty0 c 4 0; mknod -m 620 /dev/tty1 c 4 1
exec </dev/console >/dev/console 2>&1
log() { echo "gbos-stage0: $*" > /dev/kmsg; }
shell() {
  log "DROPPING TO SHELL ($1). type 'exit' to continue boot."
  setsid cttyhack sh </dev/tty1 >/dev/tty1 2>&1
}
fail() { log "FATAL: $*"; shell "failure"; }

log "=== gbos-x86 USB debug boot, kernel $(uname -r) ==="
mdev -s
mknod -m 660 /dev/loop-control c 10 237 2>/dev/null
for i in $(seq 0 15); do mknod -m 660 /dev/loop$i b 7 $i 2>/dev/null; done
mkdir -p -m 0755 /dev/socket /dev/block /dev/pts /dev/dm-user /dev/mapper
mknod -m 600 /dev/mapper/control c 10 236; mknod -m 600 /dev/device-mapper c 10 236

# Wait for the USB stick (label GBOS)
log "waiting for USB volume LABEL=GBOS ..."
DEV=
for i in $(seq 1 60); do
  mdev -s
  DEV=$(findfs LABEL=GBOS 2>/dev/null) && [ -n "$DEV" ] && break
  sleep 1
done
[ -n "$DEV" ] || fail "USB volume GBOS not found after 60s (block devices: $(ls /sys/class/block | tr '\n' ' '))"
log "found GBOS at $DEV"
mkdir -p /gbos
mount -t vfat -o rw,flush,umask=000 $DEV /gbos || fail "mount $DEV failed"
G=/gbos/gbos
cp /bin/busybox /gbos/busybox 2>/dev/null

# Boot-numbered log directory on the stick
N=1; while [ -e $G/logs/boot-$N ]; do N=$((N+1)); done
L=$G/logs/boot-$N; mkdir -p $L
log "logging to USB: gbos/logs/boot-$N/kmsg.log"
# Logger keeps running after switch_root: open kmsg fd now, use busybox from the stick.
# Loops end (instead of spinning) if the stick becomes unreachable, e.g. SELinux denial.
( exec 3</dev/kmsg; while /gbos/busybox cat <&3 >> $L/kmsg.log || /gbos/busybox sleep 1; do :; done ) &
( while /gbos/busybox sleep 5; do /gbos/busybox sync; done ) &

# Config file on the stick (edit from any computer)
SHELL_AT=none; LOAD_I915=1; LOAD_WIFI=0; EXTRA_SLEEP=0
[ -f $G/gbos.cfg ] && . $G/gbos.cfg && log "loaded gbos.cfg: SHELL_AT=$SHELL_AT LOAD_I915=$LOAD_I915 LOAD_WIFI=$LOAD_WIFI"

# Hardware inventory
{
  echo "== cmdline"; cat /proc/cmdline
  echo "== cpu"; grep -m1 'model name' /proc/cpuinfo; grep -m1 '^flags' /proc/cpuinfo
  echo "== mem"; head -3 /proc/meminfo
  echo "== pci (slot class vendor:device driver)"
  for d in /sys/bus/pci/devices/*; do
    drv=$(readlink $d/driver 2>/dev/null); echo "${d##*/} $(cat $d/class) $(cat $d/vendor):$(cat $d/device) ${drv##*/}"
  done
  echo "== block"; ls -l /sys/class/block/
  echo "== fb/drm"; ls /sys/class/graphics /sys/class/drm 2>&1
} > $L/hw.txt 2>&1
mount -t pstore pstore /sys/fs/pstore 2>/dev/null && cp -r /sys/fs/pstore $L/pstore-prev 2>/dev/null
log "hardware inventory written (hw.txt)"

[ "$SHELL_AT" = early ] && shell "SHELL_AT=early"

if [ "$LOAD_I915" = 1 ]; then
  log "modprobe i915 (UHD 620). If the screen freezes here, set LOAD_I915=0 in gbos.cfg"
  modprobe i915 && log "i915 loaded" || log "i915 load FAILED rc=$?"
  sleep 2; mdev -s
fi
if [ "$LOAD_WIFI" = 1 ]; then
  log "modprobe iwlmvm"; modprobe iwlmvm && log "iwlmvm loaded" || log "iwlmvm load FAILED"
fi

# Android partitions. Preferred: gbos/super.img (liblp dynamic partitions, layout in
# super.layout: "name start_sector num_sectors"). Fallback: separate gbos/<name>.img files.
mkdir -p /new /dev/block/by-name
dmctl() { LD_LIBRARY_PATH=/system/lib64/bootstrap:/system/lib64 chroot /new /system/bin/bootstrap/linker64 /system/bin/dmctl "$@"; }
target() { case $1 in system_a) echo /new;; *) echo /new/${1%_a};; esac; }
if [ -f $G/super.img ] && [ -f $G/super.layout ]; then
  log "using super.img (dynamic partitions)"
  losetup -r /dev/loop7 $G/super.img || fail "losetup super.img failed"
  mknod -m 600 /dev/block/loop7 b 7 7 2>/dev/null; ln -sf /dev/block/loop7 /dev/block/by-name/super
  i=0
  while read n start len; do  # system_a is first, so / is mounted before the others
    t=$(target $n); mkdir -p $t 2>/dev/null
    losetup -r -o $((start * 512)) /dev/loop$i $G/super.img && mount -t erofs -o ro /dev/loop$i $t \
      && log "mounted $n (super @ sector $start) -> $t" || { log "mount $n FAILED"; [ $n = system_a ] && fail "system mount failed"; }
    i=$((i+1))
  done < $G/super.layout
  mount --bind /dev /new/dev; mount --bind /proc /new/proc; mount --bind /sys /new/sys
  while read n start len; do
    dmctl create $n -ro linear 0 $len /dev/block/loop7 $start >/dev/null 2>&1
    log "dmctl $n = super[$start +$len] rc=$?"
  done < $G/super.layout
else
  log "no super.img, using separate partition images"
  i=0
  for n in system_a vendor_a product_a system_ext_a system_dlkm_a vendor_dlkm_a; do
    t=$(target $n); mkdir -p $t 2>/dev/null
    losetup -r /dev/loop$i $G/$n.img && mount -t erofs -o ro /dev/loop$i $t \
      && log "mounted $n -> $t" || { log "mount $n FAILED"; [ $n = system_a ] && fail "system mount failed"; }
    i=$((i+1))
  done
  mount --bind /dev /new/dev; mount --bind /proc /new/proc; mount --bind /sys /new/sys
  i=8
  for n in system_a vendor_a product_a system_ext_a; do
    losetup -r /dev/loop$i $G/$n.img; sz=$(cat /sys/block/loop$i/size)
    dmctl create $n -ro linear 0 $sz /dev/loop$i 0 >/dev/null 2>&1
    log "dmctl $n on loop$i ($sz sectors) rc=$?"
    i=$((i+1))
  done
fi
umount /new/sys; umount /new/proc; umount /new/dev
mdev -s

[ -f $G/hook.sh ] && { log "running gbos/hook.sh"; . $G/hook.sh; }

[ "$SHELL_AT" = pre_android ] && shell "SHELL_AT=pre_android (Android root at /new)"

mount -t tmpfs -o mode=0771 tmpfs /new/data
mount -t tmpfs tmpfs /new/metadata
mount -t devpts devpts /dev/pts -o mode=0620,ptmxmode=0666 2>/dev/null
mknod -m 666 /dev/ptmx c 5 2 2>/dev/null; mknod -m 666 /dev/zero c 1 5 2>/dev/null
mknod -m 666 /dev/random c 1 8 2>/dev/null; mknod -m 666 /dev/urandom c 1 9 2>/dev/null
dmesg > $L/stage0-dmesg.txt; sync
sleep $EXTRA_SLEEP
mount --move /dev /new/dev; mount --move /proc /new/proc; mount --move /sys /new/sys
mount -t selinuxfs selinuxfs /new/sys/fs/selinux
for d in mnt debug_ramdisk second_stage_resources; do mount -t tmpfs -o mode=0755 tmpfs /new/$d; done
echo "gbos-stage0: switching root -> /system/bin/init selinux_setup" > /new/dev/kmsg
exec switch_root /new /system/bin/init selinux_setup
