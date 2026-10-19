#!/usr/bin/env python3
"""Surface Laptop 7 (Intel, Lunar Lake): SoundWire audio fixes for sound/soc/sdw_utils on 6.18. Run in gbos-kbuild:
    python3 kernel/isa_emu_patch/sdw_sl7.py [KERNEL_SRC]        (default /build/src)
The rebuilt modules are snd-soc-sdw-utils.ko and snd-soc-sof-sdw.ko (no kernel change needed). Idempotent; an anchor that is not
found exactly once aborts without touching the file.

The laptop has an RT721 jack codec (link 3) and RT1320 amp(s) (link 0); the BIOS declares TWO RT1320 but only one exists.
 1. soc_sdw_rt_amp.c: asoc_sdw_rt_amp_exit() put_device()s the amp devices without clearing the pointers; when it runs again for the
    same card the refcount is dropped twice ("refcount_t: saturated; leaking memory", then "refcount_t: underflow; use-after-free"
    in dmesg). Upstream master clears them.
 2. soc_sdw_utils.c: DAI link names only get the DAI-type suffix (SimpleJack/SmartAmp/...) when one link carries several DAIs, but
    sof_sdw_get_tplg_files() maps links to the sof-sdca-*.tplg function topologies by that suffix: without it no analog PCM exists.
 3. soc_sdw_utils.c: skip BIOS-declared peripherals that never attached (the ghost RT1320); keep num_devs, which sof_sdw sized
    codec_conf by, in step (else WARN_ON(codec_conf != card->codec_conf + card->num_configs)).
Not covered: the internal microphone array (RT1320 DMIC DAI + cfg-mics, see nierdal's patch in linux-surface #1710)."""
import sys

root = (sys.argv[1] if len(sys.argv) > 1 else '/build/src').rstrip('/')
AMP = 'sound/soc/sdw_utils/soc_sdw_rt_amp.c'
UTL = 'sound/soc/sdw_utils/soc_sdw_utils.c'


def edit(path, old, new, label):
    p = root + '/' + path
    s = open(p).read()
    if new in s:
        print('already applied: ' + label)
        return
    if s.count(old) != 1:
        sys.exit('ANCHOR NOT FOUND exactly once for: ' + label + ' in ' + path)
    open(p, 'w').write(s.replace(old, new))
    print('applied: ' + label)


edit(AMP,
     "\tif (ctx->amp_dev1) {\n\t\tdevice_remove_software_node(ctx->amp_dev1);\n\t\tput_device(ctx->amp_dev1);\n\t}\n\n"
     "\tif (ctx->amp_dev2) {\n\t\tdevice_remove_software_node(ctx->amp_dev2);\n\t\tput_device(ctx->amp_dev2);\n\t}\n",
     "\tif (ctx->amp_dev1) {\n\t\tdevice_remove_software_node(ctx->amp_dev1);\n\t\tput_device(ctx->amp_dev1);\n\t\tctx->amp_dev1 = NULL;\n\t}\n\n"
     "\tif (ctx->amp_dev2) {\n\t\tdevice_remove_software_node(ctx->amp_dev2);\n\t\tput_device(ctx->amp_dev2);\n\t\tctx->amp_dev2 = NULL;\n\t}\n",
     'rt_amp_exit clears the amp_dev pointers')

edit(UTL,
     "\t\tctx->append_dai_type |= (num_link_dailinks > 1);\n",
     "\t\tctx->append_dai_type |= (num_link_dailinks > 0);\n",
     'always append the DAI type to link names')

edit(UTL,
     "int asoc_sdw_parse_sdw_endpoints(struct snd_soc_card *card,\n",
     "/* gbOS: BIOS-declared SoundWire peripheral that never enumerated (ghost amp on Surface Laptop 7 Intel) */\n"
     "static bool asoc_sdw_peripheral_unattached(const char *name)\n"
     "{\n"
     "\tstruct device *sdw_dev = bus_find_device_by_name(&sdw_bus_type, NULL, name);\n"
     "\tstruct sdw_slave *slave;\n"
     "\tbool unattached;\n"
     "\n"
     "\tif (!sdw_dev)\n"
     "\t\treturn false;\n"
     "\n"
     "\tslave = dev_to_sdw_dev(sdw_dev);\n"
     "\tunattached = slave->status == SDW_SLAVE_UNATTACHED;\n"
     "\tput_device(sdw_dev);\n"
     "\n"
     "\treturn unattached;\n"
     "}\n"
     "\n"
     "int asoc_sdw_parse_sdw_endpoints(struct snd_soc_card *card,\n",
     'helper asoc_sdw_peripheral_unattached')

edit(UTL,
     "\t\t\tcodec_name = asoc_sdw_get_codec_name(dev, codec_info, adr_link, i);\n"
     "\t\t\tif (!codec_name)\n"
     "\t\t\t\treturn -ENOMEM;\n",
     "\t\t\tcodec_name = asoc_sdw_get_codec_name(dev, codec_info, adr_link, i);\n"
     "\t\t\tif (!codec_name)\n"
     "\t\t\t\treturn -ENOMEM;\n"
     "\n"
     "\t\t\tif (asoc_sdw_peripheral_unattached(codec_name)) {\n"
     "\t\t\t\tdev_info(dev, \"gbos: %s is declared by the BIOS but not attached, skipping it\\n\",\n"
     "\t\t\t\t\t codec_name);\n"
     "\t\t\t\t(*num_devs)--; /* keep the codec_conf count in step with what is really added */\n"
     "\t\t\t\tcontinue;\n"
     "\t\t\t}\n",
     'skip unattached peripherals when building DAI links')
print('OK')
