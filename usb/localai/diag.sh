#!/system/bin/sh
# gbOS86 local AI diagnostics (init service gbos_localaidiag, root): state of the swapped-in AICore package, the model
# server and our own logs, 60 s and 300 s after boot, to logs/boot-N/localai.txt. $1 = boot number.
OUT=/postinstall/gbos/logs/boot-$1/localai.txt
snap() {
  echo "==== $1 at uptime $(cut -d' ' -f1 /proc/uptime)s"
  echo "-- pm path"; pm path com.google.android.aicore 2>&1
  echo "-- package state"
  dumpsys package com.google.android.aicore 2>&1 | grep -E 'versionCode|versionName|codePath|resourcePath|flags=|privateFlags|userId=|firstInstallTime|lastUpdateTime|signatures|Signing|enabled=|installed=|Package \[|Hidden system|Updated' | head -40
  echo "-- services bound/running"
  dumpsys activity services com.google.android.aicore 2>&1 | head -40
  echo "-- processes"; ps -A 2>&1 | grep -E 'llama|aicore|gpointer|contextualcursor' 
  echo "-- gPointer (Magic Pointer) package"; pm path com.google.android.desktop.gpointer.app 2>&1
  dumpsys package com.google.android.desktop.gpointer.app 2>&1 | grep -E 'Package \[|versionCode|codePath|flags=\[|signatures=' | head -8
  echo "-- gPointer / RobinKit / package-manager lines"
  logcat -d -v threadtime 2>&1 | grep -E 'RobinKit|gPointer/(MainActivity|MainActivityGa|Private|AiCoreServiceD)|PackageManager.*(gpointer|ContextualCursor)|INSTALL_PARSE|NO_CERTIFICATES' | tail -40
  echo "-- memory"; head -3 /proc/meminfo
  echo "-- logcat (ours + gPointer's AICore use)"
  logcat -d -v threadtime -s gbos-localai:V gbos-llama:V 2>&1 | tail -80
  logcat -d -v threadtime 2>&1 | grep -E 'gPointer/(PrivateInference|AiCoreServiceDelegate)|AiCoreClient|AiCoreException' | tail -40
}
sleep 60; snap "60 s" >> "$OUT" 2>&1
sleep 240; snap "300 s" >> "$OUT" 2>&1
