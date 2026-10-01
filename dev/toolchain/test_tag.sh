#!/bin/sh
# test_tag.sh: the tagged value model (SPEC 3.6). Numbers and regions are told
# apart by a tag in the low bits of the word, not by address range, so no
# integer can be mistaken for a region pointer. Before the tag, a large enough
# integer landed in the region range and was taken for one.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

fail=0
check() { # name : program : expected stdout
  "$WORD" build "$tmp/t.w" -o "$tmp/t" >/dev/null 2>&1 || { echo "  FAIL $1 (build error)"; fail=1; return; }
  got=$("$tmp/t" 2>&1)
  if [ "$got" = "$2" ]; then echo "  OK   $1"
  else echo "  FAIL $1 -> got [$got] want [$2]"; fail=1; fi
}

# The old REGION_BASE (0x600000000000). Before the tag this value couldn't
# appear in a program at all (num_to_str faulted on it). Now it's a number.
printf 'x = 105553116266496\nout(x)\nout(kind(x) == "number")\nout(x + 4)\n' > "$tmp/t.w"
check "REGION_BASE literal is an ordinary number" "105553116266496
true
105553116266500"

# A thousand address-sized integers, computed at run time, all stay numbers.
printf 'base = 105553116266000\ni = 0\nbad = 0\nloop i < 1000\n    if kind(base + i) != "number"\n        bad = bad + 1\n    i = i + 1\nout(bad)\n' > "$tmp/t.w"
check "computed address-valued integers never read as regions" "0"

# Integers are signed 63-bit: large magnitudes and negatives survive arithmetic.
printf 'a = 1000000000000\nout(a * 1000)\nout(0 - a)\nout(a * -1 - 1)\n' > "$tmp/t.w"
check "large + negative integers round-trip" "1000000000000000
-1000000000000
-1000000000001"

# An element that is itself a region is told apart from a number.
printf 'a = text(2)\na[0] = 7\nb = text(1)\nb[0] = a\nout(kind(b[0]) == "number")\nout(kind(a[0]) == "number")\nout(b[0][0])\n' > "$tmp/t.w"
check "nested region vs number element" "false
true
7"

# The exit status is the untagged return value (0), not its tagged encoding (1).
printf 'out("x")\n' > "$tmp/t.w"; "$WORD" build "$tmp/t.w" -o "$tmp/t" >/dev/null 2>&1
"$tmp/t" >/dev/null 2>&1; ec=$?
if [ "$ec" = 0 ]; then echo "  OK   program returning 0 exits 0"; else echo "  FAIL exit code $ec (want 0)"; fail=1; fi

if [ "$fail" = 0 ]; then echo "test_tag: PASS (tagged kind test; no integer aliases a region)"; exit 0
else echo "test_tag: FAIL"; exit 1; fi
