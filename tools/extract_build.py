#!/usr/bin/env python3
"""extract_build.py PARTS WORK [--product]

Unpack the pieces of a Google build that tools/port_build.py looks at, from the partition images in PARTS
(system_a.img, vendor_a.img, system_ext_a.img, [product_a.img]; see tools/fetch_google_parts.py) into WORK:

  WORK/system  WORK/vendor  WORK/system_ext  [WORK/product]     the erofs filesystems, extracted
  WORK/apex/<name>/                                              every APEX payload (erofs) up to 64 MB

Runs inside the gbos-erofs container (needs fsck.erofs); tools/port_build.sh does that. APEX payloads that are ext4 are
listed and skipped (no debugfs in the image); payloads over 64 MB (art, runtime, i18n) are listed and skipped too.
"""
import io, os, shutil, subprocess, sys, zipfile

EROFS_MAGIC = bytes.fromhex('e2e1f5e0')     # little-endian 0xE0F5E1E2 at offset 1024
BIG = 64 << 20


def erofs(img, dst):
    os.makedirs(dst, exist_ok=True)
    r = subprocess.run(['fsck.erofs', '--extract=' + dst, '--force', img], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit('fsck.erofs failed on %s:\n%s' % (img, (r.stdout + r.stderr)[-600:]))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    parts, work = args
    names = ['system', 'vendor', 'system_ext'] + (['product'] if '--product' in sys.argv else [])
    os.makedirs(work, exist_ok=True)
    for n in names:
        img = os.path.join(parts, n + '_a.img')
        if not os.path.isfile(img):
            sys.exit('missing %s' % img)
        print('extracting %s ...' % n, flush=True)
        erofs(img, os.path.join(work, n))
    skipped = []
    done = 0
    tmp = os.path.join(work, 'payload.img')
    for n in names:
        d = os.path.join(work, n, 'system', 'apex') if n == 'system' and os.path.isdir(os.path.join(work, n, 'system')) else os.path.join(work, n, 'apex')
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if not f.endswith(('.apex', '.capex')):
                continue
            name = f.rsplit('.', 1)[0]
            try:
                z = zipfile.ZipFile(os.path.join(d, f))
                if f.endswith('.capex'):                      # compressed APEX: the real one is inside
                    z = zipfile.ZipFile(io.BytesIO(z.read('original_apex')))
                info = z.getinfo('apex_payload.img')
            except (KeyError, zipfile.BadZipFile) as e:
                skipped.append('%s (%s)' % (name, e))
                continue
            if info.file_size > BIG:
                skipped.append('%s (%d MB, over the size limit)' % (name, info.file_size >> 20))
                continue
            with z.open(info) as src, open(tmp, 'wb') as dst:
                shutil.copyfileobj(src, dst)
            with open(tmp, 'rb') as fh:
                fh.seek(1024)
                magic = fh.read(4)
            if magic != EROFS_MAGIC:
                skipped.append('%s (not erofs)' % name)
                continue
            erofs(tmp, os.path.join(work, 'apex', name))
            done += 1
    if os.path.exists(tmp):
        os.remove(tmp)
    print('extracted %d APEX payloads' % done)
    if skipped:
        print('skipped: ' + '; '.join(skipped))
    open(os.path.join(work, '.done'), 'w').write('ok\n')


if __name__ == '__main__':
    main()
