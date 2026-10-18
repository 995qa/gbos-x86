#!/bin/sh
# HP ENVY Laptop 13-aq0xxx (board 85E2, PCI/codec SSID 103c:85e2, Realtek ALC285): only the speaker pin 0x17 is
# declared by the BIOS (0x90170180); the second speaker pair on 0x14 is 0x411111f0 (not connected), so just
# part of the four speakers gets signal ("sounds like cheeks"). alc269.c has no quirk for this SSID; only the
# HP vendor wildcard (ALC269_FIXUP_HP_MUTE_LED) applies.
# Same pin situation as the HP Spectre x360 15-df0xxx (103c:8519, ALC285_FIXUP_HP_SPECTRE_X360): declare 0x14 as
# an internal fixed speaker (0x90170110) and force 0x17 onto DAC 0x02 so both pairs share one stream / volume.
# The new fixup chains to ALC269_FIXUP_HP_MUTE_LED so the vendor wildcard's mute-LED probing is not lost.
# Keyed on the exact SSID, no other machine is affected. Built in (CONFIG_SND_HDA_CODEC_ALC269=y): kernel relink.
# Idempotent.
set -e
cd /build/src/sound/hda/codecs/realtek
grep -q 'ALC285_FIXUP_HP_ENVY13_AQ' alc269.c && { echo already; exit 0; }
python3 - alc269.c <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p).read()

def sub(old, new):
    global s
    assert s.count(old) == 1, "anchor mismatch: " + old
    s = s.replace(old, new)

# 1. enum
sub("\tALC285_FIXUP_HP_SPECTRE_X360,\n\tALC287_FIXUP_IDEAPAD_BASS_SPK_AMP,\n",
    "\tALC285_FIXUP_HP_SPECTRE_X360,\n\tALC285_FIXUP_HP_ENVY13_AQ,\n\tALC287_FIXUP_IDEAPAD_BASS_SPK_AMP,\n")

# 2. fixup entry (after the Spectre x360 one)
sub("""	[ALC285_FIXUP_HP_SPECTRE_X360] = {
		.type = HDA_FIXUP_FUNC,
		.v.func = alc285_fixup_hp_spectre_x360,
	},
""", """	[ALC285_FIXUP_HP_SPECTRE_X360] = {
		.type = HDA_FIXUP_FUNC,
		.v.func = alc285_fixup_hp_spectre_x360,
	},
	/* gbos: HP ENVY 13-aq0xxx, kernel/isa_emu_patch/alc269_hp_envy13_aq.sh */
	[ALC285_FIXUP_HP_ENVY13_AQ] = {
		.type = HDA_FIXUP_FUNC,
		.v.func = alc285_fixup_hp_spectre_x360,
		.chained = true,
		.chain_id = ALC269_FIXUP_HP_MUTE_LED,
	},
""")

# 3. quirk, sorted by SSID (after 0x85de)
sub("""	SND_PCI_QUIRK(0x103c, 0x85de, "HP Envy x360 13-ar0xxx", ALC285_FIXUP_HP_ENVY_X360),
""", """	SND_PCI_QUIRK(0x103c, 0x85de, "HP Envy x360 13-ar0xxx", ALC285_FIXUP_HP_ENVY_X360),
	SND_PCI_QUIRK(0x103c, 0x85e2, "HP ENVY Laptop 13-aq0xxx", ALC285_FIXUP_HP_ENVY13_AQ),
""")

# 4. model name for the "model=" option
sub("""	{.id = ALC285_FIXUP_HP_SPECTRE_X360, .name = "alc285-hp-spectre-x360"},
""", """	{.id = ALC285_FIXUP_HP_SPECTRE_X360, .name = "alc285-hp-spectre-x360"},
	{.id = ALC285_FIXUP_HP_ENVY13_AQ, .name = "alc285-hp-envy13-aq"},
""")
open(p, 'w').write(s)
PYEOF
grep -n 'ENVY13_AQ\|envy13-aq' alc269.c
