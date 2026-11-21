#!/usr/bin/env python3
"""zharness.py - run Zork.run on the host in a unicorn 8086, with the CTOS
calls it uses emulated, for quick testing.

usage: zharness.py [-d DIR] [-n MAXINSN] [-v] Zork.run input.txt

DIR holds the story file (Zork1.dat) and receives save files.  Each line of
input.txt is typed followed by RETURN.  Lines starting with '#' are
comments.  The run stops when the input is used up.  The transcript (every
line that scrolls up, then the last screen) goes to stdout.
"""
import argparse, os, struct, sys
from unicorn import Uc, UcError, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR, UC_HOOK_CODE
from unicorn.x86_const import *

ap = argparse.ArgumentParser()
ap.add_argument('-d', default='.', help='directory with Zork1.dat, where save files go')
ap.add_argument('-n', type=int, default=2_000_000_000, help='stop after this many instructions')
ap.add_argument('-v', action='store_true', help='log file opens')
ap.add_argument('-l', '--lines', type=int, default=29, help='screen lines (the AWS has 29)')
ap.add_argument('-p', '--param', default='', help="the command form's first field (the story file)")
ap.add_argument('--keys', action='store_true', help='input is raw characters, not lines')
ap.add_argument('--trace-at', type=lambda x: int(x, 16), action='append', default=[],
                help='image offset (hex): print the registers each time it runs')
ap.add_argument('run')
ap.add_argument('inp')
a = ap.parse_args()
# the same transcript on every platform, for tools/runtests.sh
sys.stdout.reconfigure(newline='\n')

run = open(a.run, 'rb').read()
h = struct.unpack_from('<16H', run, 0)
img = run[h[4] * 16:]
LOADSEG = 0x1000
mu = Uc(UC_ARCH_X86, UC_MODE_16)
mu.mem_map(0, 0x120000)
mu.mem_write(LOADSEG * 16, img)
# CTOS entry points: INT F0h at every even address of 200-23F (and above 1 MB)
for base in (0x200, 0x100200):
    mu.mem_write(base, b'\xcd\xf0' * 0x40)
# a RETF stub well away from them
mu.mem_write(0x300, b'\xcb'); mu.mem_write(0x100300, b'\xcb')
heap = [0x30000]

# the ASCB, and the VLPB it points to, as the Executive leaves them for a
# command whose form has one field: parameter 0 is the command name and
# parameter 1 the field, each a list of subparameters (a length byte and
# the characters).  cParams counts the fields, not parameter 0.
ASCB, VLPB = 0x8000, 0x8200
rows = [b'\x04Zork', bytes([len(a.param)]) + a.param.encode('latin1') if a.param else b'']
ob = 6 + 4 * len(rows)
sdo, body = b'', b''
for r in rows:
    sdo += struct.pack('<HH', ob + len(body), len(r)); body += r
vlpb = struct.pack('<HHH', ob + len(body), ob + len(body), len(rows) - 1) + sdo + body
mu.mem_write(VLPB, vlpb)
mu.mem_write(ASCB, struct.pack('<HHH', 0, 0, VLPB >> 4))

keys = []
for L in open(a.inp, encoding='latin1').read().split('\n'):
    if not a.keys and L.startswith('#'):
        continue
    keys += [ord(c) for c in L] + [0x0A]

# the Executive's frames on the AWS: 1 is its header lines, 0 the rest
frames = {0: dict(col=0, row=3, cols=80, lines=a.lines - 3), 1: dict(col=0, row=0, cols=80, lines=3)}
screen_lines = a.lines
scr = [[' '] * 80 for _ in range(screen_lines)]
transcript = []
files = {}
nextfh = [10]
state = {'stop': None, 'status': ''}

def rdw(addr): return struct.unpack('<H', mu.mem_read(addr, 2))[0]
def wrw(addr, v): mu.mem_write(addr, struct.pack('<H', v & 0xffff))
def lin(seg, off): return (seg * 16 + off) & 0xfffff

def hostpath(name):
    n = name
    for ch in ']>':
        if ch in n: n = n.split(ch)[-1]
    for f in os.listdir(a.d):
        if f.lower() == n.lower(): return os.path.join(a.d, f)
    return os.path.join(a.d, n)

def frame_row(fr, line):
    f = frames.get(fr)
    if f is None: return None
    if line >= f['lines']: return None
    return f['row'] + line

def call(cs, ip):
    sp = mu.reg_read(UC_X86_REG_SP); ss = mu.reg_read(UC_X86_REG_SS)
    base = lin(ss, sp)
    def args(n):
        ws = [rdw(base + 4 + 2 * i) for i in range(n)]
        return list(reversed(ws))
    key = (cs, ip)
    erc = 0
    if key == (0xFFDF, 0x436):              # PutFrameChars
        fr, col, line, seg, off, cb = args(6); n = 6
        r = frame_row(fr, line)
        txt = bytes(mu.mem_read(lin(seg, off), cb)).decode('latin1')
        if r is None: erc = 1
        else:
            for i, c in enumerate(txt):
                if col + i < 80: scr[r][col + i] = c
    elif key == (0xFFDF, 0x434):            # PutFrameAttrs
        n = 5
    elif key == (0xFFDF, 0x432):            # PosFrameCursor
        fr, col, line = args(3); n = 3
        if frame_row(fr, line) is None or col >= 80: erc = 1
    elif key == (0xFFDF, 0x43A):            # ResetFrame
        fr, = args(1); n = 1
        f = frames.get(fr)
        if f:
            if fr == 0:    # keep what was on the screen in the transcript
                rows = [''.join(scr[r]).rstrip() for r in range(f['row'] + 1, f['row'] + f['lines'])]
                while rows and not rows[0]: rows.pop(0)
                transcript.extend(rows)
            for r in range(f['row'], f['row'] + f['lines']): scr[r] = [' '] * 80
    elif key == (0xFFDF, 0x43C):            # ScrollFrame
        fr, start, mx, cnt, up = args(5); n = 5
        f = frames[fr]
        rows = [f['row'] + i for i in range(start, mx)]
        for _ in range(cnt):
            if fr == 0: transcript.append(''.join(scr[rows[0]]).rstrip())
            if up & 0xff:
                for i in range(len(rows) - 1): scr[rows[i]] = scr[rows[i + 1]][:]
                scr[rows[-1]] = [' '] * 80
    elif key == (0xFFD0, 0x51A):            # ReadKbd
        seg, off = args(2); n = 2
        if not keys:
            state['stop'] = 'input used up'
            mu.emu_stop()
            return
        mu.mem_write(lin(seg, off), bytes([keys.pop(0)]))
    elif key == (0xFFCF, 0x53E):            # GetpASCB
        seg, off = args(2); n = 2
        mu.mem_write(lin(seg, off), struct.pack('<HH', 0, ASCB >> 4))
    elif key == (0xFFD0, 0x518):            # Beep
        n = 0
    elif key == (0xFFF8, 0x29C):            # GetDateTime
        seg, off = args(2); n = 2
        mu.mem_write(lin(seg, off), struct.pack('<I', 0x12345678))
    elif key == (0xFFD8, 0x494):            # AllocMemorySL
        cb, seg, off = args(3); n = 3
        p = heap[0]; heap[0] = (p + cb + 15) & ~15
        mu.mem_write(lin(seg, off), struct.pack('<HH', 0, p >> 4))
    elif key == (0x0000, 0x218):            # OpenFile
        fseg, foff, nseg, noff, cb, pseg, poff, cbp, mode = args(9); n = 9
        name = bytes(mu.mem_read(lin(nseg, noff), cb)).decode('latin1')
        path = hostpath(name)
        if not os.path.exists(path): erc = 203
        else:
            fh = nextfh[0]; nextfh[0] += 1
            files[fh] = path
            wrw(lin(fseg, foff), fh)
        if a.v: print('[OpenFile %r -> %d]' % (name, erc), file=sys.stderr)
    elif key == (0x0000, 0x21A):            # CreateFile
        nseg, noff, cb, pseg, poff, cbp, hi, lo = args(8); n = 8
        name = bytes(mu.mem_read(lin(nseg, noff), cb)).decode('latin1')
        path = hostpath(name)
        if os.path.exists(path): erc = 224
        else: open(path, 'wb').write(bytes((hi << 16) | lo))
    elif key == (0xFFF8, 0x294):            # CloseFile
        fh, = args(1); n = 1
        files.pop(fh, None)
    elif key == (0xFFF8, 0x29A):            # ChangeFileLength
        fh, hi, lo = args(3); n = 3
        with open(files[fh], 'r+b') as f: f.truncate((hi << 16) | lo)
    elif key in ((0xFFE0, 0x416), (0xFFE0, 0x418)):  # Read, Write
        fh, bseg, boff, cb, hi, lo, cseg, coff = args(8); n = 8
        lfa = (hi << 16) | lo
        if lfa % 512 or cb % 512: erc = 2
        path = files.get(fh)
        if path is None: erc = 202
        elif erc == 0:
            if ip == 0x416:
                d = open(path, 'rb').read()[lfa:lfa + cb]
                mu.mem_write(lin(bseg, boff), d)
                wrw(lin(cseg, coff), len(d))
                if len(d) < cb: erc = 1
            else:
                d = bytes(mu.mem_read(lin(bseg, boff), cb))
                size = os.path.getsize(path)
                if lfa + cb > size: erc = 2
                else:
                    with open(path, 'r+b') as f: f.seek(lfa); f.write(d)
                    wrw(lin(cseg, coff), cb)
    elif key == (0xFFEF, 0x336):            # Exit
        state['stop'] = 'Exit'; mu.emu_stop(); return
    elif key == (0xFFEF, 0x334):            # ErrorExit
        e, = args(1)
        state['stop'] = 'ErrorExit %d' % e; mu.emu_stop(); return
    else:
        state['stop'] = 'unknown CTOS call %04X:%04X' % (cs, ip); mu.emu_stop(); return
    mu.reg_write(UC_X86_REG_AX, erc)
    retip = rdw(base); retcs = rdw(base + 2)
    # move the return address over the arguments, then RETF from the stub
    newsp = sp + 2 * n
    wrw(lin(ss, newsp), retip); wrw(lin(ss, newsp + 2), retcs)
    mu.reg_write(UC_X86_REG_SP, newsp)
    stub = 0x300 if cs * 16 <= 0x300 else 0x100300
    mu.reg_write(UC_X86_REG_IP, (stub - cs * 16) & 0xffff)

def hook_intr(uc, intno, user):
    if intno != 0xF0:
        state['stop'] = 'interrupt %02X' % intno; uc.emu_stop(); return
    cs = uc.reg_read(UC_X86_REG_CS); ip = (uc.reg_read(UC_X86_REG_IP) - 2) & 0xffff
    call(cs, ip)

mu.hook_add(UC_HOOK_INTR, hook_intr)
def hook_code(uc, addr, size, user):
    off = addr - LOADSEG * 16
    print('[trace %04X AX=%04X BX=%04X CX=%04X DX=%04X]' % (off, uc.reg_read(UC_X86_REG_AX), uc.reg_read(UC_X86_REG_BX), uc.reg_read(UC_X86_REG_CX), uc.reg_read(UC_X86_REG_DX)), file=sys.stderr)
for t in a.trace_at:
    mu.hook_add(UC_HOOK_CODE, hook_code, begin=LOADSEG * 16 + t, end=LOADSEG * 16 + t)
seg = LOADSEG
mu.reg_write(UC_X86_REG_SS, seg + h[7]); mu.reg_write(UC_X86_REG_SP, h[8])
mu.reg_write(UC_X86_REG_DS, seg); mu.reg_write(UC_X86_REG_ES, seg)
mu.reg_write(UC_X86_REG_CS, seg + h[11])
start = (seg + h[11]) * 16 + h[10]
try:
    mu.emu_start(start, 0xFFFFFFFF, count=a.n)
except UcError as e:
    cs = mu.reg_read(UC_X86_REG_CS); ip = mu.reg_read(UC_X86_REG_IP)
    state['stop'] = 'unicorn error %s at %04X:%04X (image offset %04X)' % (e, cs, ip, (cs - seg) * 16 + ip)

for L in transcript: print(L)
f0 = frames[0]
for r in range(f0['row'] + 1, f0['row'] + f0['lines']): print(''.join(scr[r]).rstrip())
print('==== status line:', ''.join(scr[f0['row']]).rstrip())
print('==== stopped:', state['stop'])
