#!/usr/bin/env python3
"""Make a replacement-kernel .config for a Whiskey Lake laptop (i5-8365U, UHD 620).

  configure_whl.py RECOVERY_KERNEL.config OUT.config

Starts from the Googlebook recovery kernel's embedded config and applies the
overrides below, adapted from GBRUNCH's AMD replacement-kernel profile
(tools/build_amd_replacement_kernel.py). Run `make olddefconfig` afterwards.
"""
import re
import sys

OVERRIDES = {
    'LOCALVERSION': '"-gbos-whl"', 'LOCALVERSION_AUTO': 'n',
    # Gen9.5 graphics: xe.ko only supports Gen12+, so build i915.
    'DRM_I915': 'm', 'DRM_SIMPLEDRM': 'y', 'SYSFB_SIMPLEFB': 'y',
    # Let rebuilt modules use any export (GBRUNCH found the trimmed list too small).
    'TRIM_UNUSED_KSYMS': 'n', 'MODULE_SIG_PROTECT': 'n', 'MODULE_SIG_PROTECT_LIST': '""',
    # No Rust toolchain is pinned here, so use the C binder like GBRUNCH.
    'RUST': 'n', 'ANDROID_BINDER_IPC': 'y', 'ANDROID_BINDERFS': 'y',
    'ANDROID_BINDER_DEVICES': '"binder,hwbinder,vndbinder"', 'DMABUF_HEAPS_SYSTEM': 'y',
    # Smaller, faster build.
    'DEBUG_INFO_NONE': 'y', 'DEBUG_INFO': 'n', 'DEBUG_INFO_BTF': 'n',
    'DEBUG_INFO_BTF_MODULES': 'n', 'IKHEADERS': 'n',
    'DEBUG_INFO_DWARF4': 'n', 'DEBUG_INFO_DWARF5': 'n', 'DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT': 'n',
    # Boot-critical laptop hardware built in.
    'BLK_DEV_NVME': 'y', 'NVME_CORE': 'y', 'SATA_AHCI': 'y', 'ATA': 'y',
    'SCSI': 'y', 'BLK_DEV_SD': 'y',
    'USB_XHCI_HCD': 'y', 'USB_XHCI_PCI': 'y', 'USB_STORAGE': 'y', 'USB_UAS': 'y',
    'HID_GENERIC': 'y', 'USB_HID': 'y', 'HID_MULTITOUCH': 'y',
    'I2C_HID': 'y', 'I2C_HID_ACPI': 'y', 'I2C_DESIGNWARE_CORE': 'y', 'I2C_DESIGNWARE_PLATFORM': 'y',
    'PINCTRL_CANNONLAKE': 'y', 'KEYBOARD_ATKBD': 'y', 'MOUSE_PS2': 'y',
    'BLK_DEV_DM': 'y', 'DM_VERITY': 'y', 'EXT4_FS': 'y', 'EROFS_FS': 'y',
    # Intel Wi-Fi (the Latitude 5300 has a CNVi 9560, 8086:9df0).
    'CFG80211': 'm', 'MAC80211': 'm', 'WLAN_VENDOR_INTEL': 'y', 'IWLWIFI': 'm', 'IWLMVM': 'm',
    # Battery/AC: Google builds these as modules, which won't load on this kernel.
    'ACPI_BATTERY': 'y', 'ACPI_AC': 'y',
    # Touchpad: the I2C controllers (8086:9de8/9de9) are LPSS PCI devices. Without this the touchpad
    # is only its PS/2 fallback (no scrolling or gestures).
    'MFD_INTEL_LPSS': 'y', 'MFD_INTEL_LPSS_PCI': 'y',
    # Audio: legacy HDA + Realtek ALC3254 (ALC269 family) + HDMI, instead of Google's SOF modules.
    # Needs snd_intel_dspcfg.dsp_driver=1 on the cmdline (no internal DMIC this way).
    'SND_HDA_INTEL': 'y', 'SND_HDA_GENERIC': 'y', 'SND_HDA_CODEC_REALTEK': 'y', 'SND_HDA_CODEC_ALC269': 'y',
    'SND_HDA_CODEC_HDMI': 'y', 'SND_HDA_CODEC_HDMI_INTEL': 'y', 'SND_HDA_I915': 'y',
}

# These must come out exactly as requested after olddefconfig.
REQUIRED = ['DRM_I915', 'TRIM_UNUSED_KSYMS', 'MODULE_SIG_PROTECT', 'ANDROID_BINDER_IPC', 'BLK_DEV_NVME']


def parse(text):
    values = {}
    for line in text.splitlines():
        m = re.match(r'CONFIG_(\w+)=(.*)', line)
        if m:
            values[m.group(1)] = m.group(2)
            continue
        m = re.match(r'# CONFIG_(\w+) is not set', line)
        if m:
            values[m.group(1)] = 'n'
    return values


def render(values):
    return ''.join('# CONFIG_%s is not set\n' % k if v == 'n' else 'CONFIG_%s=%s\n' % (k, v)
                   for k, v in values.items())


def main():
    if sys.argv[1] == '--check':
        resolved = parse(open(sys.argv[2]).read())
        bad = {k: resolved.get(k, 'n') for k in REQUIRED if resolved.get(k, 'n') != OVERRIDES[k]}
        missed = {k: resolved.get(k, 'n') for k, v in OVERRIDES.items() if resolved.get(k, 'n') != v}
        print('not resolved as requested:', missed or 'none')
        sys.exit(1 if bad else 0)
    values = parse(open(sys.argv[1]).read())
    values.update(OVERRIDES)
    open(sys.argv[2], 'w').write(render(values))


if __name__ == '__main__':
    main()
