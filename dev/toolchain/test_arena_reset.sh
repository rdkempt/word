#!/bin/sh
# test_arena_reset.sh: sys.mark / sys.reset free everything allocated since a
# mark. The arena grows on demand, so what we can observe is address space: a
# loop that allocates far more in total than it's allowed to hold has to finish
# when it resets each iteration, and run out of room when it doesn't.
#
# Both programs run under the same address-space cap (ulimit -v), which makes
# the result deterministic: the reset loop must finish with the right answer,
# and the leak loop must die with the runtime's own out-of-memory message.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

# Each iteration allocates about 80 MB, and text() fills it eagerly (the number
# 0 is the machine word 1 in the tagged value model), so the pages are
# committed. 100 iterations is about 8 GB in total, far past the cap below, so
# only the loop that gives its memory back can finish.
#
# The leak loop stores each region into `keep`, which is what makes it leak.
# The dead-store rewind gives back the region a unique local is about to
# overwrite, so `a = text(...)` alone in a loop is bounded now and would
# finish. Keeping a reference makes the test ask what mark/reset does for
# memory the compiler can't prove dead.
cat > "$tmp/reset.w" <<'EOF'
import sys
i = 0
loop i < 100
    m = mark()
    a = text(10000000)
    a[0] = i
    a[9999999] = i
    reset(m)
    i = i + 1
out(i)
EOF
cat > "$tmp/leak.w" <<'EOF'
import sys
keep = text(100)
i = 0
loop i < 100
    a = text(10000000)
    a[0] = i
    a[9999999] = i
    keep[i] = a
    i = i + 1
out(i)
EOF
"$WORD" build "$tmp/reset.w" -o "$tmp/reset"
"$WORD" build "$tmp/leak.w"  -o "$tmp/leak"

CAP=1048576                     # 1 GiB of address space, in KB

# run PROG under the cap; sets rc, out, err
capped() {
  set +e
  ( ulimit -v "$CAP"; exec "$1" ) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
}

fail=0

capped "$tmp/reset"
if [ "$rc" = 0 ] && [ "$out" = 100 ]; then
  echo "  ok: with reset, 100 x 80 MB finishes inside a 1 GiB cap"
else
  echo "  FAIL: reset loop did not finish (rc=$rc out=[$out] err=[$err])"; fail=1
fi

capped "$tmp/leak"
case "$err" in *"out of memory"*) oom=1;; *) oom=0;; esac
if [ "$rc" != 0 ] && [ "$out" != 100 ] && [ "$oom" = 1 ]; then
  echo "  ok: without it, the same loop runs out of room (rc=$rc, \"$err\")"
else
  echo "  FAIL: leak loop should have exhausted the cap (rc=$rc out=[$out] err=[$err])"; fail=1
fi

if [ "$fail" = 0 ]; then
  echo "test_arena_reset: PASS (mark/reset bounds the arena; the same loop without it cannot fit)"
  exit 0
fi
echo "test_arena_reset: FAIL"
exit 1
