"""Laptops people have tried gbOS86 on (reports from the community and the maintainer). One list, used by the Hardware
page, the docs and (by hand) README.md. Add a row per report; keep it to what the reporter actually said.

status: works | partial | pending | no
"""
from html import escape

UPDATED = '2026-10-18'

STATUS = {'works': 'Works', 'partial': 'Partly works', 'pending': 'Fix pending', 'no': 'Does not work'}

LAPTOPS = [
    dict(name='Dell Latitude 5300', cpu='Core i5-8365U (Whiskey Lake), UHD 620, 16 GB', status='works',
         works='Everything tested: boot, sign-in, Play Store, Wi-Fi, Bluetooth, sound, touchpad with gestures, brightness, battery, install to the internal NVMe',
         broken='Suspend and resume (not supported anywhere yet)',
         notes='The maintainer\'s machine; the project was built on it.'),
    dict(name='Acer Aspire Lite AL15-52', cpu='Core i5-1235U, 8 GB, 512 GB NVMe', status='works',
         works='Wi-Fi, display, touchpad, keyboard, sound, brightness, camera, Bluetooth',
         broken='',
         notes='Reported on kernel #32/#33 in live mode. Needed two firmware fixes (Realtek Wi-Fi firmware, and the Intel AX201 Bluetooth firmware name '
               '<code>ibt-0040-1050.sfi</code>), both in firmware release v34 and later. A stick made before that needs a rebuild, or an Update from a fresh stick.'),
    dict(name='Lenovo ThinkPad T470', cpu='Intel 7th gen (Kaby Lake)', status='works',
         works='Reported as working with no setup at all',
         broken='',
         notes='Short report, no details on individual devices yet.'),
    dict(name='Intel NUC8BEH (mini PC)', cpu='Core i3-8109U (Coffee Lake), 8 GB DDR4, 512 GB SATA M.2', status='works',
         works='Wi-Fi, Bluetooth, display and brightness (external monitor), keyboard (external, USB receiver), all USB ports',
         broken='',
         notes='Live USB on kernel #32. Sound was not tested; no touchpad, webcam or built-in screen to test. The SSD is SATA, and the installer only targets NVMe or eMMC, so this one runs live from the stick but cannot install.'),
    dict(name='HP OmniBook 7', cpu='Core Ultra 5 225U, 16 GB LPDDR5, 512 GB NVMe', status='partial',
         works='Touchpad, keyboard, brightness, display (live USB)',
         broken='Wi-Fi (Intel Wi-Fi 7 BE201)',
         notes='Sound, webcam and Bluetooth were not tested. A very new platform: Wi-Fi has no fix yet.'),
    dict(name='Dell XPS 16 (2026)', cpu='Intel Core Ultra (details not given)', status='partial',
         works='Boots and runs',
         broken='Screen refresh rate, Wi-Fi, camera',
         notes='The reporter says a Linux kernel option fixes the screen on this model. <code>MODOPTS</code> in <code>gbos.cfg</code> can now set driver options, so it can be tried without a rebuild. '
               'Wi-Fi and camera are open; a MIPI camera needs more than a driver.'),
    dict(name='Framework Laptop 13 Pro', cpu='Core Ultra 5 325 (Panther Lake), 16 GB, 1 TB NVMe', status='pending',
         works='Boots; black screen after choosing live boot on the reporter\'s stick',
         broken='Display on sticks built before firmware v35',
         notes='Cause found: the <code>xe</code> graphics driver could not load its Panther Lake GuC firmware. Firmware release v35 includes it; a patch zip exists for older sticks. '
               'Waiting for the reporter to confirm.'),
    dict(name='Microsoft Surface Laptop 7 (Intel, for Business)', cpu='Core Ultra 7 266V (Lunar Lake), 16 GB, 1 TB', status='pending',
         works='Boots; black screen after choosing live boot on the reporter\'s stick',
         broken='Display on sticks built before firmware v35. Built-in keyboard, Wi-Fi and sound are not known to work (no logs yet)',
         notes='Cause found: the <code>xe</code> graphics driver could not load its Lunar Lake GuC firmware. Firmware release v35 includes it; a patch zip exists for older sticks. '
               'The touchpad is detected, but the built-in keyboard does not appear as an input device. Surface-specific input drivers may be needed; waiting for a log from a working screen.'),
    dict(name='HP 14-ne0013dx', cpu='Intel (details not given)', status='no',
         works='',
         broken='Did not work for the reporter',
         notes='No logs yet. Post <code>gbos/logs/boot-N/hwdetect.txt</code> from the stick and we can look.'),
]


def table_html():
    """Cards, not a table: five text columns do not fit next to each other (name column hogged the width)."""
    cards = []
    for l in LAPTOPS:
        rows = ''
        if l['works']:
            rows += '<dt>Works</dt><dd>%s</dd>' % escape(l['works'])
        if l['broken']:
            rows += '<dt>Not working</dt><dd>%s</dd>' % escape(l['broken'])
        cards.append('<article class="lap"><div class="lap-head"><div><h3>%s</h3><p class="cpu">%s</p></div><span class="badge %s">%s</span></div>'
                     '<dl>%s</dl><p class="note">%s</p></article>' % (escape(l['name']), escape(l['cpu']), l['status'], STATUS[l['status']], rows, l['notes']))
    return ('<div class="laptops">%s</div>'
            '<p class="mut">Based on reports from people who tried it, last updated %s. Results change as fixes land: a card says what was reported, not what the latest build can do. '
            'Post yours in <a href="/forum/c/hardware">Hardware Compatibility</a> with your <code>hwdetect.txt</code>.</p>') % ('\n'.join(cards), UPDATED)


def summary():
    n = {k: sum(1 for l in LAPTOPS if l['status'] == k) for k in STATUS}
    return '%d laptops tried: %d work, %d partly, %d with a fix pending, %d not working' % (len(LAPTOPS), n['works'], n['partial'], n['pending'], n['no'])
