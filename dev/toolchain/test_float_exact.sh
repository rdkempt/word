#!/bin/sh
# test_float_exact.sh: a float literal is the nearest double, bit for bit.
#
# This is easy to get slightly wrong, so it's checked against an independent
# implementation instead of expected strings: the compiler is asked for the
# assembly it would emit, the 64-bit constant is read out of it, and Python's
# own strtod gives the same value's bits. None of it goes through word's float
# printing, which is separate code with its own rounding.
#
# The values sit on the parts of the format that break: both ends of the
# exponent range, the largest and smallest normals, subnormals down to the last
# one, the exact powers of ten either side of where a 63-bit integer stops
# holding them, and decimals that famously aren't representable.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/vals.txt" <<'VALS'
0.0
1.0
2.0
0.5
0.1
0.3
3.14
7.0
123.456
0.000001
3.141592653589793
2.718281828459045
1e6
1e17
1e-17
1e22
1e23
1e-22
1e-23
1e25
1.2e-9
1e100
1e-100
1e300
1e-300
5e-324
1e-310
2.2250738585072014e-308
1.7976931348623157e308
900000000000000000.0
1234567890123456789.0
9007199254740993.0
0.30000000000000004
1.0000000000000002
VALS

python3 - "$tmp" <<'PY'
import sys
tmp = sys.argv[1]
vals = [l.strip() for l in open(tmp+"/vals.txt") if l.strip()]
# One literal per line, each read once so nothing is elided.
with open(tmp+"/p.w","w") as f:
    for i,v in enumerate(vals):
        f.write("x%d = %s\nout(x%d == x%d)\n" % (i,v,i,i))
PY

"$WORD" build -asm "$tmp/p.w" > "$tmp/p.s" 2>/dev/null

python3 - "$tmp" <<'PY'
import sys, re, struct
tmp = sys.argv[1]
vals = [l.strip() for l in open(tmp+"/vals.txt") if l.strip()]
emitted = set(m.group(1).lower() for m in
              re.finditer(r'movabs rax, 0x([0-9a-fA-F]{16})', open(tmp+"/p.s").read()))
bad = 0
for v in vals:
    want = "%016x" % struct.unpack("<Q", struct.pack("<d", float(v)))[0]
    if float(v) == 0.0:
        continue                      # zero is emitted as the integer path
    if want in emitted:
        print("  ok   %-30s %s" % (v, want))
    else:
        bad += 1
        print("  FAIL %-30s want %s, not emitted" % (v, want))
print()
if bad:
    print("float literals: %d of %d are NOT the nearest double" % (bad, len(vals)))
    sys.exit(1)
print("float literals: all %d are the nearest double, bit for bit" % len(vals))
PY

# A literal longer than the mantissa. The digits that don't fit a 63-bit
# integer still count: a literal just above a halfway point between two doubles
# has to round up even when everything that puts it above is past the 19th
# digit, and one just below has to round down. These used to be dropped, so
# 9007199254740993.0000000000001 read as 2^53 instead of 2^53 + 2.
#
# Each case is the exact halfway point above a double, and that point nudged up
# or down far below its last digit. Python's float() (correctly rounded for any
# length) says which double it has to be. The program compares each literal
# with the shortest spelling of that double, through a function so nothing is
# folded, and has to print true for every one. One case has 900 zeros before
# its last digit, so only that trailing 1 decides it.
python3 - "$tmp" <<'PY'
import sys, math, random, struct
from fractions import Fraction
tmp = sys.argv[1]
random.seed(20260922)

def exact(fr):
    # the exact decimal of a dyadic fraction, as "d.ddd...e<exp>"
    n, d = fr.numerator, fr.denominator
    k = d.bit_length() - 1              # d is a power of two
    digits = str(n * 5**k)              # value = digits * 10^-k
    exp = len(digits) - 1 - k
    return digits[0] + "." + (digits[1:] or "0") + "e" + str(exp)

ds = [0.1, 0.3, 1.0, 2.0**53, 1e23, 5e-324, 2.2250738585072014e-308,
      1.7976931348623157e308 / 2, 123456789012345683968.0, 3.141592653589793]
while len(ds) < 60:
    b = random.getrandbits(63)
    x = struct.unpack("<d", struct.pack("<Q", b))[0]
    if math.isfinite(x) and x > 0 and math.nextafter(x, math.inf) != math.inf:
        ds.append(x)
cases = []
for x in ds:
    h = (Fraction(x) + Fraction(math.nextafter(x, math.inf))) / 2
    m, e = exact(h).split("e")
    cases.append(m + "e" + e)                     # exactly half way
    cases.append(m + "0000001e" + e)              # just above
    dg = m.replace(".", "")
    lo = str(int(dg) - 1).zfill(len(dg))
    cases.append(lo[0] + "." + lo[1:] + "99999e" + e)   # just below
cases.append("9007199254740993.0000000000001")
cases.append("1.00000000000000011102230246251565404236316680908203125000001")
cases.append("123456789012345692161.0")
cases.append("123456789012345692159.0")
cases.append("0.230584300921369395910000000000000000001")
m, e = exact((Fraction(0.1) + Fraction(math.nextafter(0.1, 1))) / 2).split("e")
cases.append(m + "0" * 900 + "1e" + e)
with open(tmp + "/long.w", "w") as f:
    f.write("same(x)\n    return x\n")
    for c in cases:
        f.write("out(same(%s) == %r)\n" % (c, float(c)))
with open(tmp + "/long.txt", "w") as f:
    f.write("\n".join(cases) + "\n")
PY
"$WORD" build "$tmp/long.w" -o "$tmp/long"
"$tmp/long" > "$tmp/long.out"
python3 - "$tmp" <<'PY'
import sys
tmp = sys.argv[1]
cases = open(tmp + "/long.txt").read().split()
got = open(tmp + "/long.out").read().split()
bad = 0
for c, g in zip(cases, got + [""] * len(cases)):
    if g != "true":
        bad += 1
        print("  FAIL %s... is not the nearest double" % c[:60])
if len(got) != len(cases):
    bad += 1
    print("  FAIL the program printed %d answers for %d cases" % (len(got), len(cases)))
if bad:
    print("long float literals: %d of %d are NOT the nearest double" % (bad, len(cases)))
    sys.exit(1)
print("long float literals: all %d are the nearest double" % len(cases))
PY

# number() and json.parse read digits at run time, and they have to give the
# double the compiler gives the same digits as a literal: the nearest one.
# They used to keep 19 digits and scale them by ten a step at a time, which
# rounds at every step, so most of the long cases above came out a double off,
# and so did "0.30000000000000004" and "70404.301035722134e2", which have only
# 17 digits. Past the integer range a dropped digit also let a later, smaller
# one in one place too high: "46116860184273879041e22" read as
# 4611686018427387901e23.
#
# Every long case is read both ways here, with the integers either side of 2^62
# and 2^63, the digit-order cases, the ends of the range and random doubles
# written with 17 significant digits, on both targets. The runtime does this in
# its own code (rt_f10exact), so it's tested apart from the compiler's.
python3 - "$tmp" <<'PY'
import sys, math, random, struct
tmp = sys.argv[1]
random.seed(20260924)
cases = open(tmp + "/long.txt").read().split()
cases += ["46116860184273879041e22", "-46116860184273879051e22", "46116860184273879041",
          "4611686018427387903.5", "4611686018427387904", "4611686018427388416",
          "4611686018427388417", "-4611686018427387905", "9223372036854775807",
          "9223372036854775808", "9223372036854776832", "9223372036854776833",
          "-9223372036854777856", "18446744073709551615", "123456789012345678901234567890",
          "70404.301035722134e2", "0.30000000000000004", "0." + "0" * 500 + "1e500",
          "1" + "0" * 400 + "e-400", "2.4703282292062327e-324", "2.4703282292062328e-324",
          "1e-400", "1.7976931348623158e308", "0.000000000000000000000000000000000001"]
while len(cases) < 420:
    x = struct.unpack("<d", struct.pack("<Q", random.getrandbits(63)))[0]
    if math.isfinite(x) and x != 0:
        cases.append(("-" if random.random() < 0.3 else "") + "%.17g" % x)
def lit(v):
    r = repr(v)
    return "(0.0 - %s)" % r[1:] if r.startswith("-") else r
with open(tmp + "/rt.w", "w") as f:
    f.write("import json\n")
    f.write("chk(s, want)\n    a = number(s)\n    b = parse(\"[\" . s . \"]\")\n")
    f.write("    if a != want\n        return \"number\"\n")
    f.write("    if b == none\n        return \"parse-none\"\n")
    f.write("    if b[0] != want\n        return \"parse\"\n    return \"true\"\n")
    for c in cases:
        f.write("out(chk(\"%s\", %s))\n" % (c, lit(float(c))))
with open(tmp + "/rt.txt", "w") as f:
    f.write("\n".join(cases) + "\n")
PY
QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
"$WORD" build "$tmp/rt.w" -o "$tmp/rt"
"$tmp/rt" > "$tmp/rt.x86.out"
if [ -n "$QEMU" ]; then
  "$WORD" build -arm64 "$tmp/rt.w" -o "$tmp/rt.a64"
  $QEMU "$tmp/rt.a64" > "$tmp/rt.arm64.out"
else
  echo "  (no qemu-aarch64: number() and parse checked on x86-64 only)"
fi
python3 - "$tmp" <<'PY'
import sys, os
tmp = sys.argv[1]
cases = open(tmp + "/rt.txt").read().split()
bad = 0
for tgt in ("x86", "arm64"):
    fn = tmp + "/rt.%s.out" % tgt
    if not os.path.exists(fn):
        continue
    got = open(fn).read().split()
    for c, g in zip(cases, got + [""] * len(cases)):
        if g != "true":
            bad += 1
            print("  FAIL (%s) %s... %s is not the nearest double" % (tgt, c[:60], g or "nothing"))
    if len(got) != len(cases):
        bad += 1
        print("  FAIL (%s) the program printed %d answers for %d cases" % (tgt, len(got), len(cases)))
if bad:
    print("number() and parse: %d wrong answers" % bad)
    sys.exit(1)
print("number() and parse: all %d cases are the nearest double" % len(cases))
PY

# A literal's exponent used to stop growing at 100000, so one of a million or
# more lost its last digits. That only shows when the literal is long enough
# to bring such an exponent back into range: a million zeros after the point
# and then e1000001 is 1.0, and it came out 0.0, while a 1 and a million zeros
# then e-1000000 came out inf. It stops at 10^17 now, far past any literal.
python3 - "$tmp" <<'PY'
import sys
tmp = sys.argv[1]
with open(tmp + "/bigexp.w", "w") as f:
    f.write("a = 0." + "0" * 1000000 + "1e1000001\n")
    f.write("b = 1" + "0" * 1000000 + "e-1000000\n")
    f.write("out((a == 1.0) . \" \" . (b == 1.0))\n")
PY
"$WORD" build "$tmp/bigexp.w" -o "$tmp/bigexp"
got=$("$tmp/bigexp")
if [ "$got" != "true true" ]; then
  echo "  FAIL a million-digit literal with an exponent past a million: [$got], want [true true]"
  exit 1
fi
echo "a literal of a million digits and its seven-digit exponent: both read as 1.0"
