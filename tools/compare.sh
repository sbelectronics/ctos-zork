#!/bin/sh
# compare.sh input.txt - play input.txt through Zork.run (with tools/zharness.py)
# and through dfrotz with the same random seed, and compare the transcripts
# word by word.
#
# dfrotz is the dumb-terminal Frotz (the frotz package on Debian and Ubuntu).
# DFROTZ names it if it isn't on the PATH. To run it on another machine, set
# ZHOST to user@host: the story and the input are copied to ~/ztmp there.
#
# The harness's GetDateTime gives 12345678h, so Zork.run seeds its generator
# with 12340C22h. dfrotz -s 305400866 uses that seed, and both use the same
# linear congruential generator.
set -e
Z=$(cd "$(dirname "$0")/.." && pwd)
IN=$1
[ -f "$IN" ] || { echo "usage: $0 input.txt" >&2; exit 2; }
if [ -z "$PY" ]; then
  if [ -x "$Z/.venv/Scripts/python.exe" ]; then PY=$Z/.venv/Scripts/python.exe
  elif [ -x "$Z/.venv/bin/python3" ]; then PY=$Z/.venv/bin/python3
  else PY=python3; fi
fi
RUN=$Z/work/Zork.run
[ -f "$RUN" ] || RUN=$Z/dist/Zork.run
OUT=$Z/work/cmp
FROTZ="${DFROTZ:-dfrotz} -m -p -q -s 305400866 -w 80 -R . Zork1.dat"
mkdir -p "$OUT/run" "$OUT/ref"
rm -f "$OUT/run/"*.sav "$OUT/ref/"*.sav "$OUT/ref/"*.qzl
cp "$Z/story/Zork1.dat" "$OUT/run/"
cp "$Z/story/Zork1.dat" "$OUT/ref/"
"$PY" "$Z/tools/zharness.py" -d "$OUT/run" "$RUN" "$IN" > "$OUT/mine.txt"
if [ -n "$ZHOST" ]; then
  ssh -o BatchMode=yes "$ZHOST" "mkdir -p ztmp"
  scp -q "$Z/story/Zork1.dat" "$IN" "$ZHOST:ztmp/"
  ssh -o BatchMode=yes "$ZHOST" "cd ztmp && rm -f *.sav *.qzl && $FROTZ < $(basename "$IN")" > "$OUT/ref.txt" 2>&1 || true
else
  (cd "$OUT/ref" && $FROTZ < "$IN") > "$OUT/ref.txt" 2>&1 || true
fi
"$PY" - "$OUT/mine.txt" "$OUT/ref.txt" <<'EOF'
import sys, difflib
def words(path, mine):
    # the harness's status lines and stop line aren't game text, and dfrotz
    # doesn't echo the input after its prompt
    t = []
    for L in open(path, encoding='latin1'):
        L = L.rstrip('\n')
        if L.startswith('===='):
            if 'stopped' in L: break
            continue
        if mine and L.startswith('>'): L = '>'
        t.append(L)
    return '\n'.join(t).replace('>', ' ').split()
a = words(sys.argv[1], True)
b = words(sys.argv[2], False)
sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
n = 0
for op, i1, i2, j1, j2 in sm.get_opcodes():
    if op == 'equal': continue
    n += 1
    if n <= 15:
        print('---', op, 'mine:', ' '.join(a[max(0, i1 - 8):i2 + 8]))
        print('     ', ' ref:', ' '.join(b[max(0, j1 - 8):j2 + 8]))
print('words: mine %d, ref %d, differing blocks %d' % (len(a), len(b), n))
EOF
