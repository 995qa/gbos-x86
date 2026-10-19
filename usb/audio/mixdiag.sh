#!/system/bin/sh
# mixdiag.sh N: sound diagnostics of boot-N, run by the gbos_audiodiag service 60 s after boot. Writes logs/boot-N/mixer.txt:
# the ALSA mixer controls of card 0 with their current values (needs audio/tinymix, a static tinyalsa tinymix built by
# tools/build_surface_tools.sh; without it that part is skipped), the UCM / SoundWire files in the image, and the card tree.
N=$1
L=/postinstall/gbos/logs/boot-$N
T=/postinstall/gbos/audio/tinymix
{
  echo "== tinymix contents (card 0)"
  if [ -x $T ]; then $T -D 0 contents; else echo "(no audio/tinymix on the stick)"; fi
  echo "== ucm / soundwire config files in the image"
  find /vendor /system /system_ext /product -maxdepth 7 \( -iname '*ucm*' -o -iname '*sof-soundwire*' \) 2>/dev/null | head -60
  echo "== /proc/asound/card0 tree"; ls -R /proc/asound/card0 2>/dev/null | head -80
} > $L/mixer.txt 2>&1
