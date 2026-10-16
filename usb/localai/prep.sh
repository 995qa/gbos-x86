#!/system/bin/sh
# gbOS86 local AI, step 1 (runs as root in post-fs-data, before PackageManager starts). Puts our localai.apk in place of
# the system AICore stub and clears everything that would still hide it:
#  1. The APK must be read-only: ART refuses code from a writable dex file ("Writable dex file ... is not allowed", boot 24),
#     and the stick's FAT mount makes every file world-writable. So keep a read-only copy on /data and bind that. (Not a
#     copy made in stage0's /tmp: that source file is deleted at switch_root and apps then failed to stat it, boot 25.)
#  2. A Play-updated AICore in /data/app wins over the system package: remove it; PackageManager falls back to ours.
#  3. PackageManager's parse cache for the stub (no services) made it answer "AiCoreMultiUserService: not found" (boot 25):
#     remove that package's entries so the APK is parsed again every boot.
D=/postinstall/gbos/localai
S=/data/gbos-localai
mkdir -p "$S"

if cp "$D/localai.apk" "$S/localai.apk.new" && chmod 444 "$S/localai.apk.new" && mv -f "$S/localai.apk.new" "$S/localai.apk"; then
  b=0
  for a in /product/priv-app/AICorePrebuilt*/*.apk; do
    [ -f "$a" ] || continue
    if mount -o bind "$S/localai.apk" "$a"; then b=$((b+1)); else log -t gbos-localai "bind over $a FAILED"; fi
  done
  log -t gbos-localai "localai.apk (read-only, $(ls -l "$S/localai.apk" | cut -c1-10)) bound over $b AICore apk(s)"
else
  log -t gbos-localai "could not stage localai.apk in $S: the stock AICore stub stays"
fi

# --- API settings. The installer writes them to $S/api.conf (root-only: it holds the user's API key). The AICore app needs to read
# them, so give it its own private copy in each Android user's device-protected storage, readable by that app uid only.
# (Old local-model files from earlier versions are removed here too; the installer deletes them as well.)
rm -f "$S/model.gguf" "$S/mmproj.gguf"
if [ -f "$S/api.conf" ]; then
  uid=$(awk '$1=="com.google.android.aicore"{print $2}' /data/system/packages.list 2>/dev/null)
  case "$uid" in ''|*[!0-9]*) log -t gbos-localai "API settings NOT copied: no uid for com.google.android.aicore in packages.list" ;; *)
    c=0
    for d in /data/user_de/*; do
      u=${d##*/}
      case "$u" in ''|*[!0-9]*) continue;; esac
      f="$d/com.google.android.aicore/files"
      full=$((u*100000+uid))
      if mkdir -p "$f" && cp "$S/api.conf" "$f/api.conf" && chown $full:$full "$f" "$f/api.conf" && chmod 700 "$f" && chmod 600 "$f/api.conf"; then
        c=$((c+1))
      else
        log -t gbos-localai "API settings copy into $f FAILED"
      fi
    done
    log -t gbos-localai "API settings copied for $c Android user(s) (provider host: $(sed -n 's#^BASE_URL=[a-z]*://\([^/:]*\).*#\1#p' "$S/api.conf" | head -n 1))" ;;
  esac
else
  rm -f /data/user_de/*/com.google.android.aicore/files/api.conf
  log -t gbos-localai "no API settings on this system (AI features will report not available)"
fi

# --- Optional: Magic Pointer patched to need only text queries (localai/patch_gpointer.py; the installer puts the file in $S).
# Same three steps as for AICore. Only bound if the system copy has exactly the size of the build the patch was made from.
GP="$S/gpointer.apk"
if [ -f "$GP" ]; then
  gb=0
  for a in /product/priv-app/ContextualCursorPrebuilt/*.apk; do
    [ -f "$a" ] || continue
    if [ "$(stat -c %s "$a")" != "$(stat -c %s "$GP")" ]; then
      log -t gbos-localai "Magic Pointer: system apk differs in size from the patched one, left alone"; continue
    fi
    if mount -o bind "$GP" "$a"; then gb=$((gb+1)); else log -t gbos-localai "bind over $a FAILED"; fi
  done
  if [ $gb -gt 0 ]; then
    for d in /data/app/*/com.google.android.desktop.gpointer.app-*; do
      [ -d "$d" ] || continue
      log -t gbos-localai "removing Play-updated Magic Pointer: $d"; rm -rf "$d"
    done
    for f in /data/system/package_cache/*/*ContextualCursorPrebuilt*; do
      [ -e "$f" ] || continue
      log -t gbos-localai "removing PackageManager cache entry: $f"; rm -f "$f"
    done
  fi
  log -t gbos-localai "patched Magic Pointer bound over $gb apk(s)"
fi

n=0
for d in /data/app/*/com.google.android.aicore-*; do
  [ -d "$d" ] || continue
  log -t gbos-localai "removing Play-updated AICore: $d"
  rm -rf "$d"; n=$((n+1))
done
c=0
for f in /data/system/package_cache/*/*AICorePrebuilt*; do
  [ -e "$f" ] || continue
  log -t gbos-localai "removing PackageManager cache entry: $f"
  rm -f "$f"; c=$((c+1))
done
log -t gbos-localai "prep done ($n updated copies removed, $c cache entries removed)"
