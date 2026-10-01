#!/bin/sh
# test_a64_lang.sh: the arm64 code generator checked against the x86-64 one.
# word builds each program in a64_lang/ for both targets, runs the arm64 binary
# under qemu-user and the x86-64 one directly, and the exit status and output
# have to match byte for byte. The other backend is the oracle, so a new
# program in a64_lang/ is a new test on both targets with no expected output to
# maintain.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok=0; fail=0

QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
if [ -z "$QEMU" ]; then
  # Without qemu we can't run the arm64 binaries, but every program still has
  # to build for arm64.
  for f in "$here"/a64_lang/*.w; do
    if "$WORD" build -arm64 "$f" -o "$tmp/a" >"$tmp/err" 2>&1; then ok=$((ok+1))
    else echo "  FAIL (arm64 build): $(basename "$f")"; head -2 "$tmp/err"; fail=$((fail+1)); fi
  done
  echo "SKIP: no qemu-aarch64 to run the result; $ok/$((ok+fail)) programs built for arm64"
  [ "$fail" = 0 ]
  exit $?
fi

for f in "$here"/a64_lang/*.w; do
  name=$(basename "$f")
  if ! "$WORD" build -arm64 "$f" -o "$tmp/a64" >"$tmp/err" 2>&1; then
    echo "  FAIL (arm64 build): $name"; head -2 "$tmp/err"; fail=$((fail+1)); continue
  fi
  if ! "$WORD" build "$f" -o "$tmp/x86" >"$tmp/err" 2>&1; then
    echo "  FAIL (x86-64 build): $name"; head -2 "$tmp/err"; fail=$((fail+1)); continue
  fi
  chmod +x "$tmp/a64" "$tmp/x86"
  # Both read stdin from /dev/null, so a program that reads it gets the same
  # empty input on either target.
  ra=0; $QEMU "$tmp/a64" < /dev/null > "$tmp/out.a64" 2>&1 || ra=$?
  rx=0; "$tmp/x86"       < /dev/null > "$tmp/out.x86" 2>&1 || rx=$?
  if [ "$ra" != "$rx" ]; then
    echo "  FAIL: $name exited $ra on arm64, $rx on x86-64"; fail=$((fail+1)); continue
  fi
  if cmp -s "$tmp/out.a64" "$tmp/out.x86"; then ok=$((ok+1))
  else
    echo "  FAIL: $name printed different things"
    diff "$tmp/out.x86" "$tmp/out.a64" | head -8
    fail=$((fail+1))
  fi
done

# Faults have to read the same on both targets too, down to the line number.
# Every program here exits 70 with `<file>:<line>: <what>`, except the sum of
# the two largest literals, which is in range and prints. In order:
# - Two top-level returns of a value that isn't a whole number, where the
#   compiler can't see its kind. The status is `n & 255` (SPEC 8.1), so each
#   faults the way `&` does. The float's status used to come from its box
#   address, 1 on x86-64 and 13 on arm64.
# - Bounds, divide by zero, stack exhaustion, a write to a literal, overflow,
#   and the wrong kind handed to a builtin or a for-each loop.
# - A split with an empty separator and a stringify of a cycle. No wrong kind
#   reaches these, so test_kinds.sh can't hold them. arm64 printed both one
#   byte short.
# - Five allocations too large to exist. Each target once wrapped these into a
#   tiny block with a huge length (test_gaps.sh checks the message).
# - Two negative shift counts written as constants. x86-64 skipped the range
#   check on that path and let the instruction mask the count to six bits, so
#   `1 << (0 - 1)` gave 0 and `1 >> (0 - 64)` gave 1. SPEC 3.1 says a count
#   outside 0 .. 63 faults.
# - Two cycles compared with ==. arm64's rt_eq had no stack guard and crashed
#   with SIGSEGV where x86-64 faulted.
# - Writes to the read-only regions (SPEC 3.7): a map key in range, through
#   keys() and out of range, then a literal out of range. arm64 checked bounds
#   first and answered `index out of bounds` where x86-64 answered `write to a
#   literal`.
# - A text element that isn't a character (-5, then a surrogate) written as
#   JSON. Both targets used to write these out; test_json.sh holds the answer.
# - A map key holding a region, which both targets used to accept (test_gaps.sh
#   holds the answer).
# - A masked sum into a 32-bit local that overflows before the mask. Both
#   targets added in 32-bit registers and printed 0 (test_gaps.sh holds the
#   answer).
for prog in 'return number("2.5")' 'f(a)
    return a
return f("x")' 'a = text(3)
out(a[7])' 'out(1 / 0)' 'r(n)
    return r(n + 1)
out(r(1))' 's = "hi"
s[0] = 65' 'out(2305843009213693951 + 2305843009213693951)' 'm = {a: 1}
out(len(copy(m, 0, 2)))' 'f(y)
    loop v in y
        out(v)
f({a: 1})' 'id(v)
    return v
out(len(copy(id(5), 0, 2)))' 'f(a)
    i = 0
    s = 0
    loop i < len(a)
        i = i + 1
        s = s + a[i]
    return s
out(f(array(3)))' 'f(a)
    i = 0
    s = 0
    loop i <= len(a)
        s = s + a[i]
        i = i + 1
    return s
out(f(array(3)))' 'big()
    y = 2
    return y
f(a)
    return a + big() + a
out(f(2305843009213693951))' 'far()
    z = 99
    return z
f(a)
    return a[far()]
out(f(array(3)))' 'out(env(123))' 'out(round("x"))' 'out(len(array(true)))' 'out(len(text(true)))' 'a = array(1)
a[0] = 5
out(sort(a[0]))' 'a = array(1)
a[0] = 5
out(find(a[0], 5))' 'import txt
out(split("a", ""))' 'import json
a = array(1)
a[0] = a
out(stringify(a))' 'n = 2305843009213693951 + 1
out(len(text(n)))' 'n = 2305843009213693951 - 1
out(len(array(n)))' 'n = 2305843009213693951 * 2 + 1
out(len(bytes(n)))' 'n = 2305843009213693951 + 1
out(len(pad("x", n, 32)))' 'out(len(bytes(40000000000000)))' 'out(1 << (0 - 1))' 'out(1 >> (0 - 64))' 'a = array(1)
a[0] = a
b = array(1)
b[0] = b
out(a == b)' 'a = {}
a["s"] = a
b = {}
b["s"] = b
out(a == b)' 'm = {}
k = "" . "abc"
m[k] = 1
k[0] = 120' 'm = {}
k = "" . "abc"
m[k] = 1
q = keys(m)
q[0][0] = 120' 'm = {}
k = "" . "abc"
m[k] = 1
k[99] = 120' 's = "hi"
s[99] = 65' 'import json
t = text(2)
t[0] = 97
t[1] = 0 - 5
out(stringify(t))' 't = text(1)
t[0] = 55296
out({a: t})' 'x = array(1)
x[0] = "ab"
m = {}
m[x] = 1' 'f(a, b)
    y = 0
    y = (a + b) & 4294967295
    return y
m = 2305843009213693951
m = m + m + 1
out(f(m, 1))'; do
  printf '%s\n' "$prog" > "$tmp/fault.w"
  "$WORD" build -arm64 "$tmp/fault.w" -o "$tmp/a64" >/dev/null 2>&1 || true
  "$WORD" build        "$tmp/fault.w" -o "$tmp/x86" >/dev/null 2>&1 || true
  chmod +x "$tmp/a64" "$tmp/x86"
  ra=0; $QEMU "$tmp/a64" < /dev/null > "$tmp/out.a64" 2>&1 || ra=$?
  rx=0; "$tmp/x86"       < /dev/null > "$tmp/out.x86" 2>&1 || rx=$?
  if [ "$ra" = "$rx" ] && cmp -s "$tmp/out.a64" "$tmp/out.x86"; then ok=$((ok+1))
  else
    echo "  FAIL (fault): arm64 exit $ra [$(cat "$tmp/out.a64")], x86-64 exit $rx [$(cat "$tmp/out.x86")]"
    fail=$((fail+1))
  fi
done

# net used to be 12,303 lines of hand-written x86-64, so arm64 couldn't build a
# net program. The net library is written in word now (carried in
# compiler/word.w) and bundled into a program that calls a net verb, so these
# have to build for arm64. The refusal path (a64_giveup) is still in the
# compiler for a construct arm64 can't compile, but no program reaches it now.
for prog in 'out(get("http://example.com"))' 'out(post("http://x", "y"))' 'out(head("http://x"))'; do
  printf '%s\n' "$prog" > "$tmp/un.w"
  rm -f "$tmp/a64"
  if "$WORD" build -arm64 "$tmp/un.w" -o "$tmp/a64" >"$tmp/err" 2>&1 && [ -f "$tmp/a64" ]; then
    ok=$((ok+1))
  else
    echo "  FAIL: arm64 could not build a net program: $prog -- $(head -1 "$tmp/err")"
    fail=$((fail+1))
  fi
done

# Big frames, on both targets. A scope held at most 256 names, and past that
# arm64 had three faults nobody could reach: a frame of 4096 bytes or more was
# never allocated (`sub sp, sp, x9` read register 31 as xzr), a frame slot past
# 4095 was set to its own offset instead of the word for 0, and an argument
# slot past 4095 would not assemble. Each program prints its answer, and both
# targets must print that answer.
big() { # <name> <expected output> <awk program that writes the source>
  awk "$3" > "$tmp/big.w"
  "$WORD" build -arm64 "$tmp/big.w" -o "$tmp/a64" >"$tmp/err" 2>&1 \
    && "$WORD" build "$tmp/big.w" -o "$tmp/x86" >>"$tmp/err" 2>&1 \
    || { echo "  FAIL (big frame build): $1 -- $(head -1 "$tmp/err")"; fail=$((fail+1)); return; }
  chmod +x "$tmp/a64" "$tmp/x86"
  ra=0; ga=$($QEMU "$tmp/a64" 2>&1) || ra=$?
  rx=0; gx=$("$tmp/x86" 2>&1) || rx=$?
  if [ "$ra" = 0 ] && [ "$rx" = 0 ] && [ "$ga" = "$2" ] && [ "$gx" = "$2" ]; then ok=$((ok+1))
  else echo "  FAIL (big frame): $1 arm64 [$ga] exit $ra, x86-64 [$gx] exit $rx, want [$2]"; fail=$((fail+1)); fi
}
big "300 names at the top level" 44850 'BEGIN{for(i=0;i<300;i++)print "v"i" = "i; print "t = 0"; for(i=0;i<300;i++) print "t = t + v"i; print "out(t)"}'
big "5000 locals in a function" 12497500 'BEGIN{print "f()"; for(i=0;i<5000;i++)print "    v"i" = "i; print "    t = 0"; for(i=0;i<5000;i++) print "    t = t + v"i; print "    return t"; print "out(f())"}'
big "5000 parameters" 4999 'BEGIN{printf "g("; for(i=0;i<5000;i++) printf "%sp%d", (i?", ":""), i; print ")"; print "    return p0 + p4999"; printf "out(g("; for(i=0;i<5000;i++) printf "%s%d", (i?", ":""), i; print "))"}'
big "5000 parameters through a contract hook" 4999 'BEGIN{printf "g("; for(i=0;i<5000;i++) printf "%sp%d", (i?", ":""), i; print ")"; print "    return p0 + p4999"; print "g:before"; print "    return p4999 > 0"; printf "out(g("; for(i=0;i<5000;i++) printf "%s%d", (i?", ":""), i; print "))"}'
big "a 24 KB frame, 200 calls deep" 4498700 'BEGIN{print "f(n)"; for(i=0;i<3000;i++)print "    v"i" = "i; print "    t = 0"; for(i=0;i<3000;i++) print "    t = t + v"i; print "    if n == 0"; print "        return t"; print "    return f(n - 1) + 1"; print "out(f(200))"}'

echo "a64 vs x86-64, same programs: $ok passed, $fail failed"
[ "$fail" = 0 ]
