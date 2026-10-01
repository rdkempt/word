#!/bin/sh
# test_guarantees.sh: what the language promises, as opposed to what the
# compiler happens to do.
#
# The other suites are strong where the compiler is mechanical: the
# differential encoder tests, the byte-identical self-host, every example built
# and run. This one is organized by promise instead of by feature. Every case
# is phrased as "the language says X" and fails if X stops being true. When a
# promise gains a clause, it gains a case here.
#
# No `set -e`, since most cases are meant to make `word` exit nonzero.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
# On Windows word.exe is a native program: a path written into a program's text
# has to be one Windows can open, and /tmp/x is \tmp\x on the current drive.
# hostpath is the identity everywhere else. win=1 marks the cases that ask
# Linux-only questions (strace, running an ELF), which skip there.
. "$here/hostpath.sh"; win=0
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in msys*|cygwin*|win32|MINGW*|MSYS*|CYGWIN*) win=1;; esac
WORD=${WORD:-"$root/word"}; tmp=$(hostpath "$(mktemp -d)"); trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"
cd "$root"
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 20"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  OK   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1 -- $2"; }
p="$tmp/p.w"; exe="$tmp/p"

# The program must be rejected, with a located diagnostic containing $2.
rej() { cat > "$p"; nm="$1"; sub="$2"
  sout=$("$WORD" build "$p" -o "$exe" 2>"$tmp/diag"); rc=$?
  got=$(cat "$tmp/diag")
  case "$got" in *"$sub"*) m=1;; *) m=0;; esac
  case "$got" in *"p.w:"*) loc=1;; *) loc=0;; esac
  if [ "$m" = 1 ] && [ "$rc" = 1 ] && [ "$loc" = 1 ] && [ -z "$sout" ]; then ok "$nm"
  else bad "$nm" "stderr=[$got] rc=$rc (want located [$sub], rc=1)"; fi; }

# The program must be accepted and print exactly $2.
acc() { cat > "$p"; nm="$1"; want="$2"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
    bad "$nm" "rejected: $("$WORD" build "$p" -o "$exe" 2>&1)"; return; fi
  got=$($TO "$exe" 2>&1); rc=$?
  if [ "$got" = "$want" ] && [ "$rc" = 0 ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc want [$want]"; fi; }

# The program must build and then die at run time, with $2 on stderr.
die() { cat > "$p"; nm="$1"; sub="$2"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then bad "$nm" "did not build"; return; fi
  got=$($TO "$exe" 2>&1); rc=$?
  case "$got" in *"$sub"*) m=1;; *) m=0;; esac
  if [ "$m" = 1 ] && [ "$rc" = 70 ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc (want [$sub], rc=70)"; fi; }

echo "== PROMISE: a local is readable only where every path has assigned it =="
# SPEC 5.1. Before this rule the read took whatever the stack slot held, and
# since static kind (3.6) trusted the assignment it could see, the tag test was
# skipped: a stale region printed as a raw integer and a stale integer was
# dereferenced as a region. Ordinary source must never reach unchecked memory,
# so these are compile errors.

rej "read after a branch that may not have run" "is not assigned on every path" <<'EOF'
if false
    x = 5
out(x)
EOF

rej "a value from a previous frame is not reachable" "is not assigned on every path" <<'EOF'
make()
    x = "SECRET-123"
    return x

bad()
    if false
        x = "other"
    return x

s = make()
out(s)
out(bad())
EOF

rej "a stale integer cannot be read as a region" "is not assigned on every path" <<'EOF'
seed()
    p = 140737488355328
    return p

leak()
    if false
        p = "text"
    return len(p)

s = seed()
out(s)
out(leak())
EOF

rej "an else-if chain with no final else" "is not assigned on every path" <<'EOF'
f(c)
    if c == 1
        v = 1
    else if c == 2
        v = 2
    return v
out(f(1))
EOF

rej "assigned only in a nested branch" "is not assigned on every path" <<'EOF'
f(c, d)
    if c != 0
        if d != 0
            v = 1
    else
        v = 3
    return v
out(f(1, 1))
EOF

rej "assigned only inside a loop body" "is not assigned on every path" <<'EOF'
f(n)
    i = 0
    loop i < n
        v = i
        i = i + 1
    return v
out(f(3))
EOF

rej "assigned only inside a for-each body" "is not assigned on every path" <<'EOF'
f(r)
    loop c in r
        v = c
    return v
out(f("ab"))
EOF

# Read before the name is bound at all: still "undefined variable", the more
# precise of the two messages.
rej "read before the binding that would create it" "undefined variable 'v'" <<'EOF'
f(n)
    loop v < n
        v = 1
    return 0
out(f(3))
EOF

echo "== and the shapes that must keep working =="
# A rule that rejects real programs is worse than the bug it fixes, so every
# ordinary way of assigning on both paths is checked here.

acc "both arms assign" "1" <<'EOF'
f(c)
    if c != 0
        x = 1
    else
        x = 2
    return x
out(f(1))
EOF

acc "one arm returns, so it joins nothing" "7" <<'EOF'
f(c)
    if c != 0
        y = 7
    else
        return 0
    return y
out(f(1))
EOF

acc "the other arm returns" "2" <<'EOF'
f(c)
    if c != 0
        return 0
    else
        y = 2
    return y
out(f(0))
EOF

acc "an arm breaks out of the loop" "3" <<'EOF'
f(n)
    t = 0
    i = 0
    loop i < n
        if i == 3
            break
        else
            t = i
        t = t + 1
        i = i + 1
    return t
out(f(10))
EOF

acc "assigned before the branch" "1" <<'EOF'
f(c)
    z = 0
    if c != 0
        z = 1
    return z
out(f(1))
EOF

acc "assigned after the branch, which is the fix" "9" <<'EOF'
f(c)
    if c != 0
        w = 1
    w = 9
    return w
out(f(0))
EOF

acc "the for-each variable is assigned by the loop" "131" <<'EOF'
f(r)
    total = 0
    loop ch in r
        total = total + ch
    return total
out(f("AB"))
EOF

acc "nested if/else where every leaf assigns" "2" <<'EOF'
f(c, d)
    if c != 0
        if d != 0
            v = 1
        else
            v = 2
    else
        v = 3
    return v
out(f(1, 0))
EOF

acc "a parameter is assigned on entry" "5" <<'EOF'
f(n)
    return n
out(f(5))
EOF

acc "a loop counter assigned before the loop" "10" <<'EOF'
f(n)
    i = 0
    loop i < n
        i = i + 1
    return i
out(f(10))
EOF

echo "== PROMISE: a conversion's failure is distinguishable from its zero =="
# number("0") and number("wat") used to be the same word, and so did
# json.parse of the text "0" and json.parse of a broken document, so no caller
# could tell a parsed zero from a failed parse.

acc "a failed number() is none, a parsed zero is 0" "none 0 true false" <<'EOF'
out(number("wat") . " " . number("0") . " " . (number("wat") == none) . " " . (number("0") == none))
EOF

acc "a failed parse is none, a parsed zero is 0" "none 0 true false" <<'EOF'
import json
out(parse("{oops") . " " . parse("0") . " " . (parse("{oops") == none) . " " . (parse("0") == none))
EOF

# fs and net answer the same word, so a program that can fail three ways spells
# all three failures the same. read() and the net verbs used to answer the
# number 0, so a library wrapping both had to remember which convention each
# one used.
acc "a failed read is none, and so is a failed dir" "none none true true" <<'EOF'
import fs
a = read("/no/such/file/zzz")
b = dir("/no/such/directory/zzz")
out(a . " " . b . " " . (a == none) . " " . (b == none))
EOF

# This is why the sentinel exists: an empty file read successfully and a file
# that couldn't be read are different answers, and `len` can't tell them apart
# (an empty file has length 0, and a failure has no length at all). Windows has
# no /dev/null a program can open by that name, so there the empty file is one
# made in $tmp.
empty=/dev/null; [ "$win" = 1 ] && { : > "$tmp/empty"; empty="$tmp/empty"; }
acc "an empty file is a region, not a failure" "0 bytes true false" <<EOF
import fs
e = read("$empty")
out(len(e) . " " . kind(e) . " " . (e != none) . " " . (e == none))
EOF

# Asking a failure whether it's true is refused, like every other none
# (SPEC 3.8). `if !read(p)` looks like a null check but couldn't tell
# "unreadable" from "empty".
die "a failed read is not a condition" "true or false" <<'EOF'
import fs
if read("/no/such/file/zzz")
    out("unreachable")
EOF

echo "== PROMISE: parse . stringify is an identity =="
# The most common thing anyone does with JSON is fetch it, change one field and
# send it back. That used to rewrite every boolean and null in the document
# without any sign of it.

acc "booleans and null survive the round trip" "{\"a\":true,\"b\":false,\"c\":null,\"d\":0}" <<'EOF'
import json
out(stringify(parse("{\"a\":true,\"b\":false,\"c\":null,\"d\":0}")))
EOF

acc "false is not 0 and null is not false" "false false false" <<'EOF'
import json
o = parse("{\"f\":false,\"n\":null,\"z\":0}")
out((o["f"] == 0) . " " . (o["n"] == o["f"]) . " " . (o["z"] == o["f"]))
EOF

# A bare literal used to be skipped without being read, so every one of these
# parsed as valid JSON. Nobody could see it until failure had its own value.
acc "a truncated or misspelled keyword is not valid JSON" "none none none none" <<'EOF'
import json
out(parse("nul") . " " . parse("tru") . " " . parse("fals") . " " . parse("nulq"))
EOF

echo "== PROMISE: what stringify writes, a parser can read back =="
# `none` isn't a JSON value (it's what a failed parse or number() answers), and
# stringify used to write its name, so a map holding a failed conversion
# produced `{"a":none}`, which no parser will take back. Writing JSON `null`
# would be worse: the language keeps null and none apart, and a document
# mustn't claim a field was present and null when a conversion failed.
die "stringify refuses none rather than writing invalid JSON" "none is not a JSON value" <<'EOF'
out(stringify({a: none}))
EOF
die "and refuses it on its own too" "none is not a JSON value" <<'EOF'
out(stringify(none))
EOF
acc "the three JSON singletons still write as JSON words" '{"a":true,"b":false,"c":null}' <<'EOF'
out(stringify({a: true, b: false, c: null}))
EOF
acc "and a document round-trips through both" "[true,false,null]" <<'EOF'
out(stringify(parse("[true,false,null]")))
EOF
acc "a failed parse is none, and none is the test for it" "caught" <<'EOF'
d = parse("{not json")
if d == none
    out("caught")
else
    out("missed")
EOF
acc "a parsed null is null, which is not a failure" "null null" <<'EOF'
d = parse("null")
out(kind(d) . " " . d)
EOF

# A float that arrives over the wire has to be the same double the compiler
# gives the same digits in source. The runtime used to scale by multiplying or
# dividing by ten in a loop, one rounding per decimal place, so parse("3.14")
# answered a value under 3.14, stringify wrote 3.13999999999999, and rendering
# that gave 3.13999999999998. A JSON fuzz found it.
acc "a parsed float is the same double as the literal" "same same same same" <<'EOF'
c(s, lit)
    v = parse(s)
    if v == lit
        return "same"
    return "DIFFERS"

out(c("3.14", 3.14) . " " . c("123.456", 123.456) . " " . c("1e-9", 1e-9) . " " . c("2.5e3", 2.5e3))
EOF
acc "and it renders back as the digits it came from" "3.14 123.456" <<'EOF'
out(stringify(parse("3.14")) . " " . stringify(parse("123.456")))
EOF
die "an infinity is not a JSON value either" "not JSON values" <<'EOF'
z = 0.0
out(stringify({v: 1.0 / z}))
EOF

# SPEC 10.1: a rejected program gets one located diagnostic, never an internal
# fault. An unterminated string used to walk the lexer off the end of the
# source and fault the compiler against its own line, and `out("` is the most
# ordinary half-typed line there is, so an editor asking for diagnostics hit it
# on every keystroke inside a string.
rej "a raw newline in a string is located, not an internal fault" "newline in string literal" <<'EOF'
out("abc
EOF
# The buffer the same function scanned into was a fixed 65,536 and unchecked,
# so a longer literal overflowed it and faulted the compiler the same way.
# That's a realistic size for a bytes("...") table: 32 KB of data is 65,536 hex
# digits. The literal is written out instead of built with `.` at run time,
# because it's the lexer being tested.
{ printf 'out(len("'; i=0; while [ $i -lt 7000 ]; do printf 'abcdefghij'; i=$((i+1)); done; printf '"))\n'; } > "$p"
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1 && [ "$($TO "$exe" 2>&1)" = "70000" ]; then
  ok "a 70,000-character string literal compiles"
else
  bad "a 70,000-character string literal compiles" "$("$WORD" build "$p" -o "$exe" 2>&1 | head -1)"
fi

echo "== PROMISE: a value of one kind is never observed as another =="

acc "kind() names each singleton" "boolean boolean null none" <<'EOF'
out(kind(true) . " " . kind(false) . " " . kind(null) . " " . kind(none))
EOF

acc "a singleton renders as itself, not as its bits" "true false null none" <<'EOF'
out(true . " " . false . " " . null . " " . none)
EOF

acc "equality is identity, and crosses no kind" "true true false false false" <<'EOF'
out((true == true) . " " . (null == null) . " " . (true == 1) . " " . (false == 0) . " " . (null == none))
EOF

# A float on the other side doesn't make a singleton a number either. null,
# false, true and none are the words 6, 14, 22 and 30, which the float
# comparison used to read as the integers 3, 7, 11 and 15, so every one of
# these was true.
acc "equality with a float crosses no kind either" "false false false false" <<'EOF'
out((null == 3.0) . " " . (false == 7.0) . " " . (true == 11.0) . " " . (none == 15.0))
EOF

# One number is one number however it's spelled, at every depth. `1 == 1.0` is
# true, and a map's values have always compared that way (rt_map_eq hands them
# to the same `==`), but an array element used to ask whether either side was
# an integer and answer false, so `[1] == [1.0]` disagreed with
# `{k: 1} == {k: 1.0}`. `find` answers where `==` would, so it matches by the
# same rule.
acc "a number is one number at every depth" "true true true true 0" <<'EOF'
one(v)
    r = array(1)
    r[0] = v
    return r
out((1 == 1.0) . " " . ({k: 1} == {k: 1.0}) . " " . (one(1) == one(1.0)) . " " . (bytes("01") == one(1.0)) . " " . find(one(1), one(1.0)))
EOF

# That mustn't make two different numbers equal at any depth, or cross a kind:
# a float element against text, a map or a singleton is still unequal.
acc "different numbers stay different, and kinds still do not cross" "false false false false false" <<'EOF'
one(v)
    r = array(1)
    r[0] = v
    return r
out((one(1) == one(2.0)) . " " . (one(2) == one(1.5)) . " " . (one(1.0) == one("1")) . " " . (one(1.0) == one({a: 1})) . " " . (one(1.0) == one(none)))
EOF

rej "a singleton is not a number" "must be a number" <<'EOF'
out(true + 1)
EOF

rej "a singleton has no order" "no meaning for true, false, null or none" <<'EOF'
out(true < 5)
EOF

# A comparison's answer is a singleton, so the same two rejections apply to it
# as to the literal. `1 + true` used to be a located compile error while
# `1 + (a == b)` compiled and faulted at run time, because the analyzer called
# a comparison a number.
rej "arithmetic on a comparison's answer" "must be a number" <<'EOF'
a = 1
b = 2
out((a == b) + 1)
EOF

rej "arithmetic on a negation's answer" "must be a number" <<'EOF'
a = true
out(!a + 1)
EOF

rej "arithmetic on a logical's answer" "must be a number" <<'EOF'
a = true
b = false
out((a && b) * 2)
EOF

# `a < b < c` reads as `(a < b) < c` and asks for an order among booleans, and
# there isn't one. It's the one mistake here that looks like ordinary math.
rej "a chained comparison has no order" "no meaning for true, false, null or none" <<'EOF'
a = 1
b = 2
c = 3
out(a < b < c)
EOF

echo "== PROMISE: what cannot be answered faults, rather than guessing =="

die "ordering a singleton held in a variable" "no meaning for true" <<'EOF'
pick(c)
    if c != 0
        return true
    return 5
a = pick(1)
b = pick(0)
out(a < b)
EOF

die "null as a condition" "true or false" <<'EOF'
n = null
if n
    out("unreachable")
EOF

die "none as a condition" "true or false" <<'EOF'
n = number("wat")
if n
    out("unreachable")
EOF

acc "false and true ARE conditions" "no yes" <<'EOF'
say(b)
    if b
        return "yes"
    return "no"
out(say(false) . " " . say(true))
EOF

echo "== PROMISE: IEEE arithmetic is permitted; crossing to integer is checked =="
# The float arithmetic itself follows IEEE: nan == nan is false, comparisons
# with a nan are unordered, and division by zero gives infinities. What was
# wrong was the one place a float has to become an integer: round(inf),
# round(-inf) and round(nan) all answered 0, because the hardware hands back
# an indefinite word and 0x8000...*2+1 is the tagged zero.

acc "nan is not equal to itself" "false" <<'EOF'
z = 0.0
n = z / z
out(n == n)
EOF

acc "a nan compares unordered, not less and not greater" "false false" <<'EOF'
z = 0.0
n = z / z
out((n < 1.0) . " " . (n > 1.0))
EOF

acc "division by zero gives infinities, and they print" "inf -inf nan" <<'EOF'
z = 0.0
out((1.0 / z) . " " . ((0.0 - 1.0) / z) . " " . (z / z))
EOF

# Past 2^63 the hardware conversion saturates, so the renderer expands the bits
# in decimal instead. 1e25 used to print as 9223372036854775808.0.
acc "a float past 2^63 prints its own magnitude" "10000000000000000000000000.0" <<'EOF'
out(1e25)
EOF

acc "and it keeps its sign and its 15 digits" "-12345678901234500000000000.0" <<'EOF'
out(0 - 1.23456789012345e25)
EOF

acc "the ordinary range is untouched" "3.14 0.5 2.0 0.0 1000000.0" <<'EOF'
out(3.14 . " " . 0.5 . " " . 2.0 . " " . 0.0 . " " . 1e6)
EOF

acc "round does its job on ordinary values" "3 -3 1 7 0" <<'EOF'
out(round(2.5) . " " . round(0 - 2.5) . " " . round(1.4) . " " . round(7) . " " . round(0.0))
EOF

die "round(inf) faults rather than answering 0" "no whole number" <<'EOF'
z = 0.0
out(round(1.0 / z))
EOF

die "round(nan) faults rather than answering 0" "no whole number" <<'EOF'
z = 0.0
out(round(z / z))
EOF

die "round of a value past the integer range faults" "no whole number" <<'EOF'
out(round(1e300))
EOF

echo "== PROMISE: truth means the same thing in every operator that asks =="
# SPEC 3.2. `if false` was right, because gen_cond_jump knew all four singleton
# words. `&&`, `||` and `!` compared against the word 1 alone, so `false`, a
# nonzero word, read as true: `if false && x` took the true branch,
# `false || false` answered 1, and `!false` answered 0, all without a fault.
#
# There's one truth test now (gen_truth_jump / a64_truth_jump) and all four
# sites use it, which is why these are phrased as "the same answer whichever
# operator asks".
acc "false is false under &&" "no" <<'EOF'
if false && true
    out("yes")
else
    out("no")
EOF
acc "false is false under ||" "no" <<'EOF'
if false || false
    out("yes")
else
    out("no")
EOF
acc "false is false under !" "yes" <<'EOF'
if !false
    out("yes")
else
    out("no")
EOF
acc "and the true cases still answer true" "yes yes yes" <<'EOF'
a = "no"
b = "no"
c = "no"
if true && true
    a = "yes"
if false || true
    b = "yes"
if !(1 == 2)
    c = "yes"
out(a . " " . b . " " . c)
EOF
acc "as values, not just as conditions" "true false false true" <<'EOF'
out((!false) . " " . (true && false) . " " . (false || false) . " " . (false || true))
EOF
# Short-circuit still short-circuits, so a `null` on the right is never used as
# a condition when the left has already settled it.
acc "&& does not evaluate its right operand when the left is false" "false" <<'EOF'
out(false && null)
EOF
die "null is not a condition under && either" "true or false" <<'EOF'
n = null
if n && true
    out("unreachable")
EOF
die "nor under !" "true or false" <<'EOF'
n = none
if !n
    out("unreachable")
EOF

echo
echo "== PROMISE: a number is a number, or the program stops =="
# The guard on a numeric operator used to test for tag 000 and nothing else,
# which was enough while a region was the only other thing a word could be. A
# map is 100 and a singleton is 110, and both got through:
#
#     s = in()
#     n = number(s)        // "wat" -> none, the word 30
#     out(n + 1)           // 30 & 7 = 6, so no fault
#
# The add ran on the word 30 and gave 32, whose low three bits are 000, so
# `out` read it as a region pointer and dereferenced address 32. That was a
# SIGSEGV from ordinary source, where SPEC 10.2 promises a located fault.
die "arithmetic on a failed conversion faults rather than segfaulting" "number expected, got true, false, null or none" <<'EOF'
s = in()
n = number(s)
out(n + 1)
EOF
die "so does multiplying one" "number expected, got true, false, null or none" <<'EOF'
s = in()
out(number(s) * 2)
EOF
# Behind a parameter, where SPEC 10.1 can't settle the kind and the emitted
# guard has to catch it (written directly, this is a compile error).
die "a map in arithmetic faults too, and names itself" "number expected, got a map" <<'EOF'
addone(v)
    return v + 1

out(addone(5))
out(addone({a: 1}))
EOF
# With a map as the only caller, the parameter pass used to take the parameter
# for a float, and on x86-64 the build failed to link (`wasm: undefined symbol:
# rt_to_double`) instead of faulting.
die "a parameter only ever handed a map faults the same way" "number expected, got a map" <<'EOF'
addone(v)
    return v + 1

out(addone({a: 1}))
EOF
# A conversion that succeeds still answers what it always did.
acc "a conversion that succeeds is still a number" "8 number" <<'EOF'
s = "7"
n = number(s)
out((n + 1) . " " . kind(n))
EOF

echo "== PROMISE: a loop that provably cannot end is a compile error, not a hang =="
# SPEC 10.1. A forgotten `i = i + 1` fails at run time as a hang, with no
# output, no location and no exit code. The compiler can decide it because
# word has no references and no closures (5.1, 8.1): a callee can't rebind a
# caller's local, so a body that never assigns the condition's names can't
# change the condition, unless the condition reads inside a region or a map
# (see the cases at the end).

rej "a loop whose body never touches its condition" "this loop cannot end" <<'EOF'
i = 0
loop i < 3
    out(i)
EOF

# And the shapes that must keep working. A false rejection would be worse than
# the bug.
acc "loop 1 with a break is the deliberate forever-loop" "3" <<'EOF'
i = 0
loop true
    i = i + 1
    if i > 2
        break
out(i)
EOF

acc "a condition containing a call may answer differently" "3" <<'EOF'
more(n)
    return n < 3

i = 0
loop more(i)
    i = i + 1
out(i)
EOF

acc "the body assigning from a callee is still assigning" "3" <<'EOF'
bump(n)
    return n + 1

i = 0
loop i < 3
    i = bump(i)
out(i)
EOF

acc "a body that returns can leave the loop" "1" <<'EOF'
f(a)
    loop a < 3
        return 1
    return 0

out(f(1))
EOF

# A callee can't rebind the caller's `a`, but it can write into the region or
# map `a` holds, and so can a store through a second name. A condition that
# reads inside one is left alone when the body has a call or an index store.
acc "a callee can write into the region the condition reads" "3" <<'EOF'
grow(r)
    r[0] = r[0] + 1
    return 0

a = array(1)
loop a[0] < 3 && true
    k = grow(a)
out(a[0])
EOF

acc "a callee can add the key the condition waits for" "1" <<'EOF'
put(m)
    m["k"] = 1
    return 0

m = {}
loop m["k"] == none
    k = put(m)
out(m["k"])
EOF

acc "a callee can change a region the condition compares" "q" <<'EOF'
fill(r)
    r[0] = 113
    return 0

s = text(1)
s[0] = 97
loop s != "q"
    k = fill(s)
out(s)
EOF

acc "a store through a second name changes the region" "1" <<'EOF'
a = array(1)
b = a
loop a[0] == 0
    b[0] = 1
out(a[0])
EOF

rej "a call can't change a number the condition reads" "this loop cannot end" <<'EOF'
next(n)
    return n + 1

i = 0
loop i < 3
    k = next(i)
EOF

# sys.recv writes into the buffer it's handed (SPEC 12.5), so a loop waiting
# for its first byte can end. It used to be refused as a loop that cannot end.
# The loop is never entered here, so nothing is read from a socket. recv is
# the only builtin that writes into an argument.
acc "recv can fill the buffer the condition reads" "done" <<'EOF'
buf = bytes(1)
buf[0] = 1
fd = 0
loop buf[0] == 0
    n = recv(fd, buf)
out("done")
EOF

rej "recv can't change a number the condition reads" "this loop cannot end" <<'EOF'
buf = bytes(1)
i = 0
loop i < 3
    n = recv(0, buf)
EOF

echo
echo "== PROMISE: a name means one thing, and a function sees only its own =="
# SPEC 5.1: one binding per name per function, so there's nothing to shadow,
# except that a `loop x in` variable still has to be a fresh name (7.2).
# Function scope and top-level scope are separate (not nested), so nothing
# leaks in and there's no global mutable state.

rej "a loop variable may not reuse a live local" "already defined" <<'EOF'
f(a)
    x = 1
    loop x in a
        out(x)
    return x

out(f(array(2)))
EOF

rej "a function cannot see a top-level variable" "undefined variable 'g'" <<'EOF'
g = 5
f()
    return g

out(f())
EOF

acc "but it may reuse the name for its own local" "6" <<'EOF'
g = 5
f()
    g = 1
    return g

out(g + f())
EOF

acc "two loops may each bind the same fresh name" "1212" <<'EOF'
f(a)
    a[0] = 1
    a[1] = 2
    s = ""
    loop x in a
        s = s . x
    loop x in a
        s = s . x
    return s

out(f(array(2)))
EOF

rej "two functions of one name is an error, not a winner" "already defined" <<'EOF'
f()
    return 1

f()
    return 2

out(f())
EOF

rej "a call must match the definition's arity" "expects 2 argument(s)" <<'EOF'
f(a, b)
    return a + b

out(f(1))
EOF

rej "a misspelled name is genuinely unknown" "call to undefined function 'raed'" <<'EOF'
out(raed("f"))
EOF

rej "break outside a loop" "'break' is only allowed inside a loop" <<'EOF'
break
EOF

echo
echo "== PROMISE: a contract guards what it says it guards =="
# SPEC 8.2/8.3. Names are global across a program (11), so without these rules
# a file you didn't write could attach a guard to your function without a word,
# or a shared body could name a parameter that means something different in
# each function.

rej "a hook may not guard a builtin" "contract hook names undefined function 'out'" <<'EOF'
out:before
    return true

out(1)
EOF

rej "a hook may not name a function that does not exist" "undefined function 'nope'" <<'EOF'
nope:before
    return true

out(1)
EOF

rej "one function, at most one before-hook" "already has a ':before' hook" <<'EOF'
f(a)
    return a

f:before
    return true

f:before
    return true

out(f(1))
EOF

rej "an :after hook and a 'result' parameter cannot coexist" "cannot have a parameter named 'result'" <<'EOF'
f(result)
    return result

f:after
    return true

out(f(1))
EOF

rej "a bare return in a hook" "bare 'return' is not allowed in a hook" <<'EOF'
f(a)
    return a

f:before
    return

out(f(1))
EOF

rej "functions sharing a hook need identical parameters" "identical parameters" <<'EOF'
f(a)
    return a

g(b, c)
    return b + c

f:before, g:before
    return true

out(f(1) + g(1, 2))
EOF

rej "a shared hook is all-before or all-after" "not a mix" <<'EOF'
f(a)
    return a

g(a)
    return a

f:before, g:after
    return true

out(f(1) + g(2))
EOF

acc "and the shared hook that follows the rules works" "3" <<'EOF'
f(amount)
    return amount

g(amount)
    return amount + 1

f:before, g:before
    if amount <= 0
        return false
    return true

out(f(1) + g(1))
EOF

echo
echo "== PROMISE: a kind error is caught, statically wherever the kind is known =="
# SPEC 10.1 reports what it can work out, and 10.2 catches the rest at run
# time. Each mistake below is written three ways: in the open, behind a name
# whose kind is settled, and behind one whose kind is open. The third is the
# one that matters. It shows the line between compile time and run time is
# about diagnostics, not safety: a kind the analyzer doesn't know is a kind the
# tag test still checks (3.6).

rej "len of a number, in the open" "'len' needs a region" <<'EOF'
out(len(3))
EOF
rej "len of a number, behind a name" "'len' needs a region" <<'EOF'
x = 3
out(len(x))
EOF

rej "indexing a number, in the open" "cannot index a number" <<'EOF'
out(3[0])
EOF
rej "indexing a number, behind a name" "cannot index a number" <<'EOF'
x = 3
out(x[0])
EOF

rej "arithmetic on text, in the open" "must be a number, but got a region" <<'EOF'
out("ab" - 1)
EOF
rej "arithmetic on text, behind a name" "must be a number, but got a region" <<'EOF'
x = "ab"
out(x - 1)
EOF

rej "ordering a number against text, in the open" "cannot compare a number with a region" <<'EOF'
out(1 < "ab")
EOF
rej "ordering a number against text, behind a name" "cannot compare a number with a region" <<'EOF'
x = "ab"
out(1 < x)
EOF

# The third way: a name whose kind no assignment in this body settles. A
# parameter holds what the caller passed, a name assigned differently on two
# paths is either, and a call into a word function answers what it answers.
# None of those is rejected, and none is unsafe: the tag test is still there,
# and it faults with a location instead of carrying on.
die "a parameter's kind is the caller's business" "region expected, got a number" <<'EOF'
f(a)
    return len(a)

out(f(3))
EOF

die "two paths that disagree leave the kind open" "region expected, got a number" <<'EOF'
c = 1
if c == 1
    x = 3
else
    x = "ab"
out(len(x))
EOF

die "a word function's result is not tracked" "region expected, got a number" <<'EOF'
mk()
    return 3

x = mk()
out(len(x))
EOF

# And the shapes that must keep compiling. Each of these could have been a
# false rejection.
acc "a parameter read before it is reassigned" "2" <<'EOF'
f(a)
    n = len(a)
    a = 3
    return n + a - 3

out(f("ab"))
EOF

acc "a name that legitimately changes kind" "2" <<'EOF'
x = 3
x = "ab"
out(len(x))
EOF

acc "a for-each variable is an element, not a kind" "2" <<'EOF'
f(a)
    a[0] = "xy"
    n = 0
    loop v in a
        n = n + len(v)
    return n

out(f(array(1)))
EOF

acc "result in an :after hook is the callee's answer" "2" <<'EOF'
f(a)
    return a

f:after
    return len(result) == 2

out(len(f("ab")))
EOF

echo "== PROMISE: a map never holds a key it cannot find =="
#
# SPEC 3.7: a map keeps the key region itself, not a copy, so the name that
# spelled the key still refers to the map's own key. The key's slot in the hash
# index was chosen from its contents, so a write through that name left the map
# holding a key it could no longer find: `out(m)` printed {"xbc":1} while both
# m["abc"] and m["xbc"] answered none, and two distinct keys could be made the
# same text. The region stops being writable when it becomes a key, and the
# write faults.
#
# The append path was already guarded by the uniqueness pass (test_gaps.sh, "a
# map key is not rewritten by a later append"). The indexed store had no guard,
# and no analysis could give it one: `keys(m)[0][0] = 'x'` never names the key.

die "an indexed write to a map key is refused" "write to a map key" <<'EOF'
k = "" . "abc"
m = {}
m[k] = 1
k[0] = 'x'
EOF

die "the fault is located at the write" "p.w:4:" <<'EOF'
k = "" . "abc"
m = {}
m[k] = 1
k[0] = 'x'
EOF

die "a key reached through keys() is refused too" "write to a map key" <<'EOF'
k = "" . "abc"
m = {}
m[k] = 1
q = keys(m)
q[0][0] = 'x'
EOF

die "two keys cannot be made equal after the fact" "write to a map key" <<'EOF'
a = "" . "ab"
b = "" . "ac"
m = {}
m[a] = 1
m[b] = 2
a[1] = 'c'
EOF

die "a byte-backed key is a key" "write to a map key" <<'EOF'
b = bytes(3)
b[0] = 'a'
b[1] = 'b'
b[2] = 'c'
m = {}
m[b] = 1
b[0] = 'x'
EOF

die "a key json.parse built is a key" "write to a map key" <<'EOF'
m = parse("{\"abc\":1}")
q = keys(m)
q[0][0] = 'x'
EOF

die "a second alias of the same region is the same key" "write to a map key" <<'EOF'
k = "" . "abc"
a = array(1)
a[0] = k
m = {}
m[k] = 1
a[0][0] = 'x'
EOF

die "a key stored through a nested subscript is a key" "write to a map key" <<'EOF'
m = {}
m["in"] = {}
k = "" . "abc"
m["in"][k] = 1
k[0] = 'x'
EOF

die "a {} literal value used as a key is a key" "write to a map key" <<'EOF'
k = "" . "abc"
m = {}
m[k] = 1
n = {a: k}
n["a"][0] = 'x'
EOF

# Two things wrong at once: the region can't be written and the index is out of
# range. The read-only check comes first, on both targets (test_a64_lang.sh runs
# these on arm64 too).
die "a key written out of range is still a key" "write to a map key" <<'EOF'
k = "" . "abc"
m = {}
m[k] = 1
k[99] = 'x'
EOF

die "a literal written out of range is still a literal" "write to a literal" <<'EOF'
s = "abc"
s[99] = 'x'
EOF

# A literal key is unwritable for the older reason, and keeps the older message.
die "a literal key still says literal" "write to a literal" <<'EOF'
m = {}
m["abc"] = 1
q = keys(m)
q[0][0] = 'x'
EOF

# What must still work. Only writing through the key is refused: reading it,
# joining it, copying it and giving the name a new region all work as before.
acc "copy() of a key is the writable one, and the map is untouched" "{\"abc\":1} xbc 1" <<'EOF'
k = "" . "abc"
m = {}
m[k] = 1
c = copy(k)
c[0] = 'x'
out(m . " " . c . " " . m["abc"])
EOF

acc "an append to the name still leaves the key alone" "{\"abc\":1} abcx 1 none" <<'EOF'
m = {}
t = "" . "abc"
m[t] = 1
t = t . "x"
out(m . " " . t . " " . m["abc"] . " " . m["abcx"])
EOF

acc "an append to a key read out of keys() leaves the key alone" "{\"abc\":1} abcx" <<'EOF'
m = {}
m["" . "abc"] = 1
t = keys(m)[0]
t = t . "x"
out(m . " " . t)
EOF

acc "reading a key, and every allocating use of one, is unaffected" "abc 3 97 abc abc 1" <<'EOF'
k = "" . "abc"
m = {}
m[k] = 1
q = keys(m)
out(k . " " . len(k) . " " . k[0] . " " . copy(k) . " " . sort(q)[0] . " " . m[k])
EOF

# Overwriting an existing key doesn't keep the region that spelled it: the map
# keeps the key it already had, so the second name is still an ordinary
# writable region, and writing it can't reach the map.
acc "a key that only overwrote an existing pair is not retained" "{\"abc\":2} xbc 2" <<'EOF'
a = "" . "abc"
b = "" . "abc"
m = {}
m[a] = 1
m[b] = 2
b[0] = 'x'
out(m . " " . b . " " . m["abc"])
EOF

acc "the map still answers every key it prints, after a copy and a sort" "3 a=1 b=2 c=3" <<'EOF'
m = {}
m["" . "a"] = 1
m["" . "b"] = 2
m["" . "c"] = 3
n = copy(m)
s = ""
loop k in sort(keys(n))
    s = s . " " . k . "=" . n[k]
out(len(n) . s)
EOF

acc "a program with no map pays nothing and still writes its regions" "xbcd" <<'EOF'
s = "" . "abcd"
s[0] = 'x'
out(s)
EOF

echo "== PROMISE: a comparison ends, with an answer or with a diagnostic =="
#
# SPEC 3.3 says `==` compares by content "all the way down", and a program can
# build a value with no bottom: `a[0] = a` is an ordinary store. Two separate
# cycles have no finite content to compare. On x86-64 the answer used to be the
# stack guard's `stack exhausted`, which sent the reader of a program with no
# recursion looking for a runaway function, and on arm64 rt_eq had no guard, so
# the answer was SIGSEGV, which SPEC 10.2 rules out.
#
# word doesn't implement equality over infinite structures. A comparison that
# walks into one is refused at the same bound a deep one is, with a message
# that names the likely cause.

die "two independent cycles are refused, not crashed" "comparison nests too deeply (a cycle?)" <<'EOF'
a = array(1)
a[0] = a
b = array(1)
b[0] = b
out(a == b)
EOF

die "!= goes the same way: it is the same walk" "comparison nests too deeply (a cycle?)" <<'EOF'
a = array(1)
a[0] = a
b = array(1)
b[0] = b
out(a != b)
EOF

die "two independently cyclic maps too" "comparison nests too deeply (a cycle?)" <<'EOF'
a = {}
a["self"] = a
b = {}
b["self"] = b
out(a == b)
EOF

die "a cycle through a map value inside an array" "comparison nests too deeply (a cycle?)" <<'EOF'
a = array(1)
a[0] = {}
a[0]["up"] = a
b = array(1)
b[0] = {}
b[0]["up"] = b
out(a == b)
EOF

# The cases that do have a finite answer still get it. An element that's the
# same word as the one it's compared against is equal without recursing, so a
# cyclic value compared with itself never reaches the bound, and a pair that
# differs before the walk gets that far is decided where it differs.
acc "a cyclic value equals itself" "true true" <<'EOF'
a = array(1)
a[0] = a
m = {}
m["self"] = m
out((a == a) . " " . (m == m))
EOF

acc "a cycle against a value that is not one is decided, not walked" "false false false" <<'EOF'
a = array(1)
a[0] = a
b = array(2)
b[0] = b
c = array(2)
c[0] = 1
c[1] = c
d = array(2)
d[0] = d
d[1] = 1
out((a == array(1)) . " " . (a == b) . " " . (c == d))
EOF

# Ordering walks the same structures, by the same rules and behind the same
# bound, so each answer above holds for `<` too, and two cycles ordered against
# each other are refused the same way instead of compared by the addresses of
# their elements.
die "two cycles ordered are refused too" "comparison nests too deeply (a cycle?)" <<'EOF'
a = array(1)
a[0] = a
b = array(1)
b[0] = b
out(a < b)
EOF

acc "a cyclic value has no order against itself, and does not hang" "false true" <<'EOF'
a = array(1)
a[0] = a
out((a < a) . " " . (a <= a))
EOF

acc "an order decided before the cycle is still decided" "true false" <<'EOF'
a = array(2)
a[0] = 1
a[1] = a
b = array(2)
b[0] = 2
b[1] = b
out((a < b) . " " . (b < a))
EOF

# A region of anything but numbers used to be ordered by its elements'
# addresses, so this printed `true true`: each row was allocated after the one
# it was compared against. That broke trichotomy (exactly one of <, == and >
# holds), which sort depends on.
acc "ordering is by content, and exactly one of the three holds" "false true false true" <<'EOF'
one(v)
    r = array(1)
    r[0] = v
    return r
out((one("b") < one("a")) . " " . (one("a") < one("b")) . " " . (one("a") == one("b")) . " " . (one("a") == one("a")))
EOF

acc "and at the depth where the elements are equal" "false false true" <<'EOF'
one(v)
    r = array(1)
    r[0] = v
    return r
x = one(one("a"))
y = one(one("a"))
out((x < y) . " " . (y < x) . " " . (x == y))
EOF

# A nan has no order against anything (SPEC 2.6), and an element that's a nan
# leaves the regions with no order either: all four operators are false, as
# they are on the numbers.
acc "an unordered element leaves the regions unordered" "false false false false false" <<'EOF'
one(v)
    r = array(1)
    r[0] = v
    return r
z = 0.0
n = one(z / z)
f = one(1.0)
out((n < f) . " " . (n <= f) . " " . (n > f) . " " . (n >= f) . " " . (n == f))
EOF

# stringify, the other walk over the same structure, already refused a cycle
# this way, and the comparison's message follows it (SPEC 10.2).
die "stringify of a cycle still names the cycle" "json: value nests too deeply (a cycle?)" <<'EOF'
import json
a = array(1)
a[0] = a
out(stringify(a))
EOF

echo
echo "guarantees: $pass passed, $fail failed"
[ "$fail" = 0 ]
