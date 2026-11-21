#!/bin/sh
# build.sh - assemble src/zork.asm with Intel ASM86, run under emulation by
# udi/udi86.py, and write work/Zork.run with tools/mkrun.py.
#
# Needs orig/asm86.86 (see tools/getorig.sh) and a Python 3 with unicorn:
# PY if set, otherwise .venv in this directory, otherwise python3.
set -e
Z=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "$PY" ]; then
  if [ -x "$Z/.venv/Scripts/python.exe" ]; then PY=$Z/.venv/Scripts/python.exe
  elif [ -x "$Z/.venv/bin/python3" ]; then PY=$Z/.venv/bin/python3
  else PY=python3; fi
fi
if [ ! -f "$Z/orig/asm86.86" ]; then
  echo "build.sh: orig/asm86.86 is missing; see tools/getorig.sh" >&2
  exit 1
fi
mkdir -p "$Z/work"
cd "$Z/work"
cp "$Z/src/zork.asm" zork.asm
rm -f ZORK.obj ZORK.OBJ zork.obj
"$PY" "$Z/udi/udi86.py" "$Z/orig/asm86.86" "ASM86 zork.asm" > asm.out 2>&1 || true
if ! grep -q "NO ERRORS FOUND" asm.out; then
  cat asm.out
  grep -n -B2 "\*\*\* " ZORK.lst 2>/dev/null | head -60 || true
  exit 1
fi
OBJ=$(ls ZORK.obj ZORK.OBJ zork.obj 2>/dev/null | head -1)
"$PY" "$Z/tools/mkrun.py" "$OBJ" Zork.run
