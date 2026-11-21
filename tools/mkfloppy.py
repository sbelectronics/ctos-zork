#!/usr/bin/env python2
"""mkfloppy.py - make a Zork floppy for the AWS and the NGEN.

usage: mkfloppy.py [--ctostool DIR] [--dir NAME] template.img out.img Zork.run Zork1.dat

The template is a CTOS floppy image with a directory besides <Sys>. The files
in that directory are deleted, it is renamed <Zork>, and Zork.run and
Zork1.dat are added to it. The pages the deleted files used are zeroed, so
is <Sys>sysImage.sys, and the volume is named Zork.

It uses ctosdisk.py from ctostool (https://github.com/sbelectronics/ctostool),
which runs on Python 2. Give its directory with --ctostool or CTOSTOOL.

On the machine: set the Path to [f0]<Zork>, then Run [f0]<Zork>Zork.run
"""
from __future__ import print_function
import argparse, os, struct, sys

NEWDIR = 'Zork'

ap = argparse.ArgumentParser(description='Make a Zork floppy from a CTOS floppy image.')
ap.add_argument('--ctostool', default=os.environ.get('CTOSTOOL'), help='the ctostool directory (default: CTOSTOOL)')
ap.add_argument('--dir', help="the template's directory to use (default: its only one besides Sys)")
ap.add_argument('template')
ap.add_argument('out')
ap.add_argument('run')
ap.add_argument('story')
a = ap.parse_args()
if not a.ctostool or not os.path.exists(os.path.join(a.ctostool, 'ctosdisk.py')):
    sys.exit('mkfloppy: give the ctostool directory with --ctostool or CTOSTOOL')
sys.path.insert(0, a.ctostool)
from ctosdisk import *

data = bytearray(open(a.template, 'rb').read())
vhb = LoadVHB(data)
if vhb['CPagedMFD'] != 1:
    sys.exit('mkfloppy: the MFD has %d pages; renaming would need rehashing' % vhb['CPagedMFD'])
dirs = [m['dirNameStr'] for m in ReadMFD(data, vhb) if m['dirNameStr'].lower() != 'sys']
if a.dir:
    srcDir = a.dir
elif len(dirs) == 1:
    srcDir = dirs[0]
else:
    sys.exit('mkfloppy: pick one of the directories %s with --dir' % dirs)
if srcDir.lower() not in [d.lower() for d in dirs]:
    sys.exit('mkfloppy: the template has no directory %s' % srcDir)

for e in ReadDir(data, srcDir):
    Delete(data, srcDir, e['fh'], ReadAllocationBitmap(data))

# rename the directory in the MFD, which has one page, so the hash doesn't matter
def Rename(sb):
    n = sb[0]
    if n and str(sb[1:1 + n]).lower() == srcDir.lower():
        sb[0:13] = bytearray(chr(len(NEWDIR)) + NEWDIR + '\x00' * (12 - len(NEWDIR)))
offs = vhb['LfaMFDbase'] + 1
for j in range(14):
    entry = data[offs + 35 * j:offs + 35 * j + 13]
    Rename(entry)
    data[offs + 35 * j:offs + 35 * j + 13] = entry

# the active VHB keeps copies of recently used MFD entries; rename it there too
def RenameLru(v):
    lru = bytearray(v['RgLruDirEntries'])
    for i in range(0, len(lru), 35):
        entry = lru[i:i + 13]
        Rename(entry)
        lru[i:i + 13] = entry
    v['RgLruDirEntries'] = str(lru)
UpdateActiveVHB(data, RenameLru)

for name, src in [('Zork.run', a.run), ('Zork1.dat', a.story)]:
    AddFile(data, NEWDIR, name, open(src, 'rb').read())

# the deleted files' contents are still in the free pages
for page, free in enumerate(ReadAllocationBitmap(data)):
    if free and (page + 1) * 512 <= len(data):
        data[page * 512:(page + 1) * 512] = bytearray(512)

# the template's OS image isn't ours to ship, and the floppy is never booted.
# sysImage.sys can't be deleted (it's no-delete, and the VHB points to it), so
# blank it where it is.
vhb = LoadVHB(data)
start = vhb['LfaSysImagebase']
data[start:start + vhb['CPagesSysImage'] * 512] = bytearray(vhb['CPagesSysImage'] * 512)

# name the volume Zork in both VHBs, so the initial one still matches the
# active one, and fix their checksums
for offs in (0, vhb['LfaVHB']):
    data[offs + 20:offs + 33] = bytearray(chr(len(NEWDIR)) + NEWDIR + '\x00' * (12 - len(NEWDIR)))
    struct.pack_into('<H', data, offs, ComputeVHBChecksum(data[offs:]))

if CheckDisk(data) != 0:
    sys.exit('mkfloppy: disk check failed')
open(a.out, 'wb').write(data)
for e in ReadDir(data, NEWDIR):
    print('%-12s %7d bytes' % (e['name'], e['fh']['cbFile']))
