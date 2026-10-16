#!/bin/sh
# Fetch the firmware gbOS86 ships for generic Intel gen6+ laptops from kernel.org's linux-firmware and trim it
# to the chips the kernel #31 drivers cover. Output: usb/firmware/ (merged; existing files are kept).
#   tools/fetch_firmware.sh [WORKDIR]      (WORKDIR defaults to a temp dir; the clone is ~1.5 GB, the result ~100 MB)
set -e
REPO=$(cd "$(dirname "$0")/.." && pwd)
W=${1:-$(mktemp -d)}
OUT=$REPO/usb/firmware
[ -d $W/fw/.git ] || git clone --depth 1 --no-checkout https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git $W/fw
cd $W/fw
git ls-tree -r --name-only HEAD > $W/all.txt
git rev-parse HEAD > $W/commit.txt
# newest N files per family (sorted by name, so the highest API number wins); iwlwifi falls back to older ones.
g() { grep "$@" $W/all.txt || true; }
{
  # Intel Wi-Fi: keep the two newest API versions of every chip family (ucode + pnvm)
  g -E '^intel/iwlwifi/' | sed -E 's#^(.*/)(iwlwifi-[^.]*[a-z0-9])-([0-9]+)\.(ucode)$#\1\2 \3 &#' | awk 'NF==3{fam=$1; n[fam]++; f[fam,n[fam]]=$3; v[fam,n[fam]]=$2} END{for(k in n){ # keep last two by numeric order
      m=n[k]; for(i=1;i<=m;i++) for(j=i+1;j<=m;j++) if (v[k,j]+0 < v[k,i]+0) {t=v[k,i];v[k,i]=v[k,j];v[k,j]=t;t=f[k,i];f[k,i]=f[k,j];f[k,j]=t}
      for(i=(m>2?m-1:1);i<=m;i++) print f[k,i]}}'
  g -E '^intel/iwlwifi/.*\.pnvm$'
  # Intel Bluetooth
  g -E '^intel/ibt-'
  # i915 GuC/HuC/DMC (skl..mtl)
  g -E '^i915/'
  # SOF audio firmware + topologies
  g -E '^intel/(sof|sof-ipc4|sof-ace-tplg|sof-tplg)'
  # Realtek Wi-Fi/BT
  g -E '^rtw88/(rtw8822b|rtw8822c|rtw8723d|rtw8821c)_'
  g -E '^rtw89/rtw89(52a|52b|52c|51b|22a)?_?(fw|8852a|8852b|8852c|8851b|8922a)'
  g -E '^rtl_bt/'
  # MediaTek mt7921/22/25 Wi-Fi + BT
  g -E '^mediatek/(WIFI_|BT_RAM_CODE_MT79|mt7925/|mt7927/)'
  # Qualcomm: ath10k QCA6174/QCA9377, ath11k QCA6390/WCN6855, QCA BT
  g -E '^ath10k/(QCA6174|QCA9377)/'
  g -E '^ath11k/(QCA6390|WCN6855)/'
  g -E '^qca/(rampatch_usb|nvm_usb|rampatch_0|nvm_0|htbtfw|crbtfw|crnv|QCA|rampatch_|nvm_)'
  # Broadcom Bluetooth + brcmfmac PCIe
  g -E '^brcm/(BCM|brcmfmac4(3602|350|356|358|3455|371))'
  # Cirrus amps found on some laptops
  g -E '^cirrus/cs35l(41|56)-[^/]*$'
  # Intel sensor hub (ISH) firmware is board-specific and loaded by the BIOS; skipped.
} | grep -v ' ' | sort -u > $W/want.txt
tr '\n' '\0' < $W/want.txt | xargs -0 git checkout HEAD --
mkdir -p $OUT
tar -cf - -T $W/want.txt | tar -xf - -C $OUT
# This kernel's iwlwifi requests "iwlwifi-*.ucode" from the firmware root (no intel/iwlwifi/ prefix).
if [ -d $OUT/intel/iwlwifi ]; then mv $OUT/intel/iwlwifi/* $OUT/ && rmdir $OUT/intel/iwlwifi; fi
# keep the symlink-targets: linux-firmware uses symlinks (e.g. in rtw89, intel/sof); FAT can't, so dereference.
find $OUT -type l | while read l; do t=$(readlink -f "$l"); [ -f "$t" ] && { rm "$l"; cp "$t" "$l"; } || rm "$l"; done
echo "linux-firmware commit: $(cat $W/commit.txt)" > $OUT/FIRMWARE_SOURCE.txt
du -sh $OUT

# Intel SOF audio firmware + topologies come from a separate repo (not in linux-firmware).
SOFV=2026.09.2
if [ ! -d $W/sof-bin-$SOFV ]; then
  curl -fL -o $W/sof.tgz https://github.com/thesofproject/sof-bin/releases/download/v$SOFV/sof-bin-$SOFV.tar.gz
  tar -xzf $W/sof.tgz -C $W
fi
mkdir -p $OUT/intel
for d in sof sof-ipc4 sof-ipc4-lib sof-ipc4-tplg sof-tplg; do
  rm -rf $OUT/intel/$d; cp -RL $W/sof-bin-$SOFV/$d $OUT/intel/$d   # -L: FAT has no symlinks
  find $OUT/intel/$d -name '*.ldc' -delete                            # debug dictionaries, not needed
done
cp $W/sof-bin-$SOFV/LICENCE.Intel $OUT/intel/LICENCE.sof-bin
echo "sof-bin: v$SOFV" >> $OUT/FIRMWARE_SOURCE.txt
du -sh $OUT
