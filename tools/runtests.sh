#!/bin/sh
# runtests.sh [Zork.run] - play each test/*.txt through Zork.run with
# tools/zharness.py and compare the transcript with test/*.expected.
# The default is work/Zork.run if it has been built, otherwise dist/Zork.run.
#
# If test/X.param exists, its first line is the story file parameter (the
# command form's first field) and its second the name the story file has
# in the test's directory (blank for none). Otherwise there's no parameter
# and the story file is Zork1.dat.
#
# The expected transcripts match dfrotz word for word apart from the
# interpreters' own prompts (tools/compare.sh checks that). To accept a
# deliberate change, run with UPDATE=1 and check the diff.
Z=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "$PY" ]; then
  if [ -x "$Z/.venv/Scripts/python.exe" ]; then PY=$Z/.venv/Scripts/python.exe
  elif [ -x "$Z/.venv/bin/python3" ]; then PY=$Z/.venv/bin/python3
  else PY=python3; fi
fi
RUN=${1:-$Z/work/Zork.run}
[ -f "$RUN" ] || RUN=$Z/dist/Zork.run
DIR=$Z/work/test
fail=0
for IN in "$Z"/test/*.txt; do
  T=$(basename "$IN" .txt)
  mkdir -p "$DIR/$T"
  rm -f "$DIR/$T/"*
  P= S=Zork1.dat
  if [ -f "$Z/test/$T.param" ]; then
    P=$(sed -n 1p "$Z/test/$T.param")
    S=$(sed -n 2p "$Z/test/$T.param")
  fi
  [ -n "$S" ] && cp "$Z/story/Zork1.dat" "$DIR/$T/$S"
  "$PY" "$Z/tools/zharness.py" -d "$DIR/$T" -p "$P" "$RUN" "$IN" > "$DIR/$T.out" 2>&1
  if [ -n "$UPDATE" ]; then
    cp "$DIR/$T.out" "$Z/test/$T.expected"
    echo "$T: updated"
  elif cmp -s "$DIR/$T.out" "$Z/test/$T.expected"; then
    echo "$T: ok"
  else
    echo "$T: FAILED"
    diff "$Z/test/$T.expected" "$DIR/$T.out" | head -20
    fail=1
  fi
done
exit $fail
