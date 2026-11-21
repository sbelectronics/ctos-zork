#!/usr/bin/env python3
"""mkrun.py - turn a one-segment ASM86 object into a CTOS V4 run file.

The program is one segment (CS = DS = SS), entered at offset 0, so the run
file needs no relocations: the loader relocates saStack and saStart itself.
CTOS calls are far calls to fixed addresses, assembled as literal bytes.

usage: mkrun.py in.obj out.run [stack_offset]

Fixups inside the segment that are self-relative or offsets into the segment
itself are applied; anything that needs a segment base (a relocation) is an
error, since the program is meant not to have any.
"""
import os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import omf2

src, dst = sys.argv[1], sys.argv[2]
o = omf2.parse(open(src, 'rb').read())
segs = [s for s in o.segs if s and s.length]
if len(segs) != 1:
    sys.exit('mkrun: expected exactly one non-empty segment, got %s' % [(s.name, s.length) for s in segs])
seg = segs[0]
img = bytearray(seg.data)
for fx in seg.fix:
    p = fx['off']
    if fx['M'] == 0:
        sys.exit('mkrun: self-relative fixup at %04x (external call?)' % p)
    if fx['loc'] in (2, 3):
        sys.exit('mkrun: segment-base fixup at %04x would need a relocation' % p)
    if fx['tm'] == 0 and o.segs[fx['ti']] is seg:
        # offset into our own segment: the segment starts at 0, so only the displacement counts
        if fx['loc'] == 1:
            struct.pack_into('<H', img, p, (struct.unpack_from('<H', img, p)[0] + fx['disp']) & 0xffff)
        elif fx['loc'] == 0:
            img[p] = (img[p] + fx['disp']) & 0xff
        else:
            sys.exit('mkrun: unsupported fixup location %d at %04x' % (fx['loc'], p))
    else:
        sys.exit('mkrun: fixup at %04x to something outside the segment (%s)' % (p, fx))

pubs = {n.upper(): off for n, si, off in o.pubs}
if len(sys.argv) > 3:
    sp = int(sys.argv[3], 0)
elif 'STKTOP' in pubs:
    sp = pubs['STKTOP']
else:
    sp = len(img)
if len(img) & 1: img.append(0)
if sp > len(img) or sp & 1:
    sys.exit('mkrun: bad stack offset %#x' % sp)

HDR = 0x200
hdr = bytearray(HDR)
total = HDR + len(img)
total = (total + 511) // 512 * 512
img += bytes(total - HDR - len(img))
ver = b'Ver Zork ' + open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'VERSION')).read().strip().encode()
fields = [
    0x5747,          # 0  signature 'GW'
    4,               # 2  run file version
    total // 512,    # 4  cpnRes: file size in 512-byte pages
    0,               # 6  irleMax: relocation entries
    HDR // 16,       # 8  cparDirectory: header size in paragraphs
    0, 0,            # 10 cparMinAlloc, 12 cparMaxAlloc
    0, sp,           # 14 saStack, 16 raStackInit
    0,               # 18 checksum
    0, 0,            # 20 raStart, 22 saStart
    0x50,            # 24 rbrgrle: relocation table offset
    0,               # 26 iovMax
    0xFFFF,          # 28 constant
    1,               # 30 verAlt
    0x50,            # 32 end of the (empty) relocation table, as the CTOS linker writes it
]
struct.pack_into('<%dH' % len(fields), hdr, 0, *fields)
hdr[0x24:0x24 + len(ver)] = ver
run = bytearray(hdr + img)
s = sum(struct.unpack_from('<%dH' % (len(run) // 2), run, 0)) & 0xffff
struct.pack_into('<H', run, 18, (0xffff - s) & 0xffff)
open(dst, 'wb').write(run)
print('mkrun: %s: code+data %#x bytes, stack top %#x, file %d bytes' % (dst, len(seg.data), sp, len(run)))
