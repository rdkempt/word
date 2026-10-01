#!/bin/sh
# test_float.sh: the floating-point conformance suite (docs/VALUE_MODEL.md: tag
# 010 is a boxed IEEE-754 double). It checks literals, the int/float promotion
# rules, comparison across the two, printing, `.`-join, and that the
# integer-only operators reject a float. Every case is a known answer.
#
# No `set -e`, since some cases are meant to fault.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 20"
p="$tmp/p.w"; exe="$tmp/p"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  OK   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1 -- $2"; }

# eval NAME EXPR EXPECTED : build+run `out(EXPR)`, compare stdout.
ev() { printf 'out(%s)\n' "$2" > "$p"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then bad "$1" "build failed: $("$WORD" build "$p" -o "$exe" 2>&1)"; return; fi
  got=$($TO "$exe" 2>&1); rc=$?
  if [ "$got" = "$3" ] && [ "$rc" = 0 ]; then ok "$1"
  else bad "$1" "$2 -> [$got] rc=$rc want [$3]"; fi; }

# prog NAME EXPECTED : build+run the program on stdin, compare stdout. It's
# defined here, next to ev, because the first case that uses it comes early:
# under `sh`, calling a function before its definition is "prog: not found",
# and without `set -e` that case just didn't run.
prog() { cat > "$p"; nm="$1"; want="$2"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then bad "$nm" "build failed"; return; fi
  got=$($TO "$exe" 2>&1); rc=$?
  if [ "$got" = "$want" ] && [ "$rc" = 0 ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc want [$want]"; fi; }

echo "== literals and printing =="
echo "== exponent notation, and a float literal's own range =="
# A float literal used to have no exponent form, and its mantissa was checked
# against the integer maximum, so 900000000000000000.0 was "number literal is
# out of range". The two grammars are separate now: an integer literal keeps
# its range, and a float literal is decimal digits with an optional exponent,
# read as an IEEE-754 double.
ev "1e6"                "1e6"         "1000000.0"
ev "capital E"          "1E3"         "1000.0"
ev "explicit plus"      "1e+3"        "1000.0"
ev "negative exponent"  "1e-3"        "0.001"
ev "mantissa and exponent" "2.5e3"    "2500.0"
ev "exponent folds exactly" "1e6 == 1000000.0"  "true"

# A value below one has no integer digits, and out() used to spend its whole
# fifteen-place budget on the zeros between the point and the first significant
# digit. Anything under 1e-15 printed as `0.0`, and then compared unequal to
# the 0.0 it had printed as.
#
# The digits count from the first significant one now. It's plain decimal at
# both ends of the range (1e308 prints as its 309 digits), so the notation
# never changes with magnitude.
ev "a small value is not zero"      "1.5e-20 == 0.0"  "false"
ev "and does not print as zero"     "1.5e-20"         "0.000000000000000000015"
ev "the last place that always worked" "1e-15"        "0.000000000000001"
ev "one past it"                    "1e-16"           "0.0000000000000001"
ev "0.1 with an exponent"           "1e-7"            "0.0000001"

# The last digit used to be rounded by adding half its place value, worked out
# as 0.5 / 10^k, and for k this large 10^k is inf, so nothing was added and
# 1e-300 printed as 9.9999999999999e-301. Every digit comes from the value's
# exact decimal expansion now (the section after this one).
ev "a power of ten near the bottom" '("" . 1e-300) != "0.0"'  "true"
# number() reads back what out() writes (SPEC 9), so a small value has to come
# back as the double you started with. It couldn't when the text said 0.0, and
# 1e-300 couldn't until number() gave the nearest double to its digits.
ev "printing a small value keeps it" "number(\"\" . 1.5e-20) == 1.5e-20"  "true"
ev "and the last place that worked"  "number(\"\" . 1e-15) == 1e-15"      "true"
ev "and so does 1e-300"              "number(\"\" . 1e-300) == 1e-300"    "true"

# What already worked has to keep working, to the byte.
ev "a half is still a half"         "0.5"             "0.5"
ev "a third is unchanged"           "1.0 / 3.0"       "0.33333333333333"
ev "and the classic sum"            "0.1 + 0.2"       "0.3"
ev "negative folds exactly" "1e-3 == 0.001"     "true"
ev "18 digits before the point" "900000000000000000.0 == 9.0e17" "true"
ev "past the double's range is inf"  "1e400 > 1e308"  "true"
ev "past it downward is zero"        "1e-400 == 0.0"  "true"
ev "1e300 is not saturated"          "1e300 > 1e299"  "true"
ev "an integer literal keeps its range" "1e0 == 1.0"  "true"

echo "== a magnitude past 2^63 prints its own value =="
# The hardware conversion saturates past 2^63, so 1e25 used to print as
# 9223372036854775808.0. A value that large is always a whole number, so the
# renderer expands its bits in decimal instead.
ev "1e19"      "1e19"       "10000000000000000000.0"
ev "1e25"      "1e25"       "10000000000000000000000000.0"
ev "negative"  "0 - 1e25"   "-10000000000000000000000000.0"
ev "1.5e30"    "1.5e30"     "1500000000000000000000000000000.0"
ev "15 significant digits are kept" "1.23456789012345e25" "12345678901234500000000000.0"
ev "2^53 exactly, on the old path"  "9007199254740992.0"  "9007199254740992.0"
ev "the boundary itself"            "1e18"                "1000000000000000000.0"

echo "== the printed digits are the value's own, rounded =="
# out() writes each float to the digit count SPEC 2.6 gives its size, and the
# last digit has to be the value's exact decimal expansion rounded half up at
# that place. The digits used to come out of a loop that multiplied the
# fraction by ten, with half the last place added first to make truncation
# round. Each multiply rounds, so over the digits of 1e-300 the error added up,
# and below about 1e-310 the half place itself was 0.0, so nothing was added:
# 5e-324 printed its fourteenth digit as 4 where it's 5, and 1e-310 as
# 0.000...99999999999999. Even 1.701209642251575 came out ...157, and the exact
# tie 9897760009307.375 as .37. Now every finite value is expanded exactly, in
# decimal, from its bits, as values past 2^63 already were. The four largest
# doubles are the exception: they're cut off at 15 digits, since rounded up
# they'd print as a number past the largest double (test_json.sh has why).
#
# The same program runs on both targets. z(n) is n zeros.
cat > "$tmp/digits.w" <<'EOF'
z(n)
    s = ""
    i = 0
    loop i < n
        s = s . "0"
        i = i + 1
    return s
c(x, want)
    got = "" . x
    if got == want
        return "ok"
    return "got " . got
out(c(5e-324, "0." . z(323) . "49406564584125"))
out(c(1e-310, "0." . z(309) . "1"))
out(c(3.407282909e-314, "0." . z(313) . "34072829088168"))
out(c(2.2250738585072014e-308, "0." . z(307) . "22250738585072"))
out(c(1.3078283781440507e-304, "0." . z(303) . "13078283781441"))
out(c(1e-300, "0." . z(299) . "1"))
out(c(1.701209642251575, "1.70120964225158"))
out(c(0.382836048166705, "0.38283604816671"))
out(c(9897760009307.375, "9897760009307.38"))
out(c(4833349985693.625, "4833349985693.63"))
out(c(4.76837158203125e-07, "0.00000047683715820313"))
out(c(1.000030517578125, "1.00003051757813"))
out(c(0.9999999999999999, "1.0"))
out(c(9.999999999999998, "10.0"))
out(c(0.09999999999999999, "0.1"))
out(c(1.0 / 3.0, "0.33333333333333"))
out(c(1.5e-20, "0.000000000000000000015"))
out(c(123456789012345.67, "123456789012345.7"))
out(c(1234567890123456789.0, "1234567890123456768.0"))
out(c(9.999999999999999e22, "1" . z(23) . ".0"))
out(c(1e308, "1" . z(308) . ".0"))
out(c(1.7976931348623157e308, "179769313486231" . z(294) . ".0"))
out(c(0.0 - 5e-324, "-0." . z(323) . "49406564584125"))
EOF
QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
want=$(printf 'ok\n%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23)
for tgt in x86 arm64; do
  [ "$tgt" = arm64 ] && [ -z "$QEMU" ] && { echo "  SKIP the printed digits (arm64): no qemu-aarch64"; continue; }
  fl=""; run=""; [ "$tgt" = arm64 ] && { fl=-arm64; run=$QEMU; }
  if "$WORD" build $fl "$tmp/digits.w" -o "$tmp/digits.$tgt" >/dev/null 2>&1; then
    got=$($TO $run "$tmp/digits.$tgt" 2>&1); rc=$?
    if [ "$got" = "$want" ] && [ "$rc" = 0 ]; then ok "every printed digit is the value's own, rounded ($tgt)"
    else bad "the printed digits ($tgt)" "[$(echo "$got" | grep -v '^ok$' | cut -c1-80 | tr '\n' '|')] rc=$rc"; fi
  else bad "the printed digits ($tgt)" "build failed"; fi
done

ev "3.14 prints"        "3.14"        "3.14"
ev "2.0 keeps the point" "2.0"        "2.0"
ev "0.5"                "0.5"         "0.5"
ev "0.1 trims noise"    "0.1"         "0.1"
ev "0.0"                "0.0"         "0.0"
ev "0.001"              "0.001"       "0.001"
ev "123.456"            "123.456"     "123.456"

echo "== arithmetic (float) =="
ev "1.5 + 2.5"          "1.5 + 2.5"   "4.0"
ev "3.14 * 2.0"         "3.14 * 2.0"  "6.28"
ev "10.0 / 4.0"         "10.0 / 4.0"  "2.5"
ev "1.0 / 8.0"          "1.0 / 8.0"   "0.125"
ev "0.1 + 0.2 rounds"   "0.1 + 0.2"   "0.3"
ev "9.99 + 0.01"        "9.99 + 0.01" "10.0"
ev "unary minus float"  "0.0 - 5.5"   "-5.5"
ev "1/3 to 15 digits"   "1.0 / 3.0"   "0.33333333333333"
ev "float div by zero"  "1.0 / 0.0"   "inf"

echo "== integer / float promotion =="
ev "int + float -> float" "2 + 0.5"   "2.5"
ev "float + int -> float" "0.5 + 2"   "2.5"
ev "float - int -> float" "1.0 - 2"   "-1.0"
ev "float * int -> float" "1.0 * 2"   "2.0"
ev "int * float -> float" "2 * 1.0"   "2.0"
ev "float / int -> float" "6.0 / 2"   "3.0"
ev "int / float -> float" "6 / 2.0"   "3.0"
# `/` is exact (SPEC 3.3): two integers give an integer when the division comes
# out even, and a float when it doesn't. There's no integer-division operator:
# the whole part is `(a - a % b) / b`, which always divides evenly and so stays
# an integer, and a power of two is a shift.
ev "int / int, exact"     "6 / 2"     "3"
ev "int / int, inexact"   "7 / 2"     "3.5"
ev "the whole part stays an integer"  "(7 - 7 % 2) / 2" "3"
ev "and toward zero for a negative"   "((0 - 7) - (0 - 7) % 2) / 2" "-3"

echo "== number() reads back what out() writes =="
# `.` and out() write a float and json.parse reads one. number() used to read
# integers only, so `out(1 / 2)` wrote 0.5 and number("0.5") answered none.
ev "number of an integer"        'number("42")'      "42"
ev "number of a decimal"         'number("3.5")'     "3.5"
ev "number of a negative decimal" 'number("-2.25")'  "-2.25"
ev "number with no integer part" 'number(".5")'      "0.5"
ev "number with an exponent"     'number("1e3")'     "1000.0"
ev "number with a signed exponent" 'number("2.5e-2")' "0.025"
ev "the round trip closes"       'number("" . (1 / 2))' "0.5"
ev "a trailing dot is not a number" 'number("1.") == none'   "true"
ev "a bare exponent is not one"     'number("1e") == none'   "true"
# An exponent needs a number in front of it to scale. These answered 0.0.
ev "an exponent alone is not one"   'number("e5") == none'   "true"
ev "nor with a capital E"           'number("E5") == none'   "true"
ev "nor after a minus"              'number("-e5") == none'  "true"
ev "nor with a signed exponent"     'number("e+5") == none'  "true"
ev "nor after a lone point"         'number(".e5") == none'  "true"
ev "a fraction still scales"        'number(".5e1")'         "5.0"
ev "two dots are not one"           'number("1.5.5") == none' "true"
ev "trailing text is not one"       'number("1.5abc") == none' "true"
# number() and json.parse use the same scaler, so the same digits have to give
# the same double. (ev() writes a bare expression, so this case, which needs an
# import, is written out.)
prog "number agrees with json.parse, digit for digit" "true true true" <<'EOF'
import json
d = parse("{\"a\":3.14,\"b\":0.1,\"c\":2.5e-2}")
out((number("3.14") == d["a"]) . " " . (number("0.1") == d["b"]) . " " . (number("2.5e-2") == d["c"]))
EOF
ev "int + int stays int"  "2 + 3"     "5"

echo "== comparison across kinds =="
ev "1 == 1.0"           "1 == 1.0"    "true"
ev "1.5 == 1.5"         "1.5 == 1.5"  "true"
ev "1.5 != 2.5"         "1.5 != 2.5"  "true"
ev "1.5 < 2"            "1.5 < 2"     "true"
ev "3.14 > 3"           "3.14 > 3"    "true"
ev "2.0 <= 2"           "2.0 <= 2"    "true"
ev "2.5 > 3 is false"   "2.5 > 3"     "false"

echo "== round(): a float to the nearest whole number =="
ev "round up"           "round(3.7)"       "4"
ev "round down"         "round(3.2)"       "3"
ev "round half away"    "round(2.5)"       "3"
ev "round negative half" "round(0.0 - 2.5)" "-3"
ev "round negative"     "round(0.0 - 3.7)" "-4"
ev "round of an int"    "round(5)"         "5"
ev "round returns an integer" "round(2.5) + 1" "4"
# There's no builtin to make a float. Multiplying by 1.0 does it.
ev "promote with * 1.0" "5 * 1.0"          "5.0"
ev "promote a division" "7 * 1.0 / 2"      "3.5"

echo "== the kind test and join =="
ev 'a float is a number'    'kind(3.14) == "number"' "true"
ev 'an integer is too'     'kind(5) == "number"'    "true"
printf 'out("x=" . 1.5)\n' > "$p"
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1 && [ "$($TO "$exe" 2>&1)" = "x=1.5" ]; then
  ok "join with a float"
else bad "join with a float" "[$("$WORD" build "$p" -o "$exe" 2>&1)$($TO "$exe" 2>&1)]"; fi

echo "== a float flows through a function =="
cat > "$p" <<'EOF'
scale(v, factor)
    return v * factor
out(scale(2.5, 4.0))
out(scale(3, 0.5))
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$($TO "$exe" 2>&1)
  if [ "$got" = "10.0
1.5" ]; then ok "float args + return"; else bad "float args + return" "[$got]"; fi
else bad "float args + return" "build failed"; fi

echo "== a whole number is required where a whole number is required =="
printf 'out(3.5 %% 2)\n' > "$p"
"$WORD" build "$p" -o "$exe" >/dev/null 2>&1
out=$($TO "$exe" 2>&1); rc=$?
case "$out" in *"needs whole numbers"*) m=1;; *) m=0;; esac
if [ "$m" = 1 ] && [ "$rc" = 70 ]; then ok "% on a float faults"; else bad "% on a float faults" "[$out] rc=$rc"; fi

# A float index gets its own message (not a bounds error), and round() turns
# it into an index.
printf 'a = text(3)\na[0] = 7\nout(a[1.5])\n' > "$p"
"$WORD" build "$p" -o "$exe" >/dev/null 2>&1
out=$($TO "$exe" 2>&1); rc=$?
case "$out" in *"index must be a whole number"*) m=1;; *) m=0;; esac
if [ "$m" = 1 ] && [ "$rc" = 70 ]; then ok "float index -> clear message"; else bad "float index" "[$out] rc=$rc"; fi

printf 'a = text(3)\na[0] = 7\na[1] = 8\nout(a[round(1.4)])\n' > "$p"
"$WORD" build "$p" -o "$exe" >/dev/null 2>&1
got=$($TO "$exe" 2>&1)
if [ "$got" = "8" ]; then ok "round() as an index (round(1.4)=1 -> a[1])"
else bad "round() as an index" "[$got]"; fi

echo "== box reuse must never be visible =="
# A float value is a boxed double, so `a*b + c*d` would make one box per
# operator, and the arena doesn't free them. Codegen writes a result into the
# left operand's box when that box is a temporary the expression owns (an
# operator result or a freshly boxed literal), and into the target's own box
# for `x = x <op> ...` when the uniqueness pass proves x is unaliased. It's an
# optimization, so what needs testing is that a program can't see it: these
# are the cases where reusing a box someone else holds would change a value.

# The important one: a copy shares the box, so the accumulator path mustn't
# fire here. If it did, b would change with a.
prog "a copied float is not clobbered by the original" "2.5 1.5" <<'EOF'
a = 1.5
b = a
a = a + 1.0
out(a . " " . b)
EOF
prog "the copy direction is safe too" "1.5 2.5" <<'EOF'
a = 1.5
b = a
b = b + 1.0
out(a . " " . b)
EOF
# A float read back out of a region is aliased by the region.
prog "a float taken from an array leaves the array alone" "2.5 1.5" <<'EOF'
arr = text(1)
arr[0] = 1.5
x = arr[0]
x = x + 1.0
out(x . " " . arr[0])
EOF
prog "a float in a map is likewise untouched" "2.5 1.5" <<'EOF'
m = {v: 1.5}
x = m["v"]
x = x + 1.0
out(x . " " . m["v"])
EOF
# Both operands are read before the result is written, so self-reference is fine.
prog "x = x + x" "5.0" <<'EOF'
x = 2.5
x = x + x
out(x)
EOF
prog "x = x + (x * 2.0) reads the old x twice" "6.0" <<'EOF'
x = 2.0
x = x + (x * 2.0)
out(x)
EOF
prog "a chain of reused temps is still exact" "25.0" <<'EOF'
x = 3.0
y = 4.0
out(x * x + y * y)
EOF
# A literal's box is reused as a temp; the same literal used again must be fresh.
prog "reusing a literal's box does not corrupt the literal" "3.5 2.0" <<'EOF'
x = 1.5
a = 2.0 + x
out(a . " " . 2.0)
EOF
prog "the same literal in a loop stays itself" "1.5 1.5 1.5 " <<'EOF'
line = ""
i = 0
loop i < 3
    v = 1.5 * 1
    line = line . (v . " ")
    i = i + 1
out(line)
EOF
# An accumulator is the shape the reuse targets; it must still be exact.
prog "an accumulator loop is exact" "1500000.0" <<'EOF'
s = 0.0
i = 0
loop i < 1000000
    s = s + 1.5
    i = i + 1
out(s)
EOF
# Mixed int/float at the same site: the float path runs only when an operand is
# a float, so the reuse helper must cope with a tagged integer in its slot.
prog "the same site with int and float operands" "5 5.5" <<'EOF'
add(a, b)
    return a + b
out(add(2, 3) . " " . add(2.5, 3))
EOF

echo "== the three-way arithmetic dispatch =="
# `+ - * /` in a program that uses floats has three paths: both operands are
# tagged integers (the inline integer path), both are floats (the inline SSE
# path, no call), or one of each (the helper promotes). One emitted site can
# take all three at run time, since the kind belongs to the value. These drive
# one call site down every path and check the answers match what each path
# alone gives.
prog "one site reached as int+int, float+float and mixed" "5 6.0 5.5 5.5" <<'EOF'
add(a, b)
    return a + b
out(add(2, 3) . " " . add(2.5, 3.5) . " " . add(2.5, 3) . " " . add(2, 3.5))
EOF
prog "every operator down the float path" "6.0 -1.0 8.75 0.7" <<'EOF'
f(a, b, op)
    if op == 0
        return a + b
    if op == 1
        return a - b
    if op == 2
        return a * b
    return a / b
out(f(2.5, 3.5, 0) . " " . f(2.5, 3.5, 1) . " " . f(2.5, 3.5, 2) . " " . f(2.8, 4.0, 3))
EOF
prog "every operator mixed int/float" "5.5 -0.5 7.5 1.25" <<'EOF'
f(a, b, op)
    if op == 0
        return a + b
    if op == 1
        return a - b
    if op == 2
        return a * b
    return a / b
out(f(2.5, 3, 0) . " " . f(2.5, 3, 1) . " " . f(2.5, 3, 2) . " " . f(2.5, 2, 3))
EOF
# The inline path must agree with the helper on the awkward values too.
prog "infinities and NaN survive the inline path" "inf -inf nan" <<'EOF'
z = 0.0
a = 1.0
out((a / z) . " " . ((0 - a) / z) . " " . (z / z))
EOF
prog "float division by an integer zero still gives inf" "inf" <<'EOF'
a = 1.0
b = 0
out(a / b)
EOF
prog "ordering across int and float is unchanged" "true true true true" <<'EOF'
out((1 < 1.5) . " " . (1.5 > 1) . " " . (2.0 == 2) . " " . (2.5 <= 2.5))
EOF

# ---------------------------------------------------------------------------
# A local whose every assignment is statically a float holds the raw double in
# its frame slot instead of a pointer to a box (infer_local_kinds and
# gen_float_expr in the compiler). That makes a float loop allocation-free
# (mandelbrot went from 216 MB and 332 ms to 260 KB and 77 ms), but it means
# one kind of local is stored differently from every other value, and a slot
# written or read the wrong way corrupts a value without a fault. So these
# tests aren't about speed. They check that a program can't tell the raw-double
# slots are there.
#
# Two halves. First, every way a program can observe such a local: printing
# it, joining it, passing it, returning it, storing it in a region or a map,
# sorting it, asking its kind. Each of those reads through the generic path,
# which boxes. Second, every way a local can fail to qualify: assigned an
# integer somewhere, assigned from a call, bound by a for-each, or a parameter.
# Each must fall back to the boxed representation and behave the same.

# dies NAME SUBSTRING : build+run, expect the runtime fault rc=70 and a message.
dies() { cat > "$p"; nm="$1"; want="$2"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then bad "$nm" "build failed"; return; fi
  got=$($TO "$exe" 2>&1); rc=$?
  case "$got" in *"$want"*) m=1;; *) m=0;; esac
  if [ "$m" = 1 ] && [ "$rc" = 70 ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc want a fault containing [$want]"; fi; }

echo "== an unboxed float local is invisible: every way to observe one =="
prog "printed, joined, and compared" "2.5 x2.5y true false" <<'EOF'
a = 2.5
out(a . " " . ("x" . a . "y") . " " . (a == 2.5) . " " . (a == 2))
EOF
prog "passed to a function and returned" "6.25" <<'EOF'
sq(v)
    return v * v
a = 2.5
out(sq(a))
EOF
prog "stored into a region, read back, sorted" "1.5 1.5 2.5 3.5" <<'EOF'
a = 3.5
b = 1.5
c = 2.5
r = text(3)
r[0] = a
r[1] = b
r[2] = c
d = sort(r)
out(r[1] . " " . d[0] . " " . d[1] . " " . d[2])
EOF
prog "used as a map value and a map is printed as JSON" '{"pi":3.5}' <<'EOF'
a = 3.5
m = {}
m["pi"] = a
out(m)
EOF
prog "the kind test and round() answer for the value, not the slot" "true 4 false" <<'EOF'
a = 3.5
s = "x"
out((kind(a) == "number") . " " . round(a) . " " . (kind(s) == "number"))
EOF
prog "an unboxed local is a fine loop bound" "0.0 0.5 1.0 1.5" <<'EOF'
x = 0.0
lim = 2.0
s = ""
loop x < lim
    s = s . x . " "
    x = x + 0.5
out(copy(s, 0, len(s) - 1))
EOF

echo "== a copy is a copy: nothing may write through a slot someone else holds =="
# A boxed float is shared by copying its pointer. An unboxed slot copies the
# double instead, which means the same thing, unless a store goes to the wrong
# place.
prog "b = a then a = ... leaves b alone" "1.5 2.5" <<'EOF'
a = 1.5
b = a
a = 2.5
out(b . " " . a)
EOF
prog "a copy stored in a region survives the original changing" "1.5 9.5" <<'EOF'
a = 1.5
r = text(1)
r[0] = a
a = 9.5
out(r[0] . " " . a)
EOF
prog "a copy passed to a function survives the caller changing it" "1.5 9.5" <<'EOF'
show(v)
    return v
a = 1.5
b = show(a)
a = 9.5
out(b . " " . a)
EOF
prog "self-referential assignment reads the OLD value on both sides" "9.0" <<'EOF'
a = 3.0
a = a * a
out(a)
EOF

echo "== locals that do NOT qualify keep the boxed representation =="
prog "assigned an integer in one branch: stays a runtime dispatch" "7 2.5" <<'EOF'
n = 0
a = 2.5
if n == 0
    a = 7
out(a . " " . 2.5)
EOF
prog "assigned from a call: nothing static is known" "3.5" <<'EOF'
half()
    return 3.5
a = half()
out(a)
EOF
prog "a for-each binding is written by the loop, never unboxed" "1.5 2.5 3.5" <<'EOF'
r = text(3)
r[0] = 1.5
r[1] = 2.5
r[2] = 3.5
s = ""
loop v in r
    s = s . v . " "
out(copy(s, 0, len(s) - 1))
EOF
prog "a parameter owns its slot even when assigned a float inside" "5.0 2.5" <<'EOF'
f(a)
    seen = a
    a = 2.5
    return seen . " " . a
out(f(5.0))
EOF
prog "an integer local divided evenly stays an integer" "7 3" <<'EOF'
i = 6
j = i / 2
out(7 . " " . j)
EOF

prog "an integer local divided unevenly becomes a float" "7 3.5" <<'EOF'
i = 7
j = i / 2
out(i . " " . j)
EOF

prog "the whole part of an integer local stays an integer" "7 3" <<'EOF'
i = 7
j = (i - i % 2) / 2
out(i . " " . j)
EOF

echo "== mixed integer and float locals =="
prog "int local times a float literal promotes" "0.5 -2.5" <<'EOF'
px = 1
w = 7
out((px * 3.5 / w) . " " . (px * 3.5 / w - 3.0))
EOF
prog "a float local plus an integer local" "5.5" <<'EOF'
a = 3.5
b = 2
out(a + b)
EOF
# An integer local carries a static kind, which removes its number checks. The
# overflow trap has to stay.
dies "an integer local still traps overflow" "overflow" <<'EOF'
big = 2305843009213693951
out(big + big + big)
EOF

echo "== NaN and the infinities through the unboxed paths =="
# ucomisd sets the parity flag on an unordered compare, and the branch forms
# have to take it into account: every ordering operator is false against a
# NaN, `==` is false, and `!=` is true. The value form (setcc) and the `if`
# form (jcc) are separate code, so both are tested.
prog "every comparison against NaN, as a value" "false false false false false true" <<'EOF'
z = 0.0
n = z / z
one = 1.0
out((n < one) . " " . (n > one) . " " . (n <= one) . " " . (n >= one) . " " . (n == n) . " " . (n != n))
EOF
prog "every comparison against NaN, as a branch" "lt:no gt:no le:no ge:no eq:no ne:yes" <<'EOF'
z = 0.0
n = z / z
one = 1.0
s = "lt:no"
if n < one
    s = "lt:yes"
t = "gt:no"
if n > one
    t = "gt:yes"
u = "le:no"
if n <= one
    u = "le:yes"
v = "ge:no"
if n >= one
    v = "ge:yes"
w = "eq:no"
if n == n
    w = "eq:yes"
x = "ne:no"
if n != n
    x = "ne:yes"
out(s . " " . t . " " . u . " " . v . " " . w . " " . x)
EOF
# The same questions when the compiler can't see that the operands are floats.
# Then they go to rt_order_float, whose -1/0/1 had no answer for an unordered
# pair: it said -1, so `n < one` and `n <= one` were true on x86-64 (arm64 said
# 0, which made `<=` and `>=` true). The two cases above never reach this path.
prog "every comparison against NaN, as a value, kinds unknown" "false false false false false true" <<'EOF'
z = 0.0
b = array(2)
b[0] = z / z
b[1] = 1.0
n = b[0]
one = b[1]
out((n < one) . " " . (n > one) . " " . (n <= one) . " " . (n >= one) . " " . (n == n) . " " . (n != n))
EOF
prog "every comparison against NaN, as a branch, kinds unknown" "lt:no gt:no le:no ge:no eq:no ne:yes" <<'EOF'
z = 0.0
b = array(2)
b[0] = z / z
b[1] = 1.0
n = b[0]
one = b[1]
s = "lt:no"
if n < one
    s = "lt:yes"
t = "gt:no"
if n > one
    t = "gt:yes"
u = "le:no"
if n <= one
    u = "le:yes"
v = "ge:no"
if n >= one
    v = "ge:yes"
w = "eq:no"
if n == n
    w = "eq:yes"
x = "ne:no"
if n != n
    x = "ne:yes"
out(s . " " . t . " " . u . " " . v . " " . w . " " . x)
EOF
prog "NaN against an integer, either side first, kinds unknown" "false false false false false false false false" <<'EOF'
z = 0.0
b = array(2)
b[0] = z / z
b[1] = 1
n = b[0]
i = b[1]
out((n < i) . " " . (n <= i) . " " . (n > i) . " " . (n >= i) . " " . (i < n) . " " . (i <= n) . " " . (i > n) . " " . (i >= n))
EOF
# `>` and `>=` read the helper's answer differently to make room for NaN's, so
# the ordered answers are tested again, equal ones included, which `>=` reads
# through an unsigned test.
prog "the ordered answers are unchanged, kinds unknown" "true true false false true true true true false true" <<'EOF'
b = array(4)
b[0] = 1.5
b[1] = 2.5
b[2] = 2
b[3] = 1.5
x = b[0]
y = b[1]
i = b[2]
x2 = b[3]
r = ""
if x2 >= x
    r = "true"
out((x < y) . " " . (x <= y) . " " . (x > y) . " " . (x >= y) . " " . (y > i) . " " . (i >= x) . " " . (x >= x2) . " " . (x <= x2) . " " . (x > x2) . " " . r)
EOF
prog "infinities compare and print" "inf -inf true true" <<'EOF'
z = 0.0
a = 1.0
p = a / z
m = (0.0 - a) / z
out(p . " " . m . " " . (p > 1000000.0) . " " . (m < 0.0))
EOF
# `-x` on a float used to negate the tagged pointer to its box and read
# whatever address that gave (a segfault, while `0 - x` was fine). It's a
# sign-bit flip now, which is also the only way to get -0.0 right. -0.0 prints
# as 0.0, so it's checked the one way it shows: 1/-0.0 is -inf.
prog "unary minus on a float, including -0.0" "-3.5 3.5 -inf inf" <<'EOF'
a = 3.5
b = -a
z = 0.0
n = -z
out(b . " " . (0.0 - b) . " " . (1.0 / n) . " " . (1.0 / z))
EOF

echo "== deep and awkward expression shapes =="
# gen_float_pair spills the left operand to the stack only when the right isn't
# a leaf, so a right-nested tree takes a path a left-nested one never does, and
# a deep one takes it many levels down.
prog "right-nested arithmetic (the spill path)" "0.75 true true" <<'EOF'
a = 1.0
b = 2.0
c = 3.0
d = 4.0
out((a / (b / (c / (d / 2.0)))) . " " . (a - (b - (c - d)) == 0.0 - 2.0) . " " . (a * (b + (c * d)) == 14.0))
EOF
prog "left- and right-nested agree with the boxed order of operations" "true true" <<'EOF'
a = 1.5
b = 2.5
c = 3.5
out(((a - b) - c == 0.0 - 4.5) . " " . ((a - (b - c)) == 2.5))
EOF
prog "a comparison whose right side is itself an expression" "true false" <<'EOF'
a = 1.5
b = 2.5
c = 3.5
out((a + b > c - 1.0) . " " . (a + b > c + 1.0))
EOF
prog "a float condition inside a nested loop still terminates" "10" <<'EOF'
i = 0
n = 0
loop i < 10
    x = 0.0
    loop x < 1.0
        x = x + 0.25
    if x >= 1.0
        n = n + 1
    i = i + 1
out(n)
EOF

echo "== the integer-only operators still reject an unboxed float =="
dies "% on a float LOCAL faults" "needs whole numbers" <<'EOF'
a = 3.5
out(a % 2)
EOF
dies "a float local as an index faults" "index must be a whole number" <<'EOF'
a = text(3)
i = 1.5
out(a[i])
EOF
# Written directly this is a compile error (SPEC 10.1 checks a local whose
# assignments agree), so the same mistake goes behind a parameter, where the
# kind is open and the emitted guard has to catch it.
dies "a region a caller passed, in arithmetic, still faults" "number expected" <<'EOF'
g(s)
    return s + 1

out(g("ab"))
EOF

echo "== contracts have their own frame, and their own inference =="
# A before/after hook is emitted into the wrapper's frame, with its own locals
# in its own slots. If it inherited the guarded function's inference, a hook
# local would be judged by a body local that only shares its name, and a
# raw-double store into a slot holding a region corrupts it without a fault.
prog "a hook local shadowing a float body local, with a different kind" "in:ok
5.0" <<'EOF'
f(n)
    x = 2.5
    return x * n

f:before
    x = "ok"
    out("in:" . x)
    return true

out(f(2.0))
EOF
prog "an after hook compares result as a float" "big
9.0" <<'EOF'
f(n)
    return n * n

f:after
    if result > 5.0
        out("big")
    return true

out(f(3.0))
EOF
prog "an after hook with a float local of its own" "0.5
9.0" <<'EOF'
f(n)
    return n * n

f:after
    half = result / 18.0
    out(half)
    return true

out(f(3.0))
EOF
dies "a float guard that fails is still a contract violation" "contract" <<'EOF'
f(n)
    return n * 2.0

f:before
    if n < 0.0
        return false
    return true

out(f(-1.0))
EOF

echo "== a float compare whose other side is an integer expression =="
prog "float local against a computed integer" "true false true" <<'EOF'
x = 5.5
i = 2
out((x > i + 1) . " " . (x < i * 2) . " " . (x >= i + 3))
EOF

echo "== a parameter every caller passes a float to is unboxed too =="
# The local inference stops at the frame boundary: a parameter is written by
# the caller, so proving it a float means seeing every call site. word has no
# function values, so every call names its target and the call graph is exact.
# infer_param_kinds joins each call site's argument kind into the callee's
# parameters and iterates. A parameter that comes out float arrives as a raw
# double (gen_call pushes it raw) and behaves like an unboxed local.
#
# The first cases use an unboxed float parameter every way a program can. The
# rest check that the inference never claims more than it can prove, since
# getting it wrong would store a raw double into a slot the code reads as a
# pointer.
prog "a float parameter, observed every way from inside" "6.25 2.5! true false" <<'EOF'
show(v)
    return (v * v) . " " . (v . "!") . " " . (v == 2.5) . " " . (v > 9.0)
out(show(2.5))
EOF
prog "a float parameter passed on to another function" "6.25" <<'EOF'
sq(v)
    return v * v
outer(v)
    return sq(v)
out(outer(2.5))
EOF
prog "recursion on a float parameter" "0.5" <<'EOF'
down(v)
    if v <= 1.0
        return v
    return down(v - 1.0)
out(down(5.5))
EOF
prog "mutual recursion on a float parameter" "0.25" <<'EOF'
a(v)
    if v <= 1.0
        return v
    return b(v - 1.0)
b(v)
    if v <= 1.0
        return v
    return a(v - 1.0)
out(a(6.25))
EOF
prog "a float parameter stored into a region and a map" "2.5 2.5" <<'EOF'
keep(v)
    r = text(1)
    r[0] = v
    m = {}
    m["k"] = v
    return r[0] . " " . m["k"]
out(keep(2.5))
EOF
prog "two call sites of different kinds: stays boxed, stays right" "6.25 9" <<'EOF'
sq(v)
    return v * v
out(sq(2.5) . " " . sq(3))
EOF
prog "a float parameter assigned an integer inside: stays boxed" "7" <<'EOF'
f(v)
    v = 7
    return v
out(f(2.5))
EOF
prog "a float parameter assigned a region inside: stays boxed" "hi" <<'EOF'
f(v)
    v = "hi"
    return v
out(f(2.5))
EOF
prog "an integer parameter is proved too, and still traps overflow" "5" <<'EOF'
add1(n)
    return n + 1
out(add1(4))
EOF
prog "a region parameter indexes without a check and still reads right" "98" <<'EOF'
second(p)
    return p[1]
out(second("abc"))
EOF
# A parameter can end the sweep undecided: these two functions are only called
# by each other, so no call site gives `v` a kind. That has to settle to
# "assume nothing" instead of staying at the internal -1, which no codegen path
# can read. The hook on `a` keeps the pair in the program, since a function
# nothing reaches is an error (SPEC 10.1) and a call from inside the pair
# doesn't count.
prog "a parameter no call site ever grounds settles to assuming nothing" "1" <<'EOF'
a(v)
    return b(v)
b(v)
    if v > 0
        return 0
    return a(v)
a:before
    return true
out(1)
EOF
# The wrapper's parameter slots hold whatever the caller pushed, which for a
# proved-float parameter is the raw double, so the hook has to read it the way
# the body does. Reading it as a tagged word would take the double's bits for a
# pointer.
prog "a contract hook reads the tagged parameter, the body the raw one" "guard:2.5
6.25" <<'EOF'
sq(v)
    return v * v

sq:before
    out("guard:" . v)
    return true

out(sq(2.5))
EOF
prog "an after hook on a function with a float parameter" "big
6.25" <<'EOF'
sq(v)
    return v * v

sq:after
    if result > 5.0
        out("big")
    return true

out(sq(2.5))
EOF
dies "a float parameter is still rejected where a whole number is required" "index must be a whole number" <<'EOF'
at(p, i)
    return p[i]
a = text(3)
out(at(a, 1.5))
EOF
# With the parameters unboxed and the return proved float, the callee allocates
# nothing. The whole-program pass proves dist() returns a float on every path,
# so the answer comes back raw in xmm0 instead of in a box. Before return kinds
# there was one box per call, and a regression there would only show in the
# arena, so the check is for zero.
#
# The second argument is an expression, so the one-line inliner (which takes a
# parameter read twice only when its argument is a name or a literal) leaves
# this a real call, and the callee is what gets checked.
cat > "$p" <<'EOF'
dist(x, y)
    return x * x + y * y
i = 0
c = 0
loop i < 10
    a = i * 0.5
    if dist(a, a + 0.5) > 1.0
        c = c + 1
    i = i + 1
out(c)
EOF
if "$WORD" build -asm "$p" > "$tmp/pd.s" 2>/dev/null; then
  body=$(awk '/^fn_dist:/{on=1} on{print} on && /^    ret$/{exit}' "$tmp/pd.s")
  nb=$(printf '%s\n' "$body" | grep -c 'call rt_box_float')
  nh=$(printf '%s\n' "$body" | grep -c 'call rt_f')
  nm=$(printf '%s\n' "$body" | grep -c 'mulsd')
  if [ "$nm" = 0 ]; then bad "float parameter codegen" "no fn_dist body in the -asm dump"
  elif [ "$nb" = 0 ] && [ "$nh" = 0 ]; then ok "the callee allocates nothing: no box for the result, no float helper"
  else bad "float parameter codegen" "$nb rt_box_float (want 0) and $nh float-helper calls (want 0)"; fi
else bad "float parameter codegen" "-asm dump failed"; fi
# With names for arguments the call is gone: `dist(a, b)` becomes
# `a * a + b * b`, evaluated in xmm registers where it's written, with no call
# and no box.
cat > "$p" <<'EOF'
dist(x, y)
    return x * x + y * y
i = 0
c = 0
loop i < 10
    a = i * 0.5
    b = a + 0.5
    if dist(a, b) > 1.0
        c = c + 1
    i = i + 1
out(c)
EOF
if "$WORD" build -asm "$p" > "$tmp/pi.s" 2>/dev/null; then
  top=$(awk '/^fn__toplevel:/{on=1} on{print} on && /^    ret$/{exit}' "$tmp/pi.s")
  nc=$(printf '%s\n' "$top" | grep -c 'call fn_dist')
  nb=$(printf '%s\n' "$top" | grep -c 'call rt_box_float')
  if [ "$nc" = 0 ] && [ "$nb" = 0 ]; then ok "a one-liner reading each parameter twice is inlined for name arguments"
  else bad "float one-liner inlining" "$nc calls of dist and $nb rt_box_float in the top level (want 0 and 0)"; fi
  r=$("$WORD" run "$p" 2>&1)
  if [ "$r" = "9" ]; then ok "and answers what the call did (9)"; else bad "float one-liner inlining" "answered [$r], want 9"; fi
else bad "float one-liner inlining" "-asm dump failed"; fi

# A float literal is a numerator over a denominator (0.5 is 1/2), and it used to
# be turned back into a double with a DIVSD every time it was evaluated, three
# per iteration in a loop like this one, which cost more than the loop's own
# arithmetic. Each distinct literal's double is worked out at compile time now,
# stored in a pool slot at startup and read with a mov, so the number of
# divisions can't depend on how often the literals are used. The runtime has
# divisions of its own, which is why this compares two programs instead of
# counting against a fixed number.
cat > "$tmp/lit_once.w" <<'EOF'
i = 0
a = i * 0.5
b = a + 1.5
if b > 1000000.0
    i = i + 1
out(i)
EOF
cat > "$tmp/lit_many.w" <<'EOF'
n = 50
i = 0
c = 0
loop i < n
    a = i * 0.5
    b = a + 1.5
    if a * a + b * b > 1000000.0
        c = c + 1
    d = b * 0.5 + 1.5
    if d > 1000000.0
        c = c + 1
    i = i + 1
out(c)
EOF
if "$WORD" build -asm "$tmp/lit_once.w" > "$tmp/l1.s" 2>/dev/null && "$WORD" build -asm "$tmp/lit_many.w" > "$tmp/l2.s" 2>/dev/null; then
  d1=$(grep -c 'divsd' "$tmp/l1.s"); d2=$(grep -c 'divsd' "$tmp/l2.s")
  if [ "$d1" = "$d2" ]; then ok "float literals cost one division each, not one per use ($d1)"
  else bad "float literal pool" "using the same three literals more often took $d1 -> $d2 divsd"; fi
else bad "float literal pool" "-asm dump failed"; fi

# cvtsi2sd writes only the low half of its destination and keeps the upper
# half, so it has a false dependency on whatever that register held before. In
# a float loop that's the previous iteration's result, which chains every
# iteration to the one before it: vecmath ran in 32 ms before ten `pxor`
# instructions broke the chain, and 15 ms after. The rule is that every
# cvtsi2sd comes right after a pxor of its own destination, and this checks it
# instruction by instruction, since a missed site only shows as a slower
# benchmark.
cat > "$p" <<'EOF'
n = 20
i = 0
c = 0
loop i < n
    a = i * 0.5
    if a * a > 4.0
        c = c + 1
    i = i + 1
out(c)
EOF
if "$WORD" build -asm "$p" > "$tmp/px.s" 2>/dev/null; then
  bad_px=$(awk '/cvtsi2sd/ { d=$2; sub(",","",d); if (prev != "pxor " d ", " d) print NR": "$0 } { $1=$1; prev=$0 }' "$tmp/px.s" | wc -l)
  nc=$(grep -c 'cvtsi2sd' "$tmp/px.s")
  if [ "$bad_px" = 0 ] && [ "$nc" -gt 0 ]; then ok "every cvtsi2sd ($nc) breaks its destination dependency with pxor first"
  else bad "cvtsi2sd dependency break" "$bad_px of $nc cvtsi2sd are not preceded by a pxor of their destination"; fi
else bad "cvtsi2sd dependency break" "-asm dump failed"; fi

# ...and the value has to survive the pooling: the same literal in two places,
# one of them behind a call, and one only ever used boxed.
cat > "$p" <<'EOF'
half()
    return 0.5
x = 0.5
out(x . " " . half() . " " . 1.5 * 1.5 . " " . 0.5)
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$($TO "$exe" 2>&1)
  if [ "$got" = "0.5 0.5 2.25 0.5" ]; then ok "a pooled literal keeps its value everywhere it appears"
  else bad "pooled literal value" "got [$got] want [0.5 0.5 2.25 0.5]"; fi
else bad "pooled literal value" "build failed"; fi

echo "== an allocation-free float loop stays allocation-free =="
# The regression check for unboxed locals, two ways.
#
# Structurally: a loop over unboxed locals must emit no call to rt_box_float at
# all. That's exact: it fails as soon as a leaf, an operator or a comparison
# falls back to the boxed path, and it only needs the assembly the compiler
# already dumps.
cat > "$p" <<'EOF'
i = 0
x = 0.0
y = 1.0
loop i < 10000000
    a = x * y
    b = y * y
    x = a - b + 0.5
    y = b - a + 0.25
    if x > 100.0
        x = 0.0
    i = i + 1
out(x > y)
EOF
if "$WORD" build -asm "$p" > "$tmp/dump.s" 2>/dev/null; then
  body=$(awk '/^fn__toplevel:/{on=1} on{print} on && /^    ret$/{exit}' "$tmp/dump.s")
  nb=$(printf '%s\n' "$body" | grep -c 'call rt_box_float' || true)
  na=$(printf '%s\n' "$body" | grep -c 'call rt_f' || true)
  if [ "$nb" = 0 ] && [ "$na" = 0 ]; then ok "the loop body allocates no boxes and calls no float helper"
  else bad "float loop is allocation-free" "$nb rt_box_float and $na float-helper calls in fn__toplevel"; fi
else bad "float loop is allocation-free" "-asm dump failed"; fi

# Behaviourally: the same loop, ten million times, under a 256 MB address-space
# cap. The arena's first chunk is 128 MiB, and a box for every operation comes
# to hundreds of megabytes at this count, so a loop that fell back to boxing
# runs out of memory. (At a million passes a boxing loop still fits.) The
# structural check above is the exact one.
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$( (ulimit -v 262144; $TO "$exe") 2>&1 ); rc=$?
  if [ "$rc" = 0 ] && [ -n "$got" ]; then ok "ten million passes of float arithmetic fit in a 256 MB address space"
  else bad "float loop under a cap" "rc=$rc out=[$got]"; fi
else bad "float loop under a cap" "build failed"; fi

echo
echo "test_float: $pass passed, $fail failed"
[ "$fail" = 0 ]
