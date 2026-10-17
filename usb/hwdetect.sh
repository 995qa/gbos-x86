# gbOS86 hardware detection: sourced by stage0_init.sh (once the gbos volume is mounted at /gbos) and by hook.sh.
# Needs: $G (gbos dir), log(), $L (boot log dir, optional). Pure busybox ash.
#
# What it does, in order (every step is non-fatal; a laptop just ends up with fewer drivers):
#  1. gbos_modules_mount: bind the stick's full module tree (gbos/modules/lib/modules/<uname -r>, depmod'ed,
#     ~1000 drivers) over /lib/modules, so modprobe can resolve any device's modalias.
#  2. gbos_coldplug: the usual udev trick without udev: read every device's `modalias` from sysfs and
#     `modprobe -a` them, repeated because a loaded driver (HDA controller, USB hub, ...) creates new devices.
#     This finds the right Wi-Fi, Bluetooth, audio (HDA or SOF), touchpad/keyboard (I2C-HID, ISH, PS/2),
#     laptop hotkey/backlight (dell/hp/thinkpad/ideapad/asus/...), card-reader and webcam drivers on any machine.
#     MODOPTS="xe.enable_psr=0 ..." in gbos.cfg (the same module.param=value spelling as on a Linux kernel command line)
#     loads those modules first with the given parameters (gbos_modopts), so a screen/driver quirk fix needs no kernel rebuild.
#  3. firmware: the kernel's firmware loader looks in gbos/firmware (a copy of linux-firmware, trimmed).
#  4. gbos_hw_report: writes hwdetect.txt next to the other boot logs: what got a driver, what didn't,
#     which firmware files were missing.
GBOS_FWPATH=/sys/module/firmware_class/parameters/path

gbos_modules_mount() {
  KVER=$(uname -r)
  if [ -f $G/modules/lib/modules/$KVER/modules.dep ]; then
    mount --bind $G/modules/lib/modules /lib/modules 2>/dev/null \
      && log "hwdetect: module tree $KVER ($(find /lib/modules/$KVER -name '*.ko' | wc -l) modules) from gbos/modules" \
      || log "hwdetect: bind mount of gbos/modules FAILED"
    return 0
  fi
  log "hwdetect: gbos/modules/lib/modules/$KVER missing, only the initramfs modules are available"
  return 1
}

# iwlwifi is only the bus half: once it has its firmware it asks for the op_mode driver named in the ucode
# ("... op_mode iwlmvm") with request_module(), which silently does nothing in this initramfs. Without
# iwlmvm there is no wlan0 (boot-20 on kernel #32: iwlwifi loaded, firmware loaded, no Wi-Fi). Load it ourselves.
gbos_load_opmodes() {
  for m in $(dmesg | sed -n 's/.*op_mode \(iwl[a-z]*\).*/\1/p' | sort -u); do
    grep -q "^$m " /proc/modules && continue
    modprobe -q $m && log "hwdetect: loaded $m (op_mode announced by iwlwifi)" || log "hwdetect: modprobe $m FAILED"
  done
}

# MODOPTS="module.param=value ..." (gbos.cfg): modprobe each named module with its parameters before the coldplug loads it
# without. Done with `modprobe module param=value` (not /etc/modprobe.d: /etc is read-only under Android's init).
# A module already loaded by stage0 keeps its parameters; that is logged. Built-in (non-module) parameters cannot be set here.
gbos_modopts() {
  [ -n "$MODOPTS" ] || return 0
  echo "$MODOPTS" | tr ' ' '\n' | awk 'index($0,".")>1 && index($0,"=")>index($0,".") {i=index($0,"."); m=substr($0,1,i-1); o[m]=o[m] " " substr($0,i+1)} END{for(m in o) print m o[m]}' \
    | while read m opts; do
        mu=$(echo $m | tr - _)
        if grep -q "^$mu " /proc/modules; then log "hwdetect: MODOPTS: $m is already loaded, '$opts' NOT applied"; continue; fi
        modprobe -q $m $opts && log "hwdetect: MODOPTS: loaded $m $opts" || log "hwdetect: MODOPTS: modprobe $m $opts FAILED"
      done
  for kv in $MODOPTS; do
    case $kv in ?*.?*=*) ;; *) log "hwdetect: MODOPTS entry ignored (want module.param=value): $kv";; esac
  done
}

# One coldplug pass: all modaliases, de-duplicated, to a single modprobe (it reads modules.alias once).
gbos_coldplug_pass() {
  find /sys/devices -name modalias 2>/dev/null | xargs cat 2>/dev/null | sort -u \
    | xargs modprobe -a -q 2>/dev/null
}

gbos_coldplug() {
  [ -f /lib/modules/$(uname -r)/modules.alias ] || { log "hwdetect: no modules.alias, skipping coldplug"; return 1; }
  # Not loaded by alias: ACPI video (brightness keys), battery already built in.
  p=1; before=$(wc -l < /proc/modules)
  while [ $p -le 4 ]; do
    gbos_coldplug_pass
    sleep 1; gbos_load_opmodes; mdev -s 2>/dev/null
    now=$(wc -l < /proc/modules)
    log "hwdetect: coldplug pass $p: $now modules loaded (was $before)"
    [ $now -eq $before ] && break
    before=$now; p=$((p+1))
  done
}

# Give drivers time to finish probing and pull their firmware (Wi-Fi, Bluetooth, audio DSP).
gbos_wait_devices() {
  i=0
  while [ $i -lt ${1:-15} ]; do
    w=$(ls /sys/class/net 2>/dev/null | grep -c '^wl')
    b=$(ls /sys/class/bluetooth 2>/dev/null | wc -l)
    s=$(grep -c '\[' /proc/asound/cards 2>/dev/null)
    # Done when every class that exists on this machine has shown up, or nothing is loading any more.
    if [ "$w" -gt 0 ] && [ "$b" -gt 0 ] && [ "$s" -gt 0 ]; then break; fi
    [ "$w" -eq 0 ] && grep -q '^iwlwifi ' /proc/modules && gbos_load_opmodes
    sleep 1; i=$((i+1))
  done
  log "hwdetect: devices after ${i}s: wifi=$(ls /sys/class/net 2>/dev/null | grep '^wl' | tr '\n' ' ') bt=$(ls /sys/class/bluetooth 2>/dev/null | tr '\n' ' ') sound=$(cat /proc/asound/cards 2>/dev/null | grep '\[' | tr -s ' ' | tr '\n' ';') backlight=$(ls /sys/class/backlight 2>/dev/null | tr '\n' ' ')"
}

gbos_hw_report() {
  [ -n "$L" ] || return 0
  {
    echo "== kernel"; uname -a
    echo "== dmi"; for f in sys_vendor product_name product_version bios_version board_name; do echo "$f=$(cat /sys/class/dmi/id/$f 2>/dev/null)"; done
    echo "== pci devices without a driver (slot class vendor:device)"
    for d in /sys/bus/pci/devices/*; do
      [ -e $d/driver ] || echo "${d##*/} $(cat $d/class) $(cat $d/vendor):$(cat $d/device)"
    done
    echo "== usb devices (vid:pid product)"
    for d in /sys/bus/usb/devices/[0-9]*-[0-9.]*; do
      [ -f $d/idVendor ] && echo "$(cat $d/idVendor):$(cat $d/idProduct) $(cat $d/product 2>/dev/null) drv=$(for i in $d:*; do readlink $i/driver 2>/dev/null; done | sed 's#.*/##' | sort -u | tr '\n' ',')"
    done
    echo "== input"; grep -E '^(N: Name|H: Handlers)' /proc/bus/input/devices
    echo "== net";   ls /sys/class/net
    echo "== bluetooth"; ls /sys/class/bluetooth 2>&1
    echo "== backlight"; for b in /sys/class/backlight/*; do [ -e $b ] && echo "$b max=$(cat $b/max_brightness) cur=$(cat $b/brightness)"; done
    echo "== sound"; cat /proc/asound/cards 2>&1
    echo "== rfkill"; for r in /sys/class/rfkill/*; do [ -e $r ] && echo "$(cat $r/name) $(cat $r/type) soft=$(cat $r/soft) hard=$(cat $r/hard)"; done
    echo "== missing firmware"; dmesg | grep -iE 'firmware.*(failed|not found|-2\))|Direct firmware load.*failed|failed to load.*(ucode|\.bin|\.sfi)' | sort -u
    echo "== MODOPTS"; echo "${MODOPTS:-(none)}"
    echo "== display (drm connectors: status, enabled, first modes)"
    for c in /sys/class/drm/card*-*; do
      [ -e $c/status ] && { echo "${c##*/} status=$(cat $c/status) enabled=$(cat $c/enabled 2>/dev/null)"; head -6 $c/modes 2>/dev/null | sed 's/^/    /'; }
    done
    echo "== video devices (cameras)"; for v in /sys/class/video4linux/*; do [ -e $v ] && echo "${v##*/} $(cat $v/name)"; done
    for m in xe i915; do
      [ -d /sys/module/$m/parameters ] && { echo "== $m parameters"; for p in /sys/module/$m/parameters/*; do echo "${p##*/}=$(cat $p 2>/dev/null)"; done; }
    done
    echo "== driver messages (wifi, graphics, camera, audio, bluetooth; first 250)"
    dmesg | grep -iE 'iwlwifi|iwlmvm|iwlmld|\bxe [0-9a-f:.]+|\[drm|ipu[0-9]|intel-ipu|ivsc|sof-audio|snd_sof|sof-firmware|soundwire|cs42l43|Bluetooth: hci|btintel|No config found|unsupported' | head -250
    echo "== lsmod"; lsmod
  } > $L/hwdetect.txt 2>&1
  log "hwdetect: report written (hwdetect.txt)"
}

# Whole thing; $1 = seconds to wait for devices (default 15).
gbos_hwdetect() {
  [ -f $G/gbos.cfg ] && [ "$HWDETECT" = 0 ] && { log "hwdetect: disabled (HWDETECT=0)"; return 0; }
  [ -d $G/firmware ] && echo -n $G/firmware > $GBOS_FWPATH
  gbos_modules_mount && gbos_modopts && gbos_coldplug && gbos_wait_devices ${1:-15}
  # The brightness keys/backlight need acpi_video when the panel has no native backlight.
  [ -d /sys/class/backlight ] && [ -z "$(ls /sys/class/backlight 2>/dev/null)" ] && modprobe -q video 2>/dev/null
  gbos_hw_report
}
