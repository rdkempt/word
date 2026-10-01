#!/bin/sh
# test_json.sh: the {} and json conformance suite. `{}` is a map (SPEC 3.7): an
# insertion-ordered key-value store on the extension tag, and JSON is what it
# prints as. It covers the literal, reads and writes, len/keys/has, equality,
# the json module's parse/stringify round trip, and the failure modes,
# including the ones an untrusted payload can reach (deep nesting, lone
# surrogates, huge exponents), which have to fail as data, never as a crash.
#
# No `set -e`, since several cases are meant to fault.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 20"
p="$tmp/p.w"; exe="$tmp/p"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  OK   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1 -- $2"; }

# ev NAME EXPR EXPECTED : build+run `import json / out(EXPR)`, compare stdout.
ev() { { echo 'import json'; printf 'out(%s)\n' "$2"; } > "$p"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
    bad "$1" "build failed: $("$WORD" build "$p" -o "$exe" 2>&1)"; return; fi
  got=$($TO "$exe" 2>&1); rc=$?
  if [ "$got" = "$3" ] && [ "$rc" = 0 ]; then ok "$1"
  else bad "$1" "$2 -> [$got] rc=$rc want [$3]"; fi; }

# prog NAME EXPECTED : the program is on stdin, compare all of stdout.
prog() { name=$1; want=$2; cat > "$p"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
    bad "$name" "build failed: $("$WORD" build "$p" -o "$exe" 2>&1)"; return; fi
  got=$($TO "$exe" 2>&1); rc=$?
  if [ "$got" = "$want" ] && [ "$rc" = 0 ]; then ok "$name"
  else bad "$name" "[$got] rc=$rc want [$want]"; fi; }

# faults NAME SUBSTR : the program is on stdin and must fault (rc 70) saying SUBSTR.
faults() { name=$1; want=$2; cat > "$p"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
    bad "$name" "build failed: $("$WORD" build "$p" -o "$exe" 2>&1)"; return; fi
  got=$($TO "$exe" 2>&1); rc=$?
  case "$got" in *"$want"*) m=1;; *) m=0;; esac
  if [ "$m" = 1 ] && [ "$rc" = 70 ]; then ok "$name"
  else bad "$name" "[$got] rc=$rc want fault matching [$want]"; fi; }

# cerr NAME SUBSTR : the program is on stdin and must be rejected at compile time.
cerr() { name=$1; want=$2; cat > "$p"
  got=$("$WORD" build "$p" -o "$exe" 2>&1); rc=$?
  case "$got" in *"$want"*) m=1;; *) m=0;; esac
  if [ "$m" = 1 ] && [ "$rc" != 0 ]; then ok "$name"
  else bad "$name" "[$got] rc=$rc want compile error matching [$want]"; fi; }

echo "== the {} literal =="
ev "empty map"            '{}'                       '{}'
ev "bare keys"            '{a: 1, b: 2}'             '{"a":1,"b":2}'
ev "quoted keys"          '{"content-type": "json"}' '{"content-type":"json"}'
ev "bare and quoted mix"  '{"a b": 1, c: 2}'         '{"a b":1,"c":2}'
ev "text values"          '{name: "Ada"}'            '{"name":"Ada"}'
ev "nested maps"          '{a: {b: {c: 1}}}'         '{"a":{"b":{"c":1}}}'
ev "expression values"    '{n: 2 + 3, t: "a" . "b"}' '{"n":5,"t":"ab"}'
ev "insertion order kept" '{z: 1, a: 2, m: 3}'       '{"z":1,"a":2,"m":3}'
ev "later key wins"       '{a: 1, a: 2}'             '{"a":2}'
ev "negative and float"   '{a: 0 - 1, b: 1.5}'       '{"a":-1,"b":1.5}'

prog "a literal spans lines, trailing comma allowed" '{"name":"Ada","age":36}' <<'EOF'
import json
m = {
    name: "Ada",
    age: 36,
}
out(m)
EOF

echo "== reading and writing =="
prog "read, absent key, has, len" 'Ada
36
true
false
none
true
false
2' <<'EOF'
p = {name: "Ada", age: 36}
out(p["name"])
out(p["age"])
out(has(p, "name"))
out(has(p, "email"))
out(p["email"])
out(p["email"] == none)
out(p["email"] == 0)
out(len(p))
EOF

# An absent key answers `none`, not 0, so `if p["email"]` faults instead of
# answering. `if` on a missing field used to read as "no", which is right until
# a field holds 0, and then it's wrong without any sign. The two questions have
# two spellings now: `== none` and has().
prog "an absent key is none, and a 0 value is still present" 'no email
zero is there
0' <<'EOF'
p = {count: 0}
if p["email"] == none
    out("no email")
else
    out("has email")
if has(p, "count")
    out("zero is there")
out(p["count"])
EOF

# `if` on a missing key is a fault instead of a guess: exit 70 with the message
# SPEC 3.8 names.
cat > "$p" <<'EOF'
p = {count: 0}
if p["email"]
    out("has email")
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$("$exe" 2>&1); rc=$?
  case "$got" in
    *"a condition must be true or false"*)
      if [ "$rc" = 70 ]; then ok "\`if\` on a missing key faults instead of guessing"
      else bad "if on a missing key" "right message, exit $rc not 70"; fi ;;
    *) bad "if on a missing key" "got [$got] rc=$rc" ;;
  esac
else bad "if on a missing key" "build failed"; fi

prog "write appends, overwrite keeps its place" '{"a":1,"b":2}
{"a":9,"b":2}
2' <<'EOF'
import json
m = {a: 1}
m["b"] = 2
out(m)
m["a"] = 9
out(m)
out(len(m))
EOF

prog "keys() gives insertion order" 'z
a
m
3' <<'EOF'
m = {z: 1, a: 2, m: 3}
ks = keys(m)
i = 0
loop i < len(ks)
    out(ks[i])
    i = i + 1
out(len(ks))
EOF

prog "a computed key" 'v' <<'EOF'
k = "na" . "me"
m = {}
m[k] = "v"
out(m[k])
EOF

prog "a map flows through a function" '7' <<'EOF'
pick(o, k)
    return o[k]
out(pick({n: 7}, "n"))
EOF

echo "== equality =="
prog "equality is by content, order-independent" 'true
true
false
false
false
false
false
true' <<'EOF'
a = {x: 1, y: "two"}
b = {y: "two", x: 1}
out(a == a)
out(a == b)
out(a == {x: 1, y: "three"})
out(a == {x: 1})
out(a == "x")
out(a == 0)
out(0 == a)
out(a != {x: 1})
EOF

prog "nested maps compare by content" 'true
false
true' <<'EOF'
out({p: {q: 1}} == {p: {q: 1}})
out({p: {q: 1}} == {p: {q: 2}})
out({} == {})
EOF

# "By content" goes all the way down (SPEC 3.3): two elements that aren't the
# same word are still equal if they're equal structures. That's what makes a
# parsed payload equal the literal it came from, arrays and all.
prog "equality reaches into nested regions and maps" 'true
false
true
false
true
true
true' <<'EOF'
import json
a = array(2)
a[0] = 1
a[1] = array(1)
a[1][0] = "x"
b = array(2)
b[0] = 1
b[1] = array(1)
b[1][0] = "x"
out(a == b)
c = array(1)
c[0] = array(1)
c[0][0] = "y"
out(a == c)
d = array(1)
d[0] = {k: 1}
e = array(1)
e[0] = {k: 1}
out(d == e)
f = array(1)
f[0] = {k: 2}
out(d == f)
out(find(d, e) == 0)
m = {tags: parse("[1,2,{\"k\":\"v\"}]"), name: "Ada"}
out(parse(stringify(m)) == m)
n = {langs: array(1)}
n["langs"][0] = "word"
out(parse(stringify(n)) == n)
EOF

echo "== printing and joining =="
ev "out() prints JSON"     '{a: 1}'                 '{"a":1}'
ev "join renders JSON"     '"v=" . {a: 1}'          'v={"a":1}'

echo "== a map is not a region =="
# sort() and find() check their argument's tag on entry (a wrong kind used to
# crash them), so a map is refused with the region builtins' own message,
# "region expected, got a map", instead of the generic "this needs a number or
# a region, not a map" from rt_bytepromote. The entry check also makes x86-64
# and arm64 agree here, where sort() used to differ. Ordering a map keeps the
# generic message, which rt_order gives on both targets (rt_ordbad).
faults "sort(map) faults"        "got a map" <<'EOF'
out(len(sort({a: 1})))
EOF
faults "find with a map faults"  "got a map" <<'EOF'
xs = array(1)
xs[0] = 1
out(find(xs, {a: 1}))
EOF
faults "ordering maps faults"    "not a map" <<'EOF'
out({a: 1} < {b: 2})
EOF
# A float on the other side used to send this to the float comparison, which
# read the map's cell address as an integer and answered false one way and true
# the other.
faults "ordering a map against a float faults" "not a map" <<'EOF'
out({a: 1} < 1.5)
EOF
faults "ordering a float against a map faults" "not a map" <<'EOF'
out(1.5 < {a: 1})
EOF
cerr "a map key must be text"    "map key must be text" <<'EOF'
out({a: 1}[0])
EOF
cerr "indexing a region with text is still an error" "index must be a number" <<'EOF'
a = text(2)
out(a["k"])
EOF
cerr "keys() of static text is rejected"  "'keys' needs a map, but got a region" <<'EOF'
out(len(keys("hi")))
EOF
cerr "keys() of a number is rejected"     "'keys' needs a map, but got a number" <<'EOF'
out(len(keys(5)))
EOF
cerr "has() of static text is rejected"   "'has' needs a map, but got a region" <<'EOF'
out(has("hi", "x"))
EOF
faults "keys() of a non-map parameter faults cleanly" "needs a map" <<'EOF'
ks(o)
    return len(keys(o))
a = text(3)
out(ks(a))
EOF
faults "has() of a non-map parameter faults cleanly" "needs a map" <<'EOF'
hk(o)
    return has(o, "x")
out(hk("text"))
EOF

echo "== growth: the pair region and hash index rebuild past 8 keys ==" 
prog "500 keys: values, order, overwrite, has all survive reindex" 'len 500
wrong 0
order 0
k0=999 len 500
misses 0
absent false' <<'EOF'
m = {}
i = 0
loop i < 500
    m["k" . i] = i * 7
    i = i + 1
out("len " . len(m))
bad = 0
i = 0
loop i < 500
    if m["k" . i] != i * 7
        bad = bad + 1
    i = i + 1
out("wrong " . bad)
ks = keys(m)
ob = 0
i = 0
loop i < 500
    if ks[i] != "k" . i
        ob = ob + 1
    i = i + 1
out("order " . ob)
m["k0"] = 999
out("k0=" . m["k0"] . " len " . len(m))
miss = 0
i = 0
loop i < 500
    if has(m, "k" . i) == 0
        miss = miss + 1
    i = i + 1
out("misses " . miss)
out("absent " . has(m, "nope"))
EOF

prog "writing to a parsed map reindexes correctly" 'len 52
kept 1 2
new 49
has true' <<'EOF'
import json
m = parse("{\"a\":1,\"b\":2}")
i = 0
loop i < 50
    m["x" . i] = i
    i = i + 1
out("len " . len(m))
out("kept " . m["a"] . " " . m["b"])
out("new " . m["x49"])
out("has " . has(m, "x25"))
EOF

echo "== json.parse =="
ev "object"       'stringify(parse("{\"a\":1,\"b\":2}"))'     '{"a":1,"b":2}'
ev "array"        'stringify(parse("[1,2,3]"))'               '[1,2,3]'
ev "empty object" 'stringify(parse("{}"))'                    '{}'
ev "empty array"  'stringify(parse("[]"))'                    '[]'
ev "nested"       'stringify(parse("{\"a\":[1,{\"b\":2}]}"))' '{"a":[1,{"b":2}]}'
ev "whitespace"   'stringify(parse("  { \"a\" : [ 1 , 2 ] } "))' '{"a":[1,2]}'
ev "bare string"  'parse("\"just text\"")'                    'just text'
ev "bare number"  'parse("42")'                               '42'
ev "negative"     'parse("-17")'                              '-17'
ev "float"        'parse("-3.5")'                             '-3.5'
ev "exponent"     'parse("1e3")'                              '1000.0'
ev "neg exponent" 'parse("15e-1")'                            '1.5'

# A JSON number has no size limit and word's integers are 63-bit, so a document
# can carry one that doesn't fit. An int64 id is the everyday case, and
# 9223372036854775807 is what every other language's Long.MAX_VALUE writes
# out. The digit loop used to multiply by ten with no ceiling and wrap: that id
# parsed as -1, and the first value past the top of the range came back with
# its sign flipped.
#
# Past the ceiling the answer is a float, which is what JSON's own number model
# and every other parser give, and what word already gave for the same value
# written as 9.223372036854776e18.
ev "the largest word integer stays an integer" 'parse("4611686018427387903")' '4611686018427387903'
ev "one past it is a float, not a sign flip"   'parse("4611686018427387904")' '4611686018427387904.0'
# The range is -2^62 .. 2^62 - 1, so the bottom end is one further from zero
# than the top. The last digit used to be allowed to be 3 either way, so -2^62
# came back as a float, which % then refused as not a whole number.
ev "the smallest word integer stays an integer" 'parse("-4611686018427387904")' '-4611686018427387904'
ev "and works as one"                           'parse("-4611686018427387904") % 3' '-1'
ev "one below it is a float"                    'parse("-4611686018427387905")' '-4611686018427387904.0'
ev "an int64 id does not wrap"                 'parse("9223372036854775807")' '9223372036854780000.0'
ev "and neither does a 30-digit one"           'parse("123456789012345678901234567890")' '123456789012346000000000000000.0'

# The same ceiling on the fraction, which wrapped the same way: a value of 1.0
# written with 29 decimal places parsed as 7.886e-11.
ev "a fraction longer than the mantissa"       'parse("0.12345678901234567890123456789")' '0.12345678901235'
ev "trailing zeros past the mantissa are 1.0"  'parse("1.00000000000000000000000000001")' '1.0'

# number() reads the same grammar and has to reach the same value. They share
# rt_f10scale so one string can't mean two numbers. number() used to answer
# `none` here.
ev "number() agrees past the ceiling"          'number("9223372036854775807") == parse("9223372036854775807")' 'true'
ev "number() agrees on a long fraction"        'number("1.00000000000000000000000000001") == parse("1.00000000000000000000000000001")' 'true'
ev "number() still refuses a non-number"       'number("wat") == none' 'true'

# parse reads digits the way the compiler reads a float literal, so it has to
# give the same double: the nearest one to all of the digits (SPEC 2.6). It
# used to keep 19 digits and scale them by ten a step at a time, which rounds
# at every step, so a number with 16 or more significant digits or an exponent
# past 15 could come out one double off. "0.30000000000000004", which most
# languages write for 0.1 + 0.2, was one of them. Past the integer range a
# dropped digit also let a later, smaller one in one place too high:
# "46116860184273879041e22" was read as 4611686018427387901e23.
#
# Each case is compared with the literal for the double Python's float() gives.
# The last three are the largest double: rounding it to 15 digits for
# stringify gave 1.79769313486232e308, past the largest double, which parse
# rightly refuses, so the top of the range is cut off instead of rounded up.
cat > "$tmp/near.w" <<'EOF'
import json
c(s, want)
    v = parse("[" . s . "]")
    if v == none
        return s . " none"
    if v[0] != want
        return s . " off"
    return "ok"

out(c("46116860184273879041e22", 4.611686018427388e+41))
out(c("-46116860184273879051e22", 0.0 - 4.611686018427388e+41))
out(c("70404.301035722134e2", 7040430.103572213))
out(c("0.30000000000000004", 0.1 + 0.2))
out(c("123.45678901234567", 123.45678901234567))
out(c("123456789012345678901234567890", 1.2345678901234568e+29))
out(c("9223372036854775807", 9.223372036854776e+18))
out(c("18446744073709551617", 1.8446744073709552e+19))
out(c("1e-20", 1e-20))
out(c("1.5e300", 1.5e+300))
out(c("1.7976931348623157e308", 1.7976931348623157e+308))
out(c("2.2250738585072014e-308", 2.2250738585072014e-308))
out(c("5e-324", 5e-324))
out(c("2.4703282292062328e-324", 5e-324))
out(c("2.4703282292062327e-324", 0.0))
out(c("1.00000000000000011102230246251565404236316680908203125", 1.0))
out(c("1.00000000000000011102230246251565404236316680908203125000001", 1.0000000000000002))
out(c("1.00000000000000011102230246251565404236316680908203124999999", 1.0))
out(c("3.14159265358979323846264338327950288", 3.141592653589793))
m = 1.7976931348623157e308
out(parse(stringify({v: m})) != none)
out(parse(stringify({v: 0.0 - m})) != none)
out(number("" . m) == 1.79769313486231e308)
EOF
QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
want=$(printf 'ok\n%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19; printf 'true\ntrue\ntrue')
for tgt in x86 arm64; do
  [ "$tgt" = arm64 ] && [ -z "$QEMU" ] && { echo "  SKIP parse gives the nearest double (arm64): no qemu-aarch64"; continue; }
  fl=""; run=""; [ "$tgt" = arm64 ] && { fl=-arm64; run=$QEMU; }
  if "$WORD" build $fl "$tmp/near.w" -o "$tmp/near.$tgt" >/dev/null 2>&1; then
    got=$($TO $run "$tmp/near.$tgt" 2>&1); rc=$?
    if [ "$got" = "$want" ] && [ "$rc" = 0 ]; then ok "parse gives the nearest double ($tgt)"
    else bad "parse gives the nearest double ($tgt)" "[$(echo "$got" | grep -v '^ok$' | tr '\n' '|')] rc=$rc"; fi
  else bad "parse gives the nearest double ($tgt)" "build failed"; fi
done
ev "true is true"   'parse("true")'                           'true'
ev "false is false" 'parse("false")'                          'false'
ev "null is null"   'parse("null")'                           'null'
ev "false is not 0" 'parse("false") == 0'                     'false'
ev "null is not 0"  'parse("null") == 0'                      'false'
ev "0 is still 0"   'parse("0")'                              '0'
ev "escapes"      'stringify(parse("{\"s\":\"a\\nb\\t\\\"q\\\"\\\\z\"}"))' '{"s":"a\nb\t\"q\"\\z"}'
ev "\\u escape"   'parse("\"\\u00e9\\u0041\"")'               'éA'
ev "surrogate pair -> one code point" 'parse("\"\\ud83d\\ude00\"")' '😀'
ev "lone surrogate -> U+FFFD"         'len(parse("\"\\ud83d\""))'   '1'
ev "a \\u escape with no hex digits is refused" 'kind(parse("\"\\uzzzz\""))' 'none'
ev "duplicate key: last wins" 'stringify(parse("{\"a\":1,\"a\":2}"))' '{"a":2}'
ev "a parsed map is an ordinary map" 'parse("{\"a\":{\"b\":7}}")["a"]["b"]' '7'

# JSON text is UTF-8 (RFC 8259), and read() and get() hand back bytes, so a
# byte-backed document is decoded the way decode() does it. It used to be read
# one code point per byte, so "José" in a file parsed as "JosÃ©".
prog "a byte-backed document is decoded as UTF-8" 'true 4 true true' <<'EOF'
import json
import txt
b = encode("{\"name\":\"José\",\"Köln\":1}")
v = parse(b)
out((v["name"] == "José") . " " . len(v["name"]) . " " . has(v, "Köln") . " " . (v == parse(decode(b))))
EOF
prog "a byte that isn't UTF-8 reads the way decode() reads it" 'true 255' <<'EOF'
import json
import txt
b = bytes(4)
b[0] = 34
b[1] = 97
b[2] = 255
b[3] = 34
v = parse(b)
out((v == parse(decode(b))) . " " . v[1])
EOF

echo "== json.parse rejects malformed text (as data, not a fault) =="
# Failure is `none`, not 0. Parsing the text "0" succeeds and gives 0, so a
# failure that answered 0 couldn't be told from a document that said 0, and
# that's what hid the truncated-keyword bug below.
ev "unclosed object" 'parse("{oops")'      'none'
ev "unclosed array"  'parse("[1,2,")'      'none'
ev "missing value"   'parse("{\"a\"}")'    'none'
ev "trailing junk"   'parse("{} x")'       'none'
ev "empty text"      'parse("")'           'none'
ev "bare comma"      'parse(",")'          'none'
ev "a failure has its own value, so a plain equality test works" 'parse("{") == none' 'true'
ev "and a parsed zero is not a failure" 'parse("0") == none' 'false'

# A bare literal used to be skipped without being read, so every one of these
# parsed as valid. Nobody noticed, because a bogus keyword produced the same
# word the failure path did.
ev "truncated null"   'parse("nul")'       'none'
ev "truncated true"   'parse("tru")'       'none'
ev "truncated false"  'parse("fals")'      'none'
ev "misspelled null"  'parse("nulq")'      'none'
ev "misspelled true"  'parse("trux")'      'none'
ev "misspelled false" 'parse("falsq")'     'none'
ev "null with junk"   'parse("nullx")'     'none'
ev "keyword in an array"  'parse("[nul]")'          'none'
ev "keyword as a value"   'parse("{\"a\": tru}")'   'none'
ev "valid keywords still parse" 'stringify(parse("[true,false,null]"))' '[true,false,null]'

# RFC 8259's number grammar. Each of these used to parse: a bare minus as 0, a
# leading zero as if it weren't there, a point or an e with no digits after it
# as though the digits were 0.
ev "a bare minus"              'parse("-")'      'none'
ev "a minus with no digit"     'parse("-x")'     'none'
ev "a minus then a point"      'parse("-.5")'    'none'
ev "a leading zero"            'parse("01")'     'none'
ev "a negative leading zero"   'parse("-01")'    'none'
ev "two zeros"                 'parse("00")'     'none'
ev "a point with no digits"    'parse("1.")'     'none'
ev "a point, then an exponent" 'parse("1.e5")'   'none'
ev "an e with no digits"       'parse("1e")'     'none'
ev "an e and a sign, no digits" 'parse("1e+")'   'none'
ev "an E and a minus, no digits" 'parse("2E-")'  'none'
ev "one of them inside an array" 'parse("[1,01]")' 'none'
ev "zero is still a number"    'parse("0")'      '0'
ev "and minus zero"            'parse("-0")'     '0'
ev "a zero before a point"     'parse("0.25")'   '0.25'
ev "a zero before an exponent" 'parse("0e5")'    '0.0'
ev "a signed exponent"         'parse("-2.5E+2")' '-250.0'

# And its string grammar: a control character has to be escaped, and the only
# escapes are \" \\ \/ \b \f \n \r \t and \u with four hex digits. An unknown one
# used to stand for the character after the backslash, a raw TAB or 0x01 went
# through as is, and on x86-64 a \u with no hex digits was U+0000.
ev "an unknown escape"         'parse("\"\\x\"")'                    'none'
ev "an escaped digit"          'parse("\"\\1\"")'                    'none'
ev "a \\u with no hex digits"  'parse("\"a\\uZZZZb\"")'              'none'
ev "a \\u cut short"           'parse("\"\\u12\"")'                  'none'
ev "a raw tab in a string"     'parse("\"a" . char(9) . "b\"")'      'none'
ev "a raw newline in a string" 'parse("\"a" . char(10) . "b\"")'     'none'
ev "a raw 0x01 in a string"    'parse("\"a" . char(1) . "b\"")'      'none'
ev "a raw control character in a key" 'parse("{\"a" . char(31) . "\":1}")' 'none'
ev "a backslash at the very end" 'parse("\"ab\\")'                   'none'
ev "an escaped slash is a slash" 'parse("\"a\\/b\"")'                'a/b'
ev "an escaped tab is a tab"   'len(parse("\"a\\tb\""))'             '3'
ev "DEL needs no escape"       'len(parse("\"a" . char(127) . "\""))' '2'

echo "== json.stringify =="
ev "text is quoted"    'stringify("plain text")' '"plain text"'
ev "number"            'stringify(7)'            '7'
ev "float"             'stringify(1.5)'          '1.5'
ev "control chars"     'stringify("a\nb")'       '"a\nb"'
ev "quote and slash"   'stringify("a\"b\\c")'    '"a\"b\\c"'
ev "non-ASCII is raw"  'stringify("héllo")'      '"héllo"'

prog "array() marks a JSON array; text() is text" '[1,"two",3]
"\u0000\u0000"' <<'EOF'
import json
xs = array(3)
xs[0] = 1
xs[1] = "two"
xs[2] = 3
out(stringify(xs))
out(stringify(text(2)))
EOF

# `"z":null` on the way out, not `"z":0`. The round trip keeps every boolean
# and null in the document, where it used to rewrite them.
prog "round trip: parse . stringify is a fixed point" 'true
{"n":[1,2,3],"o":{"k":1},"t":"x","z":null}' <<'EOF'
import json
src = "{\"n\":[1,2,3],\"o\":{\"k\":1},\"t\":\"x\",\"z\":null}"
once = stringify(parse(src))
twice = stringify(parse(once))
out(once == twice)
out(twice)
EOF

prog "non-ASCII keys and values survive the round trip" 'true
{"café":"naïve"}
4
5' <<'EOF'
import json
m = {"café": "naïve"}
back = parse(stringify(m))
out(back == m)
out(stringify(m))
out(len("café"))
out(len(back["café"]))
EOF

# A byte-backed string is written as the UTF-8 text its bytes spell, the way
# out() prints it. It used to be promoted one code point per byte, so a field
# copied out of a UTF-8 file came out as "JosÃ©".
prog "a byte-backed string writes as its UTF-8 text" '"José"
{"raw":"José"}
true' <<'EOF'
import json
import txt
b = encode("José")
out(stringify(b))
out({raw: b})
out(parse(stringify({raw: b}))["raw"] == "José")
EOF

# A text element that isn't a character faults the way out() does for it. A
# negative one used to be written as \u00XX of its low byte (-5 as û), and a
# surrogate or one past 0x10FFFF was copied into the JSON raw.
faults "stringify: a negative element is not a character" 'not a character' <<'EOF'
import json
t = text(2)
t[0] = 'a'
t[1] = 0 - 5
out(stringify(t))
EOF
faults "stringify: a surrogate is not a character" 'not a character' <<'EOF'
import json
t = text(2)
t[0] = 'a'
t[1] = 56320
out(stringify(t))
EOF
faults "stringify: past 0x10FFFF is not a character" 'not a character' <<'EOF'
import json
t = text(2)
t[0] = 'a'
t[1] = 1114112
out(stringify(t))
EOF
faults "out of a map holding one is not a character" 'not a character' <<'EOF'
t = text(1)
t[0] = 0 - 1
m = {a: t}
out(m)
EOF
prog "stringify: the characters beside the gaps still write" '5 true' <<'EOF'
import json
t = text(3)
t[0] = 55295
t[1] = 57344
t[2] = 1114111
s = stringify(t)
out(len(s) . " " . (s == "\"" . t . "\""))
EOF

echo "== hostile input fails as data, never as a crash =="
# SPEC 12.3: nesting deeper than 1000 is none, so exactly 1000 parses. The
# counter used to count the scalar at the bottom as a level of its own, so a
# thousand arrays around a 1 were refused while a thousand around nothing
# parsed. This case used to test nest(900), which never reached the boundary.
prog "1000 levels deep parses, 1001 and 20000 are refused" 'false
false
false
true
true
true
true
true' <<'EOF'
import json
nest(n, open, inner, close)
    s = ""
    i = 0
    loop i < n
        s = s . open
        i = i + 1
    s = s . inner
    i = 0
    loop i < n
        s = s . close
        i = i + 1
    return s
out(parse(nest(1000, "[", "1", "]")) == none)
out(parse(nest(1000, "[", "", "]")) == none)
out(parse(nest(1000, "{\"k\":", "\"v\"", "}")) == none)
out(parse(nest(1001, "[", "1", "]")) == none)
out(parse(nest(1001, "[", "", "]")) == none)
out(parse(nest(1001, "{\"k\":", "1", "}")) == none)
out(stringify(parse(nest(1000, "[", "1", "]"))) == nest(1000, "[", "1", "]"))
out(parse(nest(20000, "[", "1", "]")) == none)
EOF

# stringify counts the same levels parse does, so whatever parse accepts can be
# written back out: a thousand maps around a value used to fault in the writer.
prog "stringify writes back the 1000 levels parse accepts" 'true' <<'EOF'
import json
m = 7
i = 0
loop i < 1000
    m = {k: m}
    i = i + 1
out(parse(stringify(m)) == m)
EOF

faults "1001 levels built by hand are too deep to write" "nests too deeply" <<'EOF'
import json
m = 7
i = 0
loop i < 1001
    m = {k: m}
    i = i + 1
out(stringify(m))
EOF

# A number past the double's range is none, not inf: JSON has no infinity, and
# stringify refuses one, so handing it back made stringify(parse(x)) fault on a
# document parse had accepted. The exponent's size doesn't matter, and neither
# does how many digits it's written with.
ev "past the double range is none"          'parse("1e400") == none'                 'true'
ev "and so is minus that"                   'parse("-1e400") == none'                'true'
ev "inside an array, the document is none"  'parse("[1, 1e400]") == none'            'true'
ev "a huge exponent is refused, not looped" 'parse("1e999999999") == none'           'true'
ev "and so is one with thirty digits"       'parse("1e999999999999999999999999999999") == none' 'true'
ev "a tiny value underflows to zero"        'parse("1e-400")'                        '0.0'
ev "and a tiny exponent is not looped"      'parse("1e-999999999")'                  '0.0'
ev "zero times a huge power is zero"        'parse("0e999999999")'                   '0.0'
ev "a large double still parses"            'parse("1.7e308") == none'               'false'

# The exponent is clamped only after the digits' own shift is added to it. It
# used to be clamped to 400 first, so a long mantissa with a big exponent came
# out as a wrong finite number: 0.<500 zeros>1e500 is 0.1, and it parsed as
# 1e-101. number() made the same clamp.
prog "a long mantissa with a big exponent scales by the whole exponent" 'true
true
true
true
true
true' <<'EOF'
import json
zeros(n)
    s = ""
    i = 0
    loop i < n
        s = s . "0"
        i = i + 1
    return s
out(parse("0." . zeros(500) . "1e500") == 0.1)
out(parse("[0." . zeros(450) . "1e450]")[0] == 0.1)
out(parse("0." . zeros(405) . "1e405") == 0.1)
v = parse("1" . zeros(500) . "e-450")
out(v > 9.99e49 && v < 1.001e50)
out(number("0." . zeros(500) . "1e500") == 0.1)
out(parse("1" . zeros(500) . "e-100") == none)
EOF

faults "a cycle is a clear fault, not a segfault" "nests too deeply" <<'EOF'
import json
m = {a: 1}
m["self"] = m
out(stringify(m))
EOF

echo "== the map runtime is gated on use =="
printf 'out("hi")\n' > "$p"
if ! "$WORD" build -asm "$p" 2>/dev/null | grep -q "rt_map_new"; then
  ok "a map-free program emits no map runtime"
else bad "a map-free program emits no map runtime" "found rt_map_new"; fi
printf 'out({a: 1})\n' > "$p"
if "$WORD" build -asm "$p" 2>/dev/null | grep -q "rt_map_new"; then
  ok "a {} literal brings the map runtime back"
else bad "a {} literal brings the map runtime back" "no rt_map_new emitted"; fi
printf 'import json\nout(parse("1"))\n' > "$p"
if "$WORD" build -asm "$p" 2>/dev/null | grep -q "rt_json_parse"; then
  ok "json.parse brings the json runtime back"
else bad "json.parse brings the json runtime back" "no rt_json_parse emitted"; fi

echo "== a JSON array stays one through slice and sort =="
# The mark that makes a region render as [...] instead of as text is one bit in
# the region header (SPEC 3.7), and copy() and sort() allocate a fresh result,
# so without care both hand back an unmarked region. A sliced array would then
# render as text, which for [10,20] is two control characters, and stringify
# would make it a JSON string of those characters. Both carry the mark over.
prog "slice of a JSON array is a JSON array" "[10,20]
[10,20]" <<'EOF'
import json
a = parse("[10,20,30]")
s = copy(a, 0, 2)
out(s)
out(stringify(s))
EOF
prog "sort of a JSON array is a JSON array" "[1,2,3]
[1,2,3]" <<'EOF'
import json
a = parse("[3,1,2]")
d = sort(a)
out(d)
out(stringify(d))
EOF
prog "a array(n) array survives both too" "[0,9]
[0,0,9]" <<'EOF'
b = array(3)
b[2] = 9
out(copy(b, 1, 3))
out(sort(b))
EOF
prog "an array nested in a parsed map keeps the mark when sliced" "[5,6]" <<'EOF'
import json
m = parse("{\"k\":[5,6,7]}")
out(stringify(copy(m["k"], 0, 2)))
EOF
prog "a slice of a slice is still an array" "[20]" <<'EOF'
import json
a = parse("[10,20,30]")
out(copy(copy(a, 0, 2), 1, 2))
EOF
prog "the round trip survives a slice" '{"v":[1,2]}' <<'EOF'
import json
a = parse("[1,2,3]")
m = {}
m["v"] = copy(a, 0, 2)
out(stringify(m))
EOF
# The mark mustn't appear where it was never set: an unmarked region prints as
# text, which is why the mark exists (SPEC 9.1).
prog "an unmarked region is still text after slice and sort" "BC CBA" <<'EOF'
n = text(3)
n[0] = 67
n[1] = 66
n[2] = 65
out(copy(sort(n), 1, 3) . " " . n)
EOF
# A byte-backed region (from fs.read) comes back word-backed from sort, and a
# slice of it stays byte-backed. Neither result is an array, and neither may
# become one.
prog "a byte-backed region does not become an array" "97 3" <<'EOF'
import fs
write("wjsonflag.txt", "abc")
d = read("wjsonflag.txt")
s = copy(d, 0, 2)
out(sort(d)[0] . " " . (len(s) + 1))
EOF
rm -f wjsonflag.txt

echo
echo "test_json: $pass passed, $fail failed"
[ "$fail" = 0 ]
