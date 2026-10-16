#!/system/bin/sh
# aidiag.sh N: AI-feature diagnostics (Magic Pointer "Gemini is not available", AICore). Run by the
# gbos_aidiag service from gbos.rc. Writes logs/boot-N/ai-1.txt (90 s after boot) and ai-2.txt (4 min).
#
# What it answers:
#  - does AICore's uid (10107) resolve Google hosts, as the Gemini/Private-Compute uid (as.oss, 10118) does?
#    (logcat: AICore "Unable to resolve host ondevicesafety-pa.googleapis.com" while as.oss is online)
#  - does AICore hold INTERNET / is its uid blocked by connectivity or the PCC sandbox?
#  - which AI system features, services and Phenotype flags are present?
N=$1
L=/postinstall/gbos/logs/boot-$N
H=ondevicesafety-pa.googleapis.com

run() {
  T=$1
  O=$L/ai-$T.txt
  {
    echo "== date"; date
    echo "== AI features"; pm list features | grep -i -E 'aicore|npu|gemini|ondevice|genai|pointer|intelligence'
    echo "== processes"; ps -A -o USER,PID,NAME | grep -i -E 'aicore|as\.oss|com.google.android.as|gpointer|bard|quicksearch'

    # DNS and ICMP as each uid, through the same resolver path the apps use. Services are started
    # here (not inline) because only init can switch uid and keep the right SELinux context.
    for u in 10107 10118 10119 2000; do : > /dev/aidns_$u.txt; chmod 666 /dev/aidns_$u.txt; done
    for u in 10107 10118 10119 2000; do start gbos_aidns_$u; done
    sleep 15
    for u in 10107 10118 10119 2000; do echo "== ping $H as uid $u"; cat /dev/aidns_$u.txt; done
    echo "== resolver, as root"; ping -c 1 -W 5 $H

    echo "== packages"
    for p in com.google.android.aicore com.google.android.as com.google.android.as.oss \
             com.google.android.desktop.gpointer.app com.google.android.apps.bard \
             com.google.android.googlequicksearchbox com.google.android.apps.pixel.psi; do
      echo "-- $p"
      dumpsys package $p | grep -E 'userId=|versionName|versionCode|lastUpdateTime|gids=|android.permission.INTERNET|installed=|enabled=|stopped=|flags=|privateFlags=|Package \[' | head -30
    done

    echo "== connectivity (uid 10107 / 1010107 / PCC)"
    dumpsys connectivity | grep -i -E '10107|1010107|pcc|blocked|restricted' | head -60
    echo "== netpolicy"
    dumpsys netpolicy | grep -i -E '10107|1010107|restrict|blocked|firewall' | head -40
    echo "== bpf uid permission maps"
    ls -l /sys/fs/bpf/netd_shared 2>&1 | head -30

    echo "== PCC sandbox"
    dumpsys pcc_sandbox_manager 2>&1 | head -80
    dumpsys private_compute 2>&1 | head -40
    service list | grep -i -E 'pcc|privatecompute|intelligence|aicore|npu'

    echo "== on-device intelligence"
    dumpsys on_device_intelligence 2>&1 | head -80
    dumpsys ondeviceintelligence 2>&1 | head -80

    echo "== AICore / as.oss services"
    dumpsys activity services com.google.android.aicore | head -80
    dumpsys activity services com.google.android.as.oss | head -80

    echo "== system properties"
    getprop | grep -i -E 'aicore|gemini|npu|ai\.|ml\.|model|ro.product|ro.build.fingerprint|persist.device_config'

    echo "== network"
    ip addr show wlan0; ip route; getprop | grep -i dns
    echo "== cpu"
    grep -m1 flags /proc/cpuinfo
    echo "== listening"
    dumpsys wifi | grep -i -E 'mNetworkInfo|validated|Wifi is' | head -5
  } > $O 2>&1
}

sleep 90
run 1
sleep 150
run 2
