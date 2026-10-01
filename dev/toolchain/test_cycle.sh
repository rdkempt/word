#!/bin/sh
# test_cycle.sh: what happens to a value that has no end.
#
# A program can build one: `a[0] = a` is an ordinary store and `m["s"] = m` an
# ordinary map write, and nothing in SPEC 3.4 or 3.7 forbids either.
# json.stringify refuses to serialize one. This suite covers what every other
# operation does when it meets one, and they fall into two groups:
#
#   * the ones that walk the value: `==`, `!=`, `<`, `<=`, `>`, `>=` and so
#     `sort` (SPEC 3.3: ordering goes all the way down, like equality),
#     `find`, `out`, `.` and `stringify`. There's nothing finite to walk, so
#     they must stop with a located diagnostic, never a crash or a hang.
#   * the ones that don't: `len`, `kind`, indexing, `keys`, `has` and `copy`
#     (shallow). They must answer normally, since a cycle is an ordinary
#     region with an ordinary length.
#
# Either group behaving like the other is a bug: a hang or a SIGSEGV in the
# first, a surprise fault in the second. `==` on two separately built cycles
# used to be both, with `stack exhausted` on x86-64 and signal 11 on arm64,
# which SPEC 10.2 rules out.
#
# Every case runs under a timeout and its exit code is checked for a signal, so
# a crash or a hang fails the case.
#
# No `set -e`, since several cases exit 70.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"
cd "$root"
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 20"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1 -- $2"; }
p="$tmp/p.w"; exe="$tmp/p"; gen="$tmp/gen.w"

# Nothing here pipes into a helper, since a helper on the right of a pipe runs
# in a subshell and its counters would be lost. Programs go through $gen.

# Shared prologues. The cycles have to be built separately: two names for one
# cycle are equal without recursing, because an element that's the same word
# as the one it's compared against needs no walk.
ARR='a = array(1)
a[0] = a'
ARR2='b = array(1)
b[0] = b'
MAP='p = {}
p["s"] = p'
MAP2='q = {}
q["s"] = q'

# case_is <name> <expect-rc> <expect-output>: the program is on stdin. Whatever
# else it does, it must not die on a signal or time out.
case_is() { cat > "$p"; nm="$1"; erc="$2"; want="$3"
  if ! "$WORD" build "$p" -o "$exe" >"$tmp/berr" 2>&1; then
    bad "$nm" "did not build: $(head -1 "$tmp/berr")"; return; fi
  got=$($TO "$exe" 2>&1 </dev/null); rc=$?
  if [ "$rc" -ge 128 ] 2>/dev/null; then
    bad "$nm" "SIGNAL (exit $rc): a cycle must never crash the program"; return; fi
  if [ "$rc" = 124 ]; then bad "$nm" "timed out: a cycle must never hang"; return; fi
  if [ "$rc" = "$erc" ] && [ "$got" = "$want" ]; then ok "$nm"; return; fi
  bad "$nm" "got [$(printf '%s' "$got" | tr '\n' '|')] rc=$rc, want [$(printf '%s' "$want" | tr '\n' '|')] rc=$erc"; }

# refused <name> <substring>: builds, then faults with $2, located, exit 70.
refused() { cat > "$p"; nm="$1"; sub="$2"
  if ! "$WORD" build "$p" -o "$exe" >"$tmp/berr" 2>&1; then
    bad "$nm" "did not build: $(head -1 "$tmp/berr")"; return; fi
  got=$($TO "$exe" 2>&1 </dev/null); rc=$?
  if [ "$rc" -ge 128 ] 2>/dev/null; then
    bad "$nm" "SIGNAL (exit $rc): must be a diagnostic, not a crash"; return; fi
  if [ "$rc" = 124 ]; then bad "$nm" "timed out: must be a diagnostic, not a hang"; return; fi
  case "$got" in *"$sub"*) m=1;; *) m=0;; esac
  case "$got" in *"p.w:"*) loc=1;; *) loc=0;; esac
  if [ "$m" = 1 ] && [ "$rc" = 70 ] && [ "$loc" = 1 ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc (want located [$sub], rc=70)"; fi; }

CMP="comparison nests too deeply (a cycle?)"
JSN="json: value nests too deeply (a cycle?)"

echo "== building one is ordinary =="
printf '%s\nout(len(a))\nout(kind(a))\nout(len(a[0]))\nout(len(a[0][0][0][0]))\n' "$ARR" > "$gen"
case_is "an array that holds itself" 0 '1
array
1
1' < "$gen"

printf '%s\nout(len(p))\nout(kind(p))\nout(keys(p)[0])\nout(has(p, "s"))\nout(len(p["s"]))\nout(p["s"] == p)\n' "$MAP" > "$gen"
case_is "a map that holds itself" 0 '1
map
s
true
1
true' < "$gen"

printf 'a = array(1)\nb = array(1)\na[0] = b\nb[0] = a\nout(len(a) . " " . len(a[0][0][0]))\n' > "$gen"
case_is "two arrays that hold each other" 0 '1 1' < "$gen"

echo "== the walks: == and != have nothing finite to compare =="
printf '%s\n%s\nout(a == b)\n' "$ARR" "$ARR2" > "$gen"
refused "two independently built array cycles" "$CMP" < "$gen"
printf '%s\n%s\nout(a != b)\n' "$ARR" "$ARR2" > "$gen"
refused "!= is the same walk" "$CMP" < "$gen"
printf '%s\n%s\nout(p == q)\n' "$MAP" "$MAP2" > "$gen"
refused "two independently built map cycles" "$CMP" < "$gen"
printf 'a = array(1)\nb = array(1)\na[0] = b\nb[0] = a\nc = array(1)\nd = array(1)\nc[0] = d\nd[0] = c\nout(a == c)\n' > "$gen"
refused "two mutual cycles" "$CMP" < "$gen"
printf 'a = array(1)\na[0] = array(1)\na[0][0] = a\nb = array(1)\nb[0] = array(1)\nb[0][0] = b\nout(a == b)\n' > "$gen"
refused "a cycle one level down" "$CMP" < "$gen"
printf 'a = array(2)\na[0] = 7\na[1] = a\nb = array(2)\nb[0] = 7\nb[1] = b\nout(a == b)\n' > "$gen"
refused "a cycle the walk reaches after a matching prefix" "$CMP" < "$gen"
printf '%s\nm = {}\nm["v"] = a\n%s\nn = {}\nn["v"] = b\nout(m == n)\n' "$ARR" "$ARR2" > "$gen"
refused "a cycle behind a map value" "$CMP" < "$gen"
printf '%s\nm = {}\nm["v"] = array(1)\nm["v"][0] = a\n%s\nn = {}\nn["v"] = array(1)\nn["v"][0] = b\nout(m == n)\n' "$ARR" "$ARR2" > "$gen"
refused "a cycle behind a map value behind an array" "$CMP" < "$gen"
printf '%s\n%s\nout(find(a, b))\n' "$ARR" "$ARR2" > "$gen"
refused "find(), which matches elements by value" "$CMP" < "$gen"

echo "== the walks: ordering goes all the way down too =="
# SPEC 3.3 orders the element pair that decides a lexicographic comparison by
# content, not by its words, and `sort` orders by the same comparison. So the
# four ordering operators and sort walk the way == does and meet a cycle the
# same way, and SPEC 10.2 lists them together. They share rt_order's walk but
# read its answer differently (order_imm), and a condition branches on it
# through another path (order_jfalse), so each one is tested. These cases came
# with PR #226, which changed region ordering from element words to content.
printf '%s\n%s\nout(a < b)\n' "$ARR" "$ARR2" > "$gen"
refused "< on two independently built cycles" "$CMP" < "$gen"
printf '%s\n%s\nout(a <= b)\n' "$ARR" "$ARR2" > "$gen"
refused "<= is the same walk" "$CMP" < "$gen"
printf '%s\n%s\nout(a > b)\n' "$ARR" "$ARR2" > "$gen"
refused "> is the same walk" "$CMP" < "$gen"
printf '%s\n%s\nout(a >= b)\n' "$ARR" "$ARR2" > "$gen"
refused ">= is the same walk" "$CMP" < "$gen"
printf '%s\n%s\nif a >= b\n    out("yes")\nout("no")\n' "$ARR" "$ARR2" > "$gen"
refused "an ordering asked as a condition" "$CMP" < "$gen"
printf 'a = array(1)\nb = array(1)\na[0] = b\nb[0] = a\nc = array(1)\nd = array(1)\nc[0] = d\nd[0] = c\nout(a < c)\n' > "$gen"
refused "ordering two mutual cycles" "$CMP" < "$gen"
printf 'a = array(1)\na[0] = array(1)\na[0][0] = a\nb = array(1)\nb[0] = array(1)\nb[0][0] = b\nout(a < b)\n' > "$gen"
refused "ordering a cycle one level down" "$CMP" < "$gen"
printf 'a = array(2)\na[0] = 7\na[1] = a\nb = array(2)\nb[0] = 7\nb[1] = b\nout(a < b)\n' > "$gen"
refused "ordering a cycle the walk reaches after a matching prefix" "$CMP" < "$gen"
printf '%s\n%s\nh = array(2)\nh[0] = a\nh[1] = b\nout(len(sort(h)))\n' "$ARR" "$ARR2" > "$gen"
refused "sort() over a region of two independently built cycles" "$CMP" < "$gen"

echo "== the walks: rendering one is refused, and says so the same way =="
printf '%s\nout(a)\n' "$ARR" > "$gen"
refused "out() of a cyclic array" "$JSN" < "$gen"
printf '%s\nout("x" . a)\n' "$ARR" > "$gen"
refused ". of a cyclic array" "$JSN" < "$gen"
printf '%s\nout(stringify(a))\n' "$ARR" > "$gen"
refused "stringify() of a cyclic array" "$JSN" < "$gen"
printf '%s\nout(stringify(p))\n' "$MAP" > "$gen"
refused "stringify() of a cyclic map" "$JSN" < "$gen"
printf '%s\nm = {}\nm["v"] = a\nout(m)\n' "$ARR" > "$gen"
refused "out() of a map holding one" "$JSN" < "$gen"

echo "== and what a walk DOES answer, it answers without recursing =="
# An element that's the same word as the one it's compared against is equal
# without a walk, so a cycle can be compared with itself.
printf '%s\n%s\nout((a == a) . " " . (p == p) . " " . (a != a))\n' "$ARR" "$MAP" > "$gen"
case_is "a cycle equals itself, however it is tangled" 0 'true true false' < "$gen"
printf '%s\nout(a == copy(a))\n' "$ARR" > "$gen"
case_is "and equals a shallow copy of itself, for the same reason" 0 'true' < "$gen"
printf '%s\nout(a == array(1))\n' "$ARR" > "$gen"
case_is "a cycle against a plain array of the same length" 0 'false' < "$gen"
printf '%s\nb = array(2)\nb[0] = b\nout(a == b)\n' "$ARR" > "$gen"
case_is "against one of another length, decided on the length" 0 'false' < "$gen"
printf 'a = array(2)\na[0] = 7\na[1] = a\nb = array(2)\nb[0] = 8\nb[1] = b\nout(a == b)\n' > "$gen"
case_is "against one that differs before the walk gets there" 0 'false' < "$gen"
printf '%s\n%s\nout(a == p)\n' "$ARR" "$MAP" > "$gen"
case_is "a cyclic array against a cyclic map is a kind mismatch" 0 'false' < "$gen"
printf '%s\nout(find(a, a))\n' "$ARR" > "$gen"
case_is "find() of a cycle in itself hits at 0" 0 '0' < "$gen"
# Ordering takes the same shortcut, so a cycle orders against itself, and a
# sort whose comparisons only ever meet the one cycle finishes. A pair decided
# before the walk reaches a cycle (by an element or by the length) is decided
# there, as it is for ==.
printf '%s\nout((a < a) . " " . (a <= a) . " " . (a > a) . " " . (a >= a))\n' "$ARR" > "$gen"
case_is "a cycle orders against itself without a walk" 0 'false true false true' < "$gen"
printf '%s\nh = array(2)\nh[0] = a\nh[1] = a\nout(len(sort(h)) . " " . (sort(h)[0] == a))\n' "$ARR" > "$gen"
case_is "sort() over a region holding one cycle twice terminates" 0 '2 true' < "$gen"
printf 'a = array(2)\na[0] = 7\na[1] = a\nb = array(2)\nb[0] = 8\nb[1] = b\nout((a < b) . " " . (a > b))\n' > "$gen"
case_is "an ordering decided before the walk reaches the cycle" 0 'true false' < "$gen"
printf '%s\nout((array(0) < a) . " " . (a > array(0)))\n' "$ARR" > "$gen"
case_is "an ordering against an empty region, decided on the length" 0 'true true' < "$gen"

echo "== the operations that do not walk answer normally =="
# copy is shallow (SPEC 9): the element words are copied, so the copy's element
# still points at the original, and the copy isn't itself a cycle. It's
# content-equal to one, though, and all of these answer without a walk because
# each comparison's elements are the same word. There's no identity comparison
# in the language (SPEC 3.3), so a program can't ask whether the copy is a
# cycle. What it can see is that copying one finishes.
printf '%s\nc = copy(a)\nout(len(c) . " " . (c[0] == a) . " " . (c[0] == c) . " " . (c == a))\n' "$ARR" > "$gen"
case_is "copy() of a cyclic array is shallow and terminates" 0 '1 true true true' < "$gen"
printf '%s\nc = copy(p)\nout(len(c) . " " . (c["s"] == p) . " " . (c["s"] == c) . " " . (c == p))\n' "$MAP" > "$gen"
case_is "copy() of a cyclic map is shallow and terminates" 0 '1 true true true' < "$gen"
# sort isn't in this group: it orders by content, so it walks (see above). It
# never looks at an element it has no pair for, though, so a region holding
# one cycle sorts without meeting it.
printf '%s\nh = array(1)\nh[0] = a\nout(len(sort(h)))\n' "$ARR" > "$gen"
case_is "sort() of a one-element region holding a cycle" 0 '1' < "$gen"
printf '%s\nh = array(2)\nh[0] = 1\nh[1] = a\nout(find(h, a))\n' "$ARR" > "$gen"
case_is "find() of a cycle by identity in a plain region" 0 '1' < "$gen"
printf '%s\nout(len(keys(p)) . " " . has(p, "s") . " " . has(p, "z") . " " . (p["z"] == none))\n' "$MAP" > "$gen"
case_is "keys/has/[] over a cyclic map" 0 '1 true false true' < "$gen"

echo "== a finite structure, however deep, is still compared =="
printf 'build(d)\n    x = array(1)\n    cur = x\n    i = 0\n    loop i < d\n        n = array(1)\n        cur[0] = n\n        cur = n\n        i = i + 1\n    return x\n\na = build(200)\nb = build(200)\nc = build(201)\nout((a == b) . " " . (a == c))\n' > "$gen"
case_is "two 200-deep finite structures compare by content" 0 'true false' < "$gen"

# ---------------------------------------------------------------------------
# arm64 has to say the same things. Its rt_eq used to have no stack guard, so
# these refusals were signal 11 there. Each one runs on both targets.
# ---------------------------------------------------------------------------
QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
if [ -n "$QEMU" ]; then
  echo "== arm64 answers each of them the same way =="
  both() { nm="$1"
    cp "$gen" "$p"
    if ! "$WORD" build -arm64 "$p" -o "$tmp/a64" >"$tmp/berr" 2>&1; then
      bad "arm64: $nm" "did not build for arm64: $(head -1 "$tmp/berr")"; return; fi
    if ! "$WORD" build "$p" -o "$exe" >"$tmp/berr" 2>&1; then
      bad "arm64: $nm" "did not build for x86-64"; return; fi
    chmod +x "$tmp/a64"
    oa=$($TO $QEMU "$tmp/a64" 2>&1 </dev/null); ra=$?
    ox=$($TO "$exe" 2>&1 </dev/null); rx=$?
    if [ "$ra" -ge 128 ] 2>/dev/null; then
      bad "arm64: $nm" "SIGNAL (exit $ra) on arm64"; return; fi
    if [ "$oa" = "$ox" ] && [ "$ra" = "$rx" ]; then ok "arm64: $nm [$(printf '%s' "$oa" | tr '\n' '|' | cut -c1-60)]"
    else bad "arm64: $nm" "arm64 [$oa] rc=$ra, x86-64 [$ox] rc=$rx"; fi; }

  printf '%s\n%s\nout(a == b)\n' "$ARR" "$ARR2" > "$gen"; both "two array cycles"
  printf '%s\n%s\nout(a != b)\n' "$ARR" "$ARR2" > "$gen"; both "two array cycles, !="
  printf '%s\n%s\nout(p == q)\n' "$MAP" "$MAP2" > "$gen"; both "two map cycles"
  printf 'a = array(1)\nb = array(1)\na[0] = b\nb[0] = a\nc = array(1)\nd = array(1)\nc[0] = d\nd[0] = c\nout(a == c)\n' > "$gen"; both "two mutual cycles"
  printf '%s\n%s\nout(find(a, b))\n' "$ARR" "$ARR2" > "$gen"; both "find() across two cycles"
  printf '%s\n%s\nout(a < b)\n' "$ARR" "$ARR2" > "$gen"; both "two array cycles, <"
  printf '%s\n%s\nout(a <= b)\n' "$ARR" "$ARR2" > "$gen"; both "two array cycles, <="
  printf '%s\n%s\nout(a > b)\n' "$ARR" "$ARR2" > "$gen"; both "two array cycles, >"
  printf '%s\n%s\nout(a >= b)\n' "$ARR" "$ARR2" > "$gen"; both "two array cycles, >="
  printf '%s\n%s\nif a >= b\n    out("yes")\nout("no")\n' "$ARR" "$ARR2" > "$gen"; both "an ordering asked as a condition"
  printf '%s\n%s\nh = array(2)\nh[0] = a\nh[1] = b\nout(len(sort(h)))\n' "$ARR" "$ARR2" > "$gen"; both "sort() over two cycles"
  printf '%s\nout((a < a) . " " . (a <= a) . " " . (a > a) . " " . (a >= a))\n' "$ARR" > "$gen"; both "a cycle orders against itself"
  printf '%s\nh = array(2)\nh[0] = a\nh[1] = a\nout(len(sort(h)))\n' "$ARR" > "$gen"; both "sort() over one cycle twice"
  printf '%s\nout(stringify(a))\n' "$ARR" > "$gen"; both "stringify of a cycle"
  printf '%s\n%s\nout((a == a) . " " . (p == p))\n' "$ARR" "$MAP" > "$gen"; both "a cycle equals itself"
  printf '%s\nc = copy(a)\nout(len(c) . " " . (c[0] == a))\n' "$ARR" > "$gen"; both "copy of a cycle"
  printf '%s\nout(len(a) . " " . kind(a) . " " . len(a[0][0]))\n' "$ARR" > "$gen"; both "len/kind/index of a cycle"
else
  echo "  (skipping the arm64 half: no qemu-aarch64)"
fi

echo
echo "test_cycle: $pass passed, $fail failed"
[ "$fail" = 0 ]
