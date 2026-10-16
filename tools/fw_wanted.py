#!/usr/bin/env python3
"""List the linux-firmware files the shipped kernel modules ask for (MODULE_FIRMWARE), resolved against linux-firmware.

  fw_wanted.py MODULES_DIR ALL_FILES.txt WHENCE [--unresolved]

MODULES_DIR   usb/modules (any tree with *.ko in it); the modinfo "firmware=" strings are read straight from the ELF files.
ALL_FILES.txt `git ls-tree -r --name-only HEAD` of linux-firmware.
WHENCE        linux-firmware's WHENCE ("Link: a -> b" entries define names that are not in the git tree).
Prints one path (relative to the firmware root, as in the git tree) per line. With --unresolved it prints the names
nothing in the tree could satisfy instead (for the log).

Resolution of one requested name:
  exact file, or name.zst / name.xz        -> that file
  a WHENCE Link                            -> the link's target (and the link name is created by fetch_firmware.sh)
  a wildcard (cirrus/cs35l41-*.bin)        -> every match
  iwlwifi-FAMILY-N.ucode                   -> the driver asks for API N and falls back to older ones, so the two newest files
                                              of that family with API <= N (a "c" API, e.g. c99, only compares with other "c" ones)
"""
import fnmatch, os, re, sys

mods, allf_path, whence = sys.argv[1:4]
unresolved_mode = '--unresolved' in sys.argv

tree = set(l for l in open(allf_path).read().split('\n') if l)
links = {}
for l in open(whence, errors='replace'):
    m = re.match(r'Link: (\S+) -> (\S+)', l)
    if m:
        a, t = m.groups()
        links[a] = os.path.normpath(os.path.join(os.path.dirname(a), t))

req = set()
for d, _, fs in os.walk(mods):
    for f in fs:
        if f.endswith('.ko'):
            b = open(os.path.join(d, f), 'rb').read()
            for m in re.finditer(rb'(?:^|\0)firmware=([^\0]+)', b):
                req.add(m.group(1).decode())

# iwlwifi lives in intel/iwlwifi/ in the tree but is requested from the root.
def in_tree(n):
    for c in (n, n + '.zst', n + '.xz', 'intel/iwlwifi/' + n):
        if c in tree:
            return c
    return None

iwl = {}
for p in tree:
    m = re.match(r'intel/iwlwifi/(iwlwifi-.+?)-(c?)(\d+)\.ucode$', p)
    if m:
        iwl.setdefault((m.group(1), m.group(2)), []).append((int(m.group(3)), p))

out, bad = set(), []
for n in sorted(req):
    if '*' in n or '%' in n:
        hit = [p for p in tree if fnmatch.fnmatch(p, n)]
        out.update(hit)
        if not hit:
            bad.append(n)
        continue
    p = in_tree(n)
    if p:
        out.add(p)
        continue
    if n in links and (links[n] in tree or in_tree(links[n])):
        out.add(in_tree(links[n]) or links[n])
        continue
    m = re.match(r'(iwlwifi-.+?)-(c?)(\d+)\.ucode$', n)
    if m:
        cands = sorted(c for c in iwl.get((m.group(1), m.group(2)), []) if c[0] <= int(m.group(3)))
        if cands:
            out.update(p for _, p in cands[-2:])
            continue
    bad.append(n)

if unresolved_mode:
    print('\n'.join(bad))
else:
    print('\n'.join(sorted(out)))
