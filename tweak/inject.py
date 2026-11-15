#!/usr/bin/env python3
"""Inject KAlertXC.dylib into an IPA by adding LC_LOAD_DYLIB (pure Python, no optool).

Two modes, chosen automatically and validated against the real 3.0.496 binary:
  * pad  — write the command into the existing padding between the load commands and
           __text (16,048 bytes free in XCamera: nothing in the file moves)
  * grow — if padding is insufficient, insert whole pages before __text and shift every
           segment/section file offset by that page multiple, preserving page alignment.

Usage:
    python3 inject.py in.ipa path/to/KAlertXC.dylib out.ipa
"""
import sys, os, struct, zipfile, shutil, tempfile, pathlib

LC_LOAD_DYLIB = 0xC
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
PAGE = 0x4000
MH_MAGIC_64 = 0xFEEDFACF
EXE_REL = 'Payload/XCamera.app/XCamera'
DYLIB_REL = 'Payload/XCamera.app/Frameworks/KAlertXC.dylib'
DYLIB_INSTALL_NAME = '@executable_path/Frameworks/KAlertXC.dylib'


def align8(v):
    return (v + 7) & ~7


def make_lc(name):
    raw = name.encode() + b"\x00"
    cmdsize = align8(24 + len(raw))
    head = struct.pack("<IIIIII", LC_LOAD_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000)
    return head + raw + b"\x00" * (cmdsize - 24 - len(raw))


def segments(buf, ncmds):
    p, out = 32, []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", buf, p)
        if size <= 0:
            raise SystemExit(f"corrupt load command at {p:#x}")
        if cmd == LC_SEGMENT_64:
            name = bytes(buf[p + 8:p + 24]).split(b"\x00")[0].decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", buf, p + 24)
            nsects = struct.unpack_from("<I", buf, p + 64)[0]
            out.append(dict(at=p, name=name, fileoff=fileoff, filesize=filesize, nsects=nsects))
        p += size
    return out


def first_section_offset(buf, segs):
    best = None
    for s in segs:
        if s['name'] != '__TEXT':
            continue
        for j in range(s['nsects']):
            sp = s['at'] + 72 + j * 80
            soff = struct.unpack_from("<I", buf, sp + 48)[0]
            if soff and (best is None or soff < best):
                best = soff
    return best


def already_injected(buf, ncmds):
    p = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", buf, p)
        if cmd == LC_LOAD_DYLIB:
            off = struct.unpack_from("<I", buf, p + 8)[0]
            nm = bytes(buf[p + off:p + size]).split(b"\x00")[0].decode("utf-8", "replace")
            if 'KAlertXC' in nm:
                return True
        p += size
    return False


def inject(buf, name=DYLIB_INSTALL_NAME):
    magic, = struct.unpack_from("<I", buf, 0)
    if magic != MH_MAGIC_64:
        raise SystemExit(f"not a thin arm64 Mach-O (magic={magic:#x})")
    ncmds, sizeofcmds = struct.unpack_from("<II", buf, 16)
    if already_injected(buf, ncmds):
        return bytearray(buf), {'mode': 'already'}
    lc = make_lc(name)
    need = align8(len(lc))
    lc_end = 32 + sizeofcmds
    segs = segments(buf, ncmds)
    insert_at = first_section_offset(buf, segs)
    padding = insert_at - lc_end
    rep = {'lc_end': hex(lc_end), 'first_section': hex(insert_at),
           'padding': padding, 'need': need}

    if padding >= need:
        out = bytearray(buf)
        out[lc_end:lc_end + len(lc)] = lc
        struct.pack_into("<I", out, 16, ncmds + 1)
        struct.pack_into("<I", out, 20, sizeofcmds + need)
        rep['mode'] = 'pad'
        return out, rep

    pages = (need - padding + PAGE - 1) // PAGE
    shift = pages * PAGE
    out = bytearray(buf[:insert_at]) + bytearray(shift) + bytearray(buf[insert_at:])
    pos = lc_end
    out[pos:pos + len(lc)] = lc
    struct.pack_into("<I", out, 16, ncmds + 1)
    struct.pack_into("<I", out, 20, sizeofcmds + (pos + need - lc_end))
    for s in segs:
        if s['name'] == '__PAGEZERO':
            continue
        p = s['at']
        if s['fileoff'] >= insert_at:
            struct.pack_into("<Q", out, p + 40, s['fileoff'] + shift)
        else:
            struct.pack_into("<Q", out, p + 48, s['filesize'] + shift)
        for j in range(s['nsects']):
            sp = p + 72 + j * 80
            soff = struct.unpack_from("<I", out, sp + 48)[0]
            if soff >= insert_at and soff:
                struct.pack_into("<I", out, sp + 48, soff + shift)
    p = 32
    for _ in range(ncmds + 1):
        cmd, size = struct.unpack_from("<II", out, p)
        if cmd == LC_CODE_SIGNATURE:
            so = struct.unpack_from("<I", out, p + 8)[0]
            if so >= insert_at:
                struct.pack_into("<I", out, p + 8, so + shift)
        p += size
    rep['mode'] = 'grow'
    rep['shift'] = shift
    return out, rep


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        raise SystemExit(1)
    src, dylib, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    work = tempfile.mkdtemp()
    print(f'==> extracting {src}')
    with zipfile.ZipFile(src) as z:
        z.extractall(work)
    exe = os.path.join(work, EXE_REL)
    if not os.path.exists(exe):
        raise SystemExit(f'{EXE_REL} not found in archive')
    os.makedirs(os.path.join(work, os.path.dirname(DYLIB_REL)), exist_ok=True)
    shutil.copy2(dylib, os.path.join(work, DYLIB_REL))

    data = bytearray(pathlib.Path(exe).read_bytes())
    out, rep = inject(data)
    print(f'==> injection mode={rep["mode"]} padding={rep.get("padding")} need={rep.get("need")}')
    pathlib.Path(exe).write_bytes(out)

    if os.path.exists(dst):
        os.remove(dst)
    base = os.path.join(work, 'Payload')
    with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as z:
        for root, _, files in os.walk(base):
            for f in sorted(files):
                full = os.path.join(root, f)
                z.write(full, os.path.relpath(full, work))
    print(f'==> wrote {dst} ({os.path.getsize(dst):,} bytes)')


if __name__ == '__main__':
    main()
