#!/system/bin/sh
# gbOS86 AI diagnostics (init service gbos_localaidiag, root): state of the swapped-in AICore and Magic Pointer packages,
# the API settings (whether present, the provider host and model, NEVER the key) and our own logs, 40 s and 120 s after boot,
# to logs/boot-N/localai.txt. $1 = boot number.
OUT=/postinstall/gbos/logs/boot-$1/localai.txt
snap() {
  echo "==== $1 at uptime $(cut -d' ' -f1 /proc/uptime)s"
  echo "-- pm path"; pm path com.google.android.aicore 2>&1
  echo "-- package state"
  dumpsys package com.google.android.aicore 2>&1 | grep -E 'versionCode|versionName|codePath|flags=\[|signatures=|Package \[|enabled=|installed=' | head -12
  echo "-- services bound/running"
  dumpsys activity services com.google.android.aicore 2>&1 | head -30
  echo "-- API settings (key never shown)"
  for f in /data/gbos-localai/api.conf /data/user_de/*/com.google.android.aicore/files/api.conf; do
    [ -f "$f" ] && echo "$f: $(grep -E '^(BASE_URL|MODEL|MAX_PER_HOUR)=' "$f" | tr '\n' ' ') key: $(grep -q '^API_KEY=.' "$f" && echo set || echo MISSING)"
  done
  echo "-- gPointer (Magic Pointer) package"; pm path com.google.android.desktop.gpointer.app 2>&1
  dumpsys package com.google.android.desktop.gpointer.app 2>&1 | grep -E 'Package \[|versionCode|codePath|flags=\[|signatures=' | head -8
  echo "-- gPointer / RobinKit / package-manager lines"
  logcat -d -v threadtime 2>&1 | grep -E 'RobinKit|gPointer/(MainActivity|MainActivityGa|Private|AiCoreServiceD)|PackageManager.*(gpointer|ContextualCursor)|INSTALL_PARSE|NO_CERTIFICATES' | tail -40
  echo "-- processes"; ps -A 2>&1 | grep -E 'aicore|gpointer|contextualcursor'
  echo "-- logcat (our service)"
  logcat -d -v threadtime -s gbos-localai:V 2>&1 | tail -80
}
sleep 40; snap "40 s" >> "$OUT" 2>&1
sleep 80; snap "120 s" >> "$OUT" 2>&1
