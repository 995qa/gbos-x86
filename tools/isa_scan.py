#!/usr/bin/env python3
"""Scan x86 ELF files under a directory for instructions older Intel CPUs (Haswell, Whiskey Lake) lack.

  isa_scan.py ROOT LABEL OUT.json

Disassembles every x86 ELF with objdump and counts instructions by the CPU feature they need.
Haswell has SSE4.2, AVX, AVX2, FMA, F16C, BMI1/2, LZCNT, MOVBE, AES-NI and 128-bit PCLMULQDQ;
anything below is newer.
"""
import json, os, re, subprocess, sys
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor

OBJDUMP = '/usr/bin/objdump'

FEATURES = [
    ('GFNI', r'v?gf2p8(affineqb|affineinvqb|mulb)'),
    ('SHA-NI', r'sha(1rnds4|1nexte|1msg1|1msg2|256rnds2|256msg1|256msg2)'),
    ('SHA512/SM3/SM4', r'v(sha512\w*|sm3\w*|sm4\w*)'),
    ('AVX-VNNI', r'(\{vex\}\s*)?vpdp(busd|busds|wssd|wssds)'),
    ('AVX-VNNI-INT8/16', r'vpdp(bssd|bssds|bsud|bsuds|buud|buuds|wsud|wsuds|wusd|wusds|wuud|wuuds)'),
    ('AVX-IFMA', r'vpmadd52(l|h)uq'),
    ('AVX-NE-CONVERT', r'v(bcstnebf162ps|bcstnesh2ps|cvtneebf162ps|cvtneeph2ps|cvtneobf162ps|cvtneoph2ps|cvtneps2bf16)'),
    ('ADX', r'(adcx|adox)[lq]?'),
    ('RDSEED', r'rdseed[wlq]?'),
    ('RDPID', r'rdpid[lq]?'),
    ('CLFLUSHOPT', r'clflushopt'),
    ('CLWB', r'clwb'),
    ('CLDEMOTE', r'cldemote'),
    ('MOVDIRI', r'movdiri[lq]?|movdir64b'),
    ('SERIALIZE/HRESET', r'serialize|hreset'),
    ('WAITPKG', r'umwait|umonitor|tpause'),
    ('XSAVEC/XSAVES', r'xsavec(64)?|xsaves(64)?|xrstors(64)?'),
    ('CMPCCXADD', r'cmp\w+xadd'),
    ('PREFETCHI', r'prefetchit[01]'),
    ('AMX', r'tile\w+|tdp\w+'),
]
FEATURE_RE = [(n, re.compile(r'^(' + p + r')\b')) for n, p in FEATURES]
YMM_ONLY = [  # instructions Haswell has only in 128-bit form; 256/512-bit forms are newer
    ('VAES (256/512-bit)', re.compile(r'^vaes(enc|enclast|dec|declast)\b')),
    ('VPCLMULQDQ (256/512-bit)', re.compile(r'^vpclmulqdq\b')),
]
# Whiskey Lake (i5-8365U) adds these over Haswell
WHISKEY_LAKE_HAS = {'ADX', 'RDSEED', 'CLFLUSHOPT', 'XSAVEC/XSAVES'}
AVX512 = re.compile(r'%zmm\d|%k[1-7]\b|\{%k[0-7]\}|\{1to\d+\}')
LINE = re.compile(r'^\s*[0-9a-f]+:\s+(\S+)\s*(.*)$')


def is_x86_elf(path):
    try:
        with open(path, 'rb') as f:
            h = f.read(20)
    except OSError:
        return False
    return h[:4] == b'\x7fELF' and h[18:20] in (b'\x3e\x00', b'\x03\x00')  # x86-64, i386


def scan(path):
    counts = Counter()
    total = 0
    try:
        out = subprocess.run([OBJDUMP, '-d', '--no-show-raw-insn', path],
                             capture_output=True, text=True, errors='replace', timeout=900).stdout
    except subprocess.TimeoutExpired:
        return path, None, 0
    for line in out.splitlines():
        m = LINE.match(line)
        if not m:
            continue
        total += 1
        mn, ops = m.group(1), m.group(2)
        if mn.startswith('{'):  # e.g. "{vex}" prefix printed as its own token
            mn = ops.split(None, 1)[0] if ops else mn
        if AVX512.search(ops):
            counts['AVX-512'] += 1
            continue
        for name, rx in FEATURE_RE:
            if rx.match(mn):
                counts[name] += 1
                break
        else:
            for name, rx in YMM_ONLY:
                if rx.match(mn) and ('%ymm' in ops or '%zmm' in ops):
                    counts[name] += 1
    return path, dict(counts), total


def main():
    root, label, out_json = sys.argv[1:4]
    files = []
    for d, _, names in os.walk(root):
        for n in names:
            p = os.path.join(d, n)
            if not os.path.islink(p) and is_x86_elf(p):
                files.append(p)
    totals = Counter()
    file_hits = defaultdict(dict)
    instr_total = 0
    failed = []
    with ProcessPoolExecutor(max_workers=os.cpu_count()) as ex:
        for path, counts, n in ex.map(scan, files, chunksize=4):
            if counts is None:
                failed.append(os.path.relpath(path, root))
                continue
            instr_total += n
            for k, v in counts.items():
                totals[k] += v
                file_hits[k][os.path.relpath(path, root)] = v
    result = {
        'label': label,
        'elf_files': len(files),
        'instructions': instr_total,
        'timed_out': failed,
        'totals': dict(totals.most_common()),
        'files_per_feature': {k: len(v) for k, v in file_hits.items()},
        'top_files': {k: sorted(v.items(), key=lambda x: -x[1])[:15] for k, v in file_hits.items()},
        'all_files': {k: sorted(v) for k, v in file_hits.items()},
    }
    with open(out_json, 'w') as f:
        json.dump(result, f, indent=1)
    print('%s: %d ELF files, %d instructions' % (label, len(files), instr_total))
    for k, v in totals.most_common():
        tag = 'ok on i5-8365U' if k in WHISKEY_LAKE_HAS else 'MISSING on i5-8365U'
        print('  %-26s %8d instr in %4d files   %s' % (k, v, len(file_hits[k]), tag))
    if failed:
        print('  timed out:', len(failed))


if __name__ == '__main__':
    main()
