#!/bin/sh
# test_alias.sh - a region that's still reachable some other way is never
# treated as unique.
#
# The uniqueness pass lets `s = s . x` append in place and lets an overwritten
# local give its region back to the arena. Both are only safe when nothing else
# can reach the region. Three builtins can hand back their argument unchanged
# (decode when it's already code points, pad when it's already wide enough, and
# number when it's already a number), and two code shapes kept a second
# reference the pass didn't see: a `loop x in t` whose body reassigns t, and a
# contract hook that stores a parameter. Each one let a program read memory
# that had been handed to something else, with no fault.
#
# Every program in dev/toolchain/alias/ says what it should print on its first
# line (`// want: ...`). The neg_*.w ones pass either way: they check builtins
# that always allocate, so a builtin that later gains an identity path shows up.
# Runs on the host target, and on arm64 under qemu when it's there.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 30"
QEMU=""
if [ "$(uname -s)" = Linux ]; then
  QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
  case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
fi

pass=0; fail=0
cd "$here/alias"
for f in *.w; do
  want=$(head -1 "$f" | sed 's#^// want: ##')
  if "$WORD" build "$f" -o "$tmp/x" >"$tmp/err" 2>&1; then
    got=$($TO "$tmp/x" </dev/null 2>&1 | tr -d '\r')
  else
    got="build failed: $(head -1 "$tmp/err")"
  fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $f -- got [$got] want [$want]"; fi
  if [ -n "$QEMU" ]; then
    if "$WORD" build -arm64 "$f" -o "$tmp/a" >"$tmp/err" 2>&1; then
      got=$($TO $QEMU "$tmp/a" </dev/null 2>&1)
    else
      got="build failed: $(head -1 "$tmp/err")"
    fi
    if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL arm64 $f -- got [$got] want [$want]"; fi
  fi
done
[ -n "$QEMU" ] || echo "  note: no qemu-aarch64, so only the host target ran"
echo "test_alias: $pass passed, $fail failed"
[ "$fail" = 0 ]
