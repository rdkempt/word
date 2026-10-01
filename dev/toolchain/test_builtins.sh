#!/bin/sh
# test_builtins.sh: known answers for every builtin and operator, on ordinary
# input and at the boundaries where the basics break. test_kinds.sh checks what
# a builtin does with the wrong kind (a fault, never a crash), and this checks
# what it does with the right one (the exact answer). Where a behaviour is a
# documented edge (SPEC 9), the case cites the rule it guards.
#
# No `set -e`, since the fault cases exit nonzero.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; cd "$root"
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 10"
p="$tmp/p.w"; exe="$tmp/p"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "  FAIL $1 -- $2"; }

# crun NAME WANT [STDIN] : build, run, expect exit 0 and stdout exactly WANT.
crun() { cat > "$p"; nm=$1; want=$2
  if ! "$WORD" build "$p" -o "$exe" >"$tmp/e" 2>&1; then bad "$nm" "build failed: $(head -1 "$tmp/e")"; return; fi
  got=$(printf '%s' "$3" | $TO "$exe" 2>&1); rc=$?
  if [ "$got" = "$want" ] && [ "$rc" = 0 ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc, want [$want] rc=0"; fi; }

# cdie NAME SUBSTR : build ok, then a located run-time fault, exit 70.
cdie() { cat > "$p"; nm=$1; sub=$2
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then bad "$nm" "build failed (wanted a run-time fault)"; return; fi
  got=$($TO "$exe" 2>&1); rc=$?
  case "$got" in *"$sub"*) m=1;; *) m=0;; esac
  case "$got" in *p.w:*) loc=1;; *) loc=0;; esac
  if [ "$m" = 1 ] && [ "$rc" = 70 ] && [ "$loc" = 1 ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc, want located [$sub] rc=70"; fi; }

echo "== len (SPEC 9: counts elements; a code point in text, a byte in a byte region) =="
crun "len of text"            "5"      <<'EOF'
out(len("hello"))
EOF
crun "len empty"              "0"      <<'EOF'
out(len(""))
EOF
crun "len counts code points" "1"      <<'EOF'
out(len("é"))
EOF
crun "len of bytes counts bytes" "2"   <<'EOF'
out(len(bytes("6869")))
EOF
crun "len of a fresh array"   "3"      <<'EOF'
out(len(array(3)))
EOF

echo "== copy (whole, half-open range, empty, subkind carries) =="
crun "copy whole"             "abc"    <<'EOF'
out(copy("abc"))
EOF
crun "copy range half-open"   "bc"     <<'EOF'
out(copy("abcd", 1, 3))
EOF
crun "copy empty range"       "0"      <<'EOF'
out(len(copy("abc", 1, 1)))
EOF
crun "copy of bytes stays bytes" "bytes" <<'EOF'
out(kind(copy(bytes("4142"), 0, 1)))
EOF
cdie "copy past the end faults" "out of bounds" <<'EOF'
out(copy("abc", 0, 9))
EOF

echo "== sort (orders a COPY; text is lexicographic; input intact) =="
crun "sort numbers ascending" "1 2 3 4" <<'EOF'
a = array(4)
a[0] = 3
a[1] = 1
a[2] = 4
a[3] = 2
s = sort(a)
out(s[0] . " " . s[1] . " " . s[2] . " " . s[3])
EOF
crun "sort text lexicographic" "abcd"  <<'EOF'
out(sort("dbca"))
EOF
crun "sort leaves input alone" "dbca"  <<'EOF'
s = "dbca"
x = sort(s)
out(s)
EOF
crun "sort empty"             "0"      <<'EOF'
out(len(sort("")))
EOF
# sort orders by the comparison SPEC 3.3 describes, all the way down: rows of
# text sort by their text. It used to compare the element words, which for a
# nested region is its address, so these came back in the order they were
# allocated in.
crun "sort rows of text"      '[["apple"],["date"],["fig"],["pear"]]' <<'EOF'
one(v)
    r = array(1)
    r[0] = v
    return r
rows = array(4)
rows[0] = one("pear")
rows[1] = one("apple")
rows[2] = one("fig")
rows[3] = one("date")
out(sort(rows))
EOF
crun "sort rows by a nested number" '[[4],[30],[200]]' <<'EOF'
one(v)
    r = array(1)
    r[0] = v
    return r
rows = array(3)
rows[0] = one(30)
rows[1] = one(4)
rows[2] = one(200)
out(sort(rows))
EOF
crun "sort rows by a nested float" '[[0.5],[1.5],[2.5]]' <<'EOF'
one(v)
    r = array(1)
    r[0] = v
    return r
rows = array(3)
rows[0] = one(2.5)
rows[1] = one(0.5)
rows[2] = one(1.5)
out(sort(rows))
EOF
crun "sort rows of two fields"  '[["a",1],["a",2],["b",0]]' <<'EOF'
pair(k, v)
    r = array(2)
    r[0] = k
    r[1] = v
    return r
rows = array(3)
rows[0] = pair("b", 0)
rows[1] = pair("a", 2)
rows[2] = pair("a", 1)
out(sort(rows))
EOF
cdie "sort rows with no order between them" "cannot order-compare" <<'EOF'
one(v)
    r = array(1)
    r[0] = v
    return r
rows = array(2)
rows[0] = one("a")
rows[1] = one(1)
out(len(sort(rows)))
EOF

echo "== find (first run; none on miss; empty needle is 0) =="
crun "find a run"             "2"      <<'EOF'
out(find("hello", "ll"))
EOF
crun "find at start"          "0"      <<'EOF'
out(find("hello", "he"))
EOF
crun "find miss is none"      "true"   <<'EOF'
out(find("hello", "z") == none)
EOF
crun "find empty needle is 0" "0"      <<'EOF'
out(find("hello", ""))
EOF

echo "== keys / has (insertion order; membership) =="
crun "keys in insertion order" "3"     <<'EOF'
m = {c: 1, a: 1, b: 1}
out(len(keys(m)))
EOF
crun "keys render as an array" '["c","a","b"]' <<'EOF'
out(keys({c: 1, a: 1, b: 1}))
EOF
crun "has present / absent"   "true false" <<'EOF'
m = {a: 1}
out(has(m, "a") . " " . has(m, "b"))
EOF

echo "== round (ties away from zero; an integer is unchanged; inf/nan/range fault) =="
crun "round half up"          "3"      <<'EOF'
out(round(2.5))
EOF
crun "round negative half"    "-3"     <<'EOF'
out(round(0.0 - 2.5))
EOF
crun "round down"             "2"      <<'EOF'
out(round(2.4))
EOF
crun "round integer is itself" "5"     <<'EOF'
out(round(5))
EOF
# The nearest whole number, even where adding 0.5 rounds the sum. x86-64 used
# to add 0.5 and truncate, so the largest double below one half came back as 1,
# and 2^52 + 1, already whole, as 2^52 + 2. arm64's frinta always got these
# right.
crun "round just below a half is 0" "0 0" <<'EOF'
out(round(0.49999999999999994) . " " . round(0.0 - 0.49999999999999994))
EOF
crun "round of a whole float past 2^52 is itself" "4503599627370497 -4503599627370497" <<'EOF'
out(round(4503599627370497.0) . " " . round(0.0 - 4503599627370497.0))
EOF
# The answer is an integer, so it has the integer range, -2^62 .. 2^62 - 1. The
# check used to be against the 64-bit word, and 2^62 .. 2^63 wrapped to the
# other sign: round(6e18) answered -3223372036854775808.
crun "round at both ends of the range" "4611686018427387392 -4611686018427387904" <<'EOF'
out(round(4611686018427387392.0) . " " . round(0.0 - 4611686018427387904.0))
EOF
cdie "round(2^62) faults" "round() has no whole number" <<'EOF'
out(round(4611686018427387904.0))
EOF
cdie "round(6e18) faults" "round() has no whole number" <<'EOF'
out(round(6000000000000000000.0))
EOF
cdie "round(-6e18) faults" "round() has no whole number" <<'EOF'
out(round(0.0 - 6000000000000000000.0))
EOF
cdie "round(-2^62 - 1024) faults" "round() has no whole number" <<'EOF'
out(round(0.0 - 4611686018427388928.0))
EOF

echo "== number (parse; none on failure; SPEC 9 rejects whitespace/+/trailing-dot) =="
crun "number integer"         "42"     <<'EOF'
out(number("42"))
EOF
crun "number negative"        "-5"     <<'EOF'
out(number("-5"))
EOF
crun "number float"           "3.14"   <<'EOF'
out(number("3.14"))
EOF
crun "number exponent -> float" "1000.0" <<'EOF'
out(number("1e3"))
EOF
crun "number of a number is itself" "7" <<'EOF'
out(number(7))
EOF
crun "number rejects: ws, +, 1., 1e, empty, word" "true true true true true true" <<'EOF'
out((number(" 1") == none) . " " . (number("+1") == none) . " " . (number("1.") == none) . " " . (number("1e") == none) . " " . (number("") == none) . " " . (number("wat") == none))
EOF
crun "number 0 is not a failure" "false" <<'EOF'
out(number("0") == none)
EOF
# Both ends of the integer range are integers (SPEC 2.6), and the bottom end is
# -2^62, one further from zero than the top. It used to come back as a float.
crun "number at both ends of the range is an integer" "4611686018427387903 -4611686018427387904 -1" <<'EOF'
out(number("4611686018427387903") . " " . number("-4611686018427387904") . " " . (number("-4611686018427387904") % 3))
EOF
crun "number one past either end is a float" "4611686018427387904.0 -4611686018427387904.0" <<'EOF'
out(number("4611686018427387904") . " " . number("-4611686018427387905"))
EOF

echo "== in (SPEC 9: an integer line is a number when it fits the range) =="
# in() reads an integer line as a number right up to the ends of the range, the
# way number() does, on both targets. It used to give up past 18 digits, so
# 10^18 .. 2^62 - 1 came back as text.
cat > "$p" <<'EOF'
loop !ended()
    v = in()
    out(kind(v) . " " . v)
EOF
printf '%s\n' 999999999999999999 1000000000000000000 4611686018427387903 \
  4611686018427387904 -4611686018427387904 -4611686018427387905 \
  9999999999999999999 18446744073709551617 000000000000000000000042 -0 12a > "$tmp/in.txt"
want="number 999999999999999999
number 1000000000000000000
number 4611686018427387903
text 4611686018427387904
number -4611686018427387904
text -4611686018427387905
text 9999999999999999999
text 18446744073709551617
number 42
number 0
text 12a"
QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$($TO "$exe" < "$tmp/in.txt" 2>&1)
  [ "$got" = "$want" ] && ok "in() reads every integer in the range" \
                       || bad "in() reads every integer in the range" "got [$(echo "$got" | tr '\n' '|')]"
else bad "in() integer lines builds" "build failed"; fi
if [ -n "$QEMU" ]; then
  if "$WORD" build -arm64 "$p" -o "$exe.a64" >/dev/null 2>&1; then
    got=$($TO $QEMU "$exe.a64" < "$tmp/in.txt" 2>&1)
    [ "$got" = "$want" ] && ok "in() reads every integer in the range (arm64)" \
                         || bad "in() reads every integer in the range (arm64)" "got [$(echo "$got" | tr '\n' '|')]"
  else bad "in() integer lines builds for arm64" "build failed"; fi
fi

echo "== bytes / array / text constructors =="
crun "bytes zero-filled"      "3 0 0 0" <<'EOF'
b = bytes(3)
out(len(b) . " " . b[0] . " " . b[1] . " " . b[2])
EOF
crun "bytes store truncates to low byte" "1" <<'EOF'
b = bytes(1)
b[0] = 257
out(b[0])
EOF
crun "bytes hex literal"      "2 65 66" <<'EOF'
b = bytes("4142")
out(len(b) . " " . b[0] . " " . b[1])
EOF
crun "array renders as JSON (zero-filled)"  "[0,0]"  <<'EOF'
out(array(2))
EOF
crun "bytes(0)/text(0)/array(0) empty" "0 0 0" <<'EOF'
out(len(bytes(0)) . " " . len(text(0)) . " " . len(array(0)))
EOF

echo "== kind (all eight answers) =="
crun "kind names each kind"   "number number text bytes array map boolean boolean null none" <<'EOF'
out(kind(1) . " " . kind(1.5) . " " . kind("a") . " " . kind(bytes(1)) . " " . kind(array(1)) . " " . kind({a: 1}) . " " . kind(true) . " " . kind(false) . " " . kind(null) . " " . kind(none))
EOF

echo "== txt: char / encode / decode (import txt) =="
crun "char builds one code point" "A" <<'EOF'
import txt
out(char(65))
EOF
crun "char of a 4-byte code point is one element" "1" <<'EOF'
import txt
out(len(char(128512)))
EOF
# char() builds the region for any whole number. A code point out of range is
# caught when the region is encoded, and out() prints it as a list of numbers,
# like any region of integers that aren't characters (out(text(3)) prints
# [0, 0, 0]).
crun "char builds a one-element region for any whole number" "1" <<'EOF'
import txt
out(len(char(1114112)))
EOF
cdie "encode rejects an out-of-range code point" "not a code point" <<'EOF'
import txt
out(len(encode(char(1114112))))
EOF
crun "encode counts UTF-8 bytes"  "1 2 3" <<'EOF'
import txt
out(len(encode("A")) . " " . len(encode("é")) . " " . len(encode("€")))
EOF
crun "decode(encode(s)) round-trips" "true" <<'EOF'
import txt
s = "héllo €"
out(decode(encode(s)) == s)
EOF

echo "== txt: split / pad =="
crun "split on a separator"   "3 a b c" <<'EOF'
import txt
xs = split("a,b,c", ",")
out(len(xs) . " " . xs[0] . " " . xs[1] . " " . xs[2])
EOF
crun "split keeps empty pieces" '["a","","b"]' <<'EOF'
import txt
out(split("a,,b", ","))
EOF
crun "split with no separator present" '["abc"]' <<'EOF'
import txt
out(split("abc", ","))
EOF
crun "pad right-aligns (positive width)" "00x" <<'EOF'
import txt
out(pad("x", 3, 48))
EOF
crun "pad left-aligns (negative width)" "x00" <<'EOF'
import txt
out(pad("x", 0 - 3, 48))
EOF
crun "pad never truncates"    "xyz"    <<'EOF'
import txt
out(pad("xyz", 2, 48))
EOF

echo "== env (reads the process environment) =="
crun "env of an unset variable is none" "true" <<'EOF'
out(env("WORD_TEST_DEFINITELY_UNSET_XYZ") == none)
EOF
# A byte-backed name holds bytes, not 8-byte words. env() used to read it as
# words, so the same name looked up that way was never found.
export WORD_TEST_ENV_BYTES=hello
cat > "$p" <<'EOF'
a = env(copy("WORD_TEST_ENV_BYTES"))
b = env(copy(bytes("574f52445f544553545f454e565f4259544553")))
out(a . " " . b)
EOF
for tgt in x86 arm64; do
  [ "$tgt" = arm64 ] && [ -z "$QEMU" ] && continue
  fl=""; run=""; [ "$tgt" = arm64 ] && { fl=-arm64; run=$QEMU; }
  if "$WORD" build $fl "$p" -o "$exe.env" >/dev/null 2>&1; then
    got=$($TO $run "$exe.env" 2>&1)
    [ "$got" = "hello hello" ] && ok "env finds a variable by a word-backed or a byte-backed name ($tgt)" \
      || bad "env finds a variable by a byte-backed name ($tgt)" "got [$got]"
  else bad "env by a byte-backed name builds ($tgt)" "build failed"; fi
done

echo "== now / random / args =="
crun "now() is a number"      "number" <<'EOF'
out(kind(now()))
EOF
crun "now() does not go backwards" "true" <<'EOF'
a = now()
b = now()
out(b >= a)
EOF
crun "random() is a number"   "number" <<'EOF'
out(kind(random()))
EOF
crun "args() is an array"     "array" <<'EOF'
out(kind(args()))
EOF
# args() reflects the command line: args()[0] is the program, then each argument.
cat > "$p" <<'EOF'
out(len(args()))
out(args()[1])
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$($TO "$exe" alpha beta 2>&1)
  want="3
alpha"
  [ "$got" = "$want" ] && ok "args() reflects the command line" || bad "args() reflects the command line" "got [$(echo "$got" | tr '\n' '|')]"
else bad "args() reflects the command line" "build failed"; fi

echo "== operators (known answers + the faults SPEC 10.2 promises) =="
crun "arithmetic"             "4 2 3.5 1"  <<'EOF'
out((2 + 2) . " " . (6 / 3) . " " . (7 / 2) . " " . (7 % 2))
EOF
crun "modulo carries sign of the dividend" "-1 1" <<'EOF'
out((0 - 7 % 3) . " " . (7 % (0 - 3)))
EOF
crun "bitwise"                "12 14 2 -6" <<'EOF'
out((12 & 14) . " " . (12 | 2) . " " . (6 ^ 4) . " " . (~5))
EOF
crun "comparison across kinds is false, never a match" "false true" <<'EOF'
out((5 == "5") . " " . (5 != "5"))
EOF
crun "text compares lexicographically" "true" <<'EOF'
out("abc" < "abd")
EOF
crun "boolean logic"          "true false true" <<'EOF'
out((true && true) . " " . (true && false) . " " . (false || true))
EOF
cdie "divide by zero faults"  "zero"   <<'EOF'
out(1 / 0)
EOF
cdie "modulo by zero faults"  "zero"   <<'EOF'
out(1 % 0)
EOF

# ---------------------------------------------------------------------------
# Shifts and the bitwise operators, end to end (SPEC 3.1, 3.3).
#
# A shift is where the 63-bit signed value model shows through. The value range
# is -2^62 .. 2^62-1 and the largest literal you can write is 2^61-1, so most
# operands here have to be computed. The count is the one operand the hardware
# would mask without telling you.
#
# MAXI and MINI below are the ends of the value range, built by computation:
#   MAXI = 2^62 - 1  =  4611686018427387903
#   MINI = -2^62     = -4611686018427387904
# ---------------------------------------------------------------------------
echo "== shifts: every count that is a boundary (SPEC 3.1) =="
crun "<< by 0, 1, 61, 62, 63" "1|2|2305843009213693952|-4611686018427387904|0" <<'EOF'
out((1 << 0) . "|" . (1 << 1) . "|" . (1 << 61) . "|" . (1 << 62) . "|" . (1 << 63))
EOF
# 1 << 62 is the sign bit of a 63-bit value, so it's the minimum. The operator
# works on the bits, and the answer can't leave the range (SPEC 3.1). 1 << 63
# shifts the whole value out.
crun "<< 62 is the sign bit, << 63 is zero" "true|true" <<'EOF'
LIT = 2305843009213693951
MINI = 0 - LIT - LIT - 2
out(((1 << 62) == MINI) . "|" . ((1 << 63) == 0))
EOF
crun ">> by 0, 1, 62, 63" "7|3|0|0" <<'EOF'
out((7 >> 0) . "|" . (7 >> 1) . "|" . (7 >> 62) . "|" . (7 >> 63))
EOF
crun "zero shifts to zero, every count" "0|0|0|0" <<'EOF'
out((0 << 0) . "|" . (0 << 63) . "|" . (0 >> 0) . "|" . (0 >> 63))
EOF
crun "-1 << 1, 62, 63" "-2|-4611686018427387904|0" <<'EOF'
out(((0 - 1) << 1) . "|" . ((0 - 1) << 62) . "|" . ((0 - 1) << 63))
EOF
# >> is arithmetic: it copies the sign bit, because the one integer type is
# signed (SPEC 3.1). So -1 stays -1 however far it's shifted.
crun "-1 >> anything is still -1 (the sign is copied)" "-1|-1|-1|-1" <<'EOF'
out(((0 - 1) >> 0) . "|" . ((0 - 1) >> 1) . "|" . ((0 - 1) >> 62) . "|" . ((0 - 1) >> 63))
EOF
crun "the ends of the value range, shifted" "-2|0|0|-1|-1" <<'EOF'
LIT = 2305843009213693951
MAXI = LIT + LIT + 1
MINI = 0 - MAXI - 1
out((MAXI << 1) . "|" . (MINI << 1) . "|" . (MAXI >> 62) . "|" . (MINI >> 62) . "|" . (MINI >> 63))
EOF
crun "a count of 0 is the identity, at both ends" "true|true|true|true" <<'EOF'
LIT = 2305843009213693951
MAXI = LIT + LIT + 1
MINI = 0 - MAXI - 1
out(((MAXI << 0) == MAXI) . "|" . ((MINI << 0) == MINI) . "|" . ((MAXI >> 0) == MAXI) . "|" . ((MINI >> 0) == MINI))
EOF
# SPEC 3.3 offers `a >> 3` as a division by eight that keeps the whole part.
# >> rounds toward minus infinity and `/` is exact, so the two differ on
# negatives.
crun ">> floors where / stays exact" "-4|-3.5|-4|-4" <<'EOF'
out(((0 - 7) >> 1) . "|" . ((0 - 7) / 2) . "|" . ((0 - 8) >> 1) . "|" . ((0 - 7) >> 1))
EOF

echo "== shifts: the count is checked, never masked =="
# The hardware masks a shift count to six bits. The language checks it instead
# (SPEC 3.1). Both spellings of the count are tested: a literal the compiler
# can see, and a value it can't.
cdie "<< 64 (literal count)"  "shift out of range" <<'EOF'
out(1 << 64)
EOF
cdie ">> 64 (literal count)"  "shift out of range" <<'EOF'
out(1 >> 64)
EOF
cdie "<< -1 (literal count)"  "shift out of range" <<'EOF'
out(1 << (0 - 1))
EOF
cdie ">> -1 (literal count)"  "shift out of range" <<'EOF'
out(1 >> (0 - 1))
EOF
cdie ">> 64 (count out of a region)" "shift out of range" <<'EOF'
a = array(1)
a[0] = 64
out(1 >> a[0])
EOF
cdie ">> -1 (count out of a region)" "shift out of range" <<'EOF'
a = array(1)
a[0] = 0 - 1
out(1 >> a[0])
EOF
cdie "a count far past 64 is out of range, not masked" "shift out of range" <<'EOF'
a = array(1)
a[0] = 1000000000000
out(1 << a[0])
EOF
crun "63 is in range, 64 is not: the boundary is exact" "0|-1" <<'EOF'
a = array(1)
a[0] = 63
out((1 << a[0]) . "|" . ((0 - 1) >> a[0]))
EOF
# Every count from 0 to 63 runs, with the count hidden from the analyzer. The
# answers are checked against `(1 << n) >> n == 1` for the counts where that
# holds (n < 62; at 62 the bit is the sign, and at 63 it's gone).
crun "all 64 counts, through a region" "62|true" <<'EOF'
a = array(1)
n = 0
good = 0
loop n < 62
    a[0] = n
    if ((1 << a[0]) >> a[0]) == 1
        good = good + 1
    n = n + 1
a[0] = 62
hi = (1 << a[0]) >> a[0]
a[0] = 63
out(good . "|" . ((hi == (0 - 1)) && ((1 << a[0]) == 0)))
EOF

echo "== shifts and bitwise operators are integer-only (SPEC 3.3) =="
cdie "a float count"          "operator needs whole numbers" <<'EOF'
out(1 << 2.0)
EOF
cdie "a float subject"        "operator needs whole numbers" <<'EOF'
out(2.0 << 1)
EOF
cdie "a float count behind a region" "operator needs whole numbers" <<'EOF'
a = array(1)
a[0] = 2.0
out(1 << a[0])
EOF
cdie "a float through &"      "operator needs whole numbers" <<'EOF'
out(2.0 & 1)
EOF
cdie "a float through ~"      "operator needs whole numbers" <<'EOF'
out(~2.0)
EOF

echo "== bitwise: the ends of the range, and the identities that pin them =="
crun "& | ^ across the whole range" "0|-1|-1|0|-1" <<'EOF'
LIT = 2305843009213693951
MAXI = LIT + LIT + 1
MINI = 0 - MAXI - 1
out((MAXI & MINI) . "|" . (MAXI | MINI) . "|" . (MAXI ^ MINI) . "|" . (MAXI ^ MAXI) . "|" . ((0 - 1) & (0 - 1)))
EOF
crun "~ maps each end onto the other" "true|true|true|true" <<'EOF'
LIT = 2305843009213693951
MAXI = LIT + LIT + 1
MINI = 0 - MAXI - 1
out(((~MAXI) == MINI) . "|" . ((~MINI) == MAXI) . "|" . ((~0) == (0 - 1)) . "|" . ((~(0 - 1)) == 0))
EOF
# Not at the bottom end: -MINI isn't representable, so `0 - MINI` is an
# integer overflow (SPEC 3.1).
crun "~x is -x - 1 wherever -x exists" "true|true|true" <<'EOF'
LIT = 2305843009213693951
MAXI = LIT + LIT + 1
MINI = 0 - MAXI - 1
out(((~MAXI) == (0 - MAXI - 1)) . "|" . ((~5) == (0 - 6)) . "|" . ((~(MINI + 1)) == (0 - (MINI + 1) - 1)))
EOF
crun "de Morgan, on values the range cannot widen" "true|true" <<'EOF'
a = 3735928559
b = 0 - 3405691582
out((((~a) & (~b)) == (~(a | b))) . "|" . (((~a) | (~b)) == (~(a & b))))
EOF
crun "the bitwise operators never trap, at the ends" "true" <<'EOF'
LIT = 2305843009213693951
MAXI = LIT + LIT + 1
MINI = 0 - MAXI - 1
n = (MINI & MAXI) | (MINI ^ MAXI) | (~MINI) | (~MAXI)
out(n == (0 - 1))
EOF

echo "== the precedence these operators actually have (SPEC 4.1) =="
# Loosest to tightest: `||`, `&&`, comparisons, `.`, then `+ - | ^`, then
# `* / % << >> &`. So a shift binds tighter than `+` (in C it's looser), `&`
# binds tighter than `|` and `^`, and `<<` is left-associative at the same
# level as `*`, so `1 << 2 * 3` is 12 (in C it's 64).
crun "a shift binds tighter than + and -" "17|10|0" <<'EOF'
out((1 + 2 << 3) . "|" . (1 << 3 + 2) . "|" . (0 - 1 >> 1))
EOF
crun "<< is level with *, and left-associative" "12|12" <<'EOF'
out((1 << 2 * 3) . "|" . (2 * 3 << 1))
EOF
crun "& binds tighter than | and ^" "3|3|4" <<'EOF'
out((1 | 2 & 3) . "|" . (1 ^ 2 & 3) . "|" . (4 + 1 & 6))
EOF
crun "| and ^ are level, and left-associative" "0" <<'EOF'
out(1 | 2 ^ 3)
EOF
crun "~ binds tighter than +" "-1|-3" <<'EOF'
out((~1 + 1) . "|" . (~(1 + 1)))
EOF

echo "test_builtins: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
