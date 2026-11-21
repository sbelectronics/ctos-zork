#!/bin/sh
# getorig.sh <dir> [<dir> ...]
# Finds the Intel ASM86 assembler under the given directories (for example a
# copy of a CTOS system or development disk) and copies it to orig/asm86.86.
# It is Intel's software and is not in the repository. The file is accepted
# only if its SHA-256 matches the version Zork.run was built with.
#   asm86.86   Intel ASM86 assembler V2.0 (run by udi/udi86.py)
Z=$(cd "$(dirname "$0")/.." && pwd)
[ $# -gt 0 ] || { echo "usage: $0 <dir> [<dir> ...]" >&2; exit 2; }
WANT=8efaf522ce7ba858cc735ceb8b32c284de0c1d730d6bf5406465e598e3accf6d
f=$(find "$@" -type f -iname asm86.86 2>/dev/null | while IFS= read -r f; do
      [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$WANT" ] && { echo "$f"; break; }
    done)
if [ -z "$f" ]; then
  echo "orig/asm86.86: no file with SHA-256 $WANT found" >&2
  exit 1
fi
mkdir -p "$Z/orig"
cp "$f" "$Z/orig/asm86.86" && echo "orig/asm86.86 <- $f"
