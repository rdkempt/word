#!/bin/sh
# test_txt.sh: the `txt` module (char, decode, encode, split and pad) and the
# kind() builtin. len(encode(s)) is the byte length a Content-Length needs,
# where len(s) counts code points.
#
# No `set -e`: several cases are meant to fault, and the check is the located
# message and exit 70.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}
cd "$root"
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
# On Windows word.exe is a native program, so a path written into a program's
# text has to be one Windows can open (/tmp/x would be \tmp\x on the current
# drive). hostpath is the identity everywhere else.
. "$here/hostpath.sh"
tmp=$(hostpath "$(mktemp -d)"); trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1 -- $2"; }
p="$tmp/p.w"; exe="$tmp/p"

# run <name> <expected-stdout>; program on stdin.
run() { cat > "$p"; nm="$1"; want="$2"
  if ! "$WORD" build "$p" -o "$exe" >"$tmp/err" 2>&1; then bad "$nm" "build failed: $(cat "$tmp/err")"; return; fi
  got=$("$exe" 2>&1)
  if [ "$got" = "$want" ]; then ok "$nm"; else bad "$nm" "got [$got] want [$want]"; fi; }

# faults <name> <substring of the message>; must exit 70 with a located message.
faults() { cat > "$p"; nm="$1"; want="$2"
  if ! "$WORD" build "$p" -o "$exe" >"$tmp/err" 2>&1; then bad "$nm" "build failed: $(cat "$tmp/err")"; return; fi
  got=$("$exe" 2>&1); rc=$?
  case "$got" in
    *"$want"*) if [ "$rc" = 70 ]; then ok "$nm"; else bad "$nm" "message right, exit $rc not 70"; fi ;;
    *) bad "$nm" "got [$got] want a message containing [$want]" ;;
  esac; }

echo "== char: a computed code point finally has a spelling =="
run "char builds one-element text" "H" <<'EOF'
import txt
out(char(72))
EOF
run "char joins, and the join does not renumber it" "He" <<'EOF'
import txt
out(char(72) . char(101))
EOF
run "char carries a multi-byte code point" "—" <<'EOF'
import txt
out(char(8212))
EOF
run "char round-trips s[i]" "1" <<'EOF'
import txt
s = "q"
if char(s[0]) == s
    out(1)
else
    out(0)
EOF
run "len of a char is 1, not the digits of the number" "1" <<'EOF'
import txt
out(len(char(8212)))
EOF
faults "char of text faults, and says what it needs" "expected a whole number" <<'EOF'
import txt
out(char("a"))
EOF
faults "char of a float faults the same way" "expected a whole number" <<'EOF'
import txt
out(char(1.5))
EOF

echo "== decode: a program can finally say 'this file is text' =="
printf 'caf\303\251 \342\200\224 dash\n' > "$tmp/u.txt"
run "decode turns file bytes into code points" "15 12" <<EOF
import txt
import fs
raw = read("$tmp/u.txt")
out(len(raw) . " " . len(decode(raw)))
EOF
run "joining a decoded line does not mojibake" "line: café — dash" <<EOF
import txt
import fs
t = decode(read("$tmp/u.txt"))
out("line: " . copy(t, 0, 12))
EOF
run "decode of something already text is itself" "already text" <<'EOF'
import txt
out(decode("already text"))
EOF
faults "decode of a number faults" "region expected" <<'EOF'
import txt
out(decode(5))
EOF

echo "== decode: only well-formed UTF-8 is a character =="
# Unicode section 3.9, table 3-7. An overlong form, a surrogate and anything
# past U+10FFFF aren't characters, and each used to decode as one: C1 BB came
# back as '{', and F4 90 80 80 as 1114112. Now the lead byte of anything
# ill-formed passes through as itself (SPEC 12.4) and the bytes after it are
# decoded on their own.
cat > "$tmp/u8.w" <<'EOF'
show(b)
    s = decode(b)
    r = ""
    i = 0
    loop i < len(s)
        if i > 0
            r = r . ","
        r = r . s[i]
        i = i + 1
    return r

out(show(bytes("C280")) . " " . show(bytes("DFBF")) . " " . show(bytes("E0A080")) . " " . show(bytes("ED9FBF")))
out(show(bytes("EE8080")) . " " . show(bytes("EFBFBF")) . " " . show(bytes("F0908080")) . " " . show(bytes("F48FBFBF")))
out(show(bytes("C0AF")) . " " . show(bytes("C1BB")) . " " . show(bytes("E08080")) . " " . show(bytes("E09FBF")))
out(show(bytes("EDA080")) . " " . show(bytes("EDBFBF")) . " " . show(bytes("F08080AF")) . " " . show(bytes("F08FBFBF")))
out(show(bytes("F4908080")) . " " . show(bytes("F5808080")) . " " . show(bytes("F8888080")) . " " . show(bytes("E28241")))
EOF
want='128 2047 2048 55295
57344 65535 65536 1114111
192,175 193,187 224,128,128 224,159,191
237,160,128 237,191,191 240,128,128,175 240,143,191,191
244,144,128,128 245,128,128,128 248,136,128,128 226,130,65'
cat "$tmp/u8.w" | run "every boundary: the well-formed decode, the ill-formed pass through" "$want"

# in(), args() and env() use the same decoder, so they follow the same rule.
printf 'out(len(env("W_OVERLONG")) . " " . env("W_OVERLONG")[0])\nx = in()\nout(len(x) . " " . x[0])\n' > "$p"
if "$WORD" build "$p" -o "$exe" >"$tmp/err" 2>&1; then
  got=$(printf '\355\240\200\n' | W_OVERLONG=$(printf '\301\273') "$exe" 2>&1)
  if [ "$got" = "2 193
3 237" ]; then ok "env() and in() pass an overlong and a surrogate through"
  else bad "env() and in() pass an overlong and a surrogate through" "got [$got]"; fi
else bad "env() and in() pass an overlong and a surrogate through" "build failed: $(cat "$tmp/err")"; fi

# And the compiler reads a literal by the same rule: an overlong in the source
# is two elements, not the character it spells, and a sequence cut short keeps
# every byte it has.
printf 'a = "\301\273"\nb = "\342\202A"\nc = "caf\303\251"\nout(len(a) . " " . a[0] . " " . len(b) . " " . b[1] . " " . len(c))\n' > "$p"
if "$WORD" build "$p" -o "$exe" >"$tmp/err" 2>&1; then
  got=$("$exe" 2>&1)
  if [ "$got" = "2 193 3 130 4" ]; then ok "a string literal is decoded by the same rule"
  else bad "a string literal is decoded by the same rule" "got [$got]"; fi
else bad "a string literal is decoded by the same rule" "build failed: $(cat "$tmp/err")"; fi

echo "== split =="
run "split on a single-character separator" '["a","b","c"]' <<'EOF'
import txt
out(split("a,b,c", ","))
EOF
run "n separators give n+1 pieces, empties included" '["a","","b"]' <<'EOF'
import txt
out(split("a,,b", ","))
EOF
run "a separator that never occurs gives one piece" '["abc"]' <<'EOF'
import txt
out(split("abc", ","))
EOF
run "leading and trailing separators give empty ends" '["","a",""]' <<'EOF'
import txt
out(split(",a,", ","))
EOF
run "a multi-character separator" '["a","b"]' <<'EOF'
import txt
out(split("a<>b", "<>"))
EOF
run "pieces are indexable and counted" "3 b" <<'EOF'
import txt
p = split("a,b,c", ",")
out(len(p) . " " . p[1])
EOF
run "splitting the empty string gives one empty piece" "1 0" <<'EOF'
import txt
p = split("", ",")
out(len(p) . " " . len(p[0]))
EOF
run "split on a multi-byte separator" '["a","b"]' <<'EOF'
import txt
out(split("a—b", "—"))
EOF
run "split of file bytes decodes through promotion" "2" <<EOF
import txt
import fs
out(len(split(read("$tmp/u.txt"), "\n")))
EOF
faults "an empty separator has no answer" "at least one character" <<'EOF'
import txt
out(split("abc", ""))
EOF

echo "== pad =="
run "a positive width right-aligns" "   7|" <<'EOF'
import txt
out(pad("7", 4, ' ') . "|")
EOF
run "a negative width left-aligns" "7...|" <<'EOF'
import txt
out(pad("7", 0 - 4, '.') . "|")
EOF
run "any fill character, not just a space" "00ff" <<'EOF'
import txt
out(pad("ff", 4, '0'))
EOF
run "pad never truncates" "toolong" <<'EOF'
import txt
out(pad("toolong", 3, ' '))
EOF
run "padding to its own width is a no-op" "abc" <<'EOF'
import txt
out(pad("abc", 3, ' '))
EOF
run "the result is text, and its length is the width" "5" <<'EOF'
import txt
out(len(pad("ab", 5, ' ')))
EOF
faults "pad of a number faults" "region expected" <<'EOF'
import txt
out(pad(5, 3, ' '))
EOF

echo "== kind: the question nothing could ask =="
run "an integer is a number" "number" <<'EOF'
out(kind(1))
EOF
run "a float is a number too" "number" <<'EOF'
out(kind(1.5))
EOF
# A byte-backed region is its own kind, "bytes". It used to answer "text", so
# fs.read looked like decoded text while its len() counts bytes and its
# elements are bytes.
run "a byte buffer is bytes, not text" "bytes" <<'EOF'
out(kind(bytes(4)))
EOF
run "a hex blob is bytes" "bytes" <<'EOF'
out(kind(bytes("4142")))
EOF
run "a file read is bytes" "bytes" <<'EOF'
import fs
write("ktxtflag.txt", "abc")
out(kind(read("ktxtflag.txt")))
EOF
rm -f ktxtflag.txt
run "decoding it makes it text" "text" <<'EOF'
import fs
write("ktxtflag2.txt", "abc")
out(kind(decode(read("ktxtflag2.txt"))))
EOF
rm -f ktxtflag2.txt
run "a copy of a byte buffer is still bytes" "bytes" <<'EOF'
out(kind(copy(bytes(4))))
EOF
run "sort promotes bytes to text" "text" <<'EOF'
out(kind(sort(bytes(4))))
EOF

run "text is text" "text" <<'EOF'
out(kind("abc"))
EOF
run "a map is a map, which a number test alone cannot tell you" "map" <<'EOF'
out(kind({a: 1}))
EOF
run "kind() calls a JSON array an array, which is how it is told from a string" "array" <<'EOF'
out(kind(array(2)))
EOF
run "an unmarked array is text, because in word they are the same thing" "text" <<'EOF'
out(kind(text(3)))
EOF
run "the number test answers for an integer and a float, and nothing else" "true true false false" <<'EOF'
a = kind(1) == "number"
b = kind(2.5) == "number"
c = kind("s") == "number"
d = kind({}) == "number"
out(a . " " . b . " " . c . " " . d)
EOF
run "a parsed document classifies leaf, object and array" "number text map array" <<'EOF'
import json
d = parse("{\"n\":1,\"s\":\"x\",\"o\":{},\"a\":[1]}")
out(kind(d["n"]) . " " . kind(d["s"]) . " " . kind(d["o"]) . " " . kind(d["a"]))
EOF
run "split hands back something kind() calls an array" "array" <<'EOF'
import txt
out(kind(split("a,b", ",")))
EOF
faults "the answer is a literal, so writing into it faults" "write to a literal" <<'EOF'
k = kind(1)
k[0] = 65
EOF

echo "== kind(): every constructor, and the fold agreeing with the call =="
# `kind(x) == "name"` is the only kind test (is_number() is gone), and the
# compiler folds it into a tag test instead of building the name and comparing
# it. So there are two implementations of the same question, and they have to
# agree. Each value goes through a function parameter, so the compiler can't
# work out its kind at the comparison.
#
# `shape` asks all five names folded, and `named` asks all five through a
# variable, which takes the out-of-line rt_kind path. A value that matches two
# names, or none, or gets different answers from the two, is a bug.
run "the fold and the call agree on every kind" "N N T T B B A M B B A B T A" <<'EOF'
import fs
shape(v)
    r = ""
    if kind(v) == "number"
        r = r . "N"
    if kind(v) == "text"
        r = r . "T"
    if kind(v) == "bytes"
        r = r . "B"
    if kind(v) == "array"
        r = r . "A"
    if kind(v) == "map"
        r = r . "M"
    return r
named(v)
    k = kind(v)
    n = "number"
    t = "text"
    b = "bytes"
    a = "array"
    m = "map"
    r = ""
    if k == n
        r = r . "N"
    if k == t
        r = r . "T"
    if k == b
        r = r . "B"
    if k == a
        r = r . "A"
    if k == m
        r = r . "M"
    return r
one(v)
    f = shape(v)
    if f != named(v)
        return "!"
    return f
line = ""
line = line . one(7) . " " . one(7.5) . " " . one("hi") . " " . one(text(3))
line = line . " " . one(bytes(3)) . " " . one(bytes("41ff")) . " " . one(array(2))
line = line . " " . one({}) . " " . one(read("README.md"))
line = line . " " . one(copy(bytes(4), 0, 2)) . " " . one(copy(array(4), 0, 2))
line = line . " " . one(bytes(2) . bytes(2)) . " " . one(bytes(2) . "x")
line = line . " " . one(split("a,b", ","))
out(line)
EOF
# != is the same test with the answer flipped, and it has its own fold.
run "!= answers the complement of ==, on every kind" "true true true true true" <<'EOF'
q(v, want)
    a = kind(v) == want
    b = kind(v) != want
    // Two booleans are complements when they differ. This used to add them
    // and check for 1, which stopped working when comparisons started
    // answering true or false instead of 1 or 0: arithmetic on a singleton
    // is a compile error.
    if a != b
        return true
    return false
out(q(1, "number") . " " . q("s", "text") . " " . q(bytes(1), "bytes") . " " . q(array(1), "array") . " " . q({}, "map"))
EOF
# The fold only applies to a literal name. Against a variable it stays an
# ordinary comparison with what rt_kind returned, so a program that computes
# the name it's looking for still works.
run "a computed name still compares" "true false" <<'EOF'
want = "num" . "ber"
out((kind(7) == want) . " " . (kind("s") == want))
EOF
# A misspelled name is a test that could never be true, and the fold would
# turn it into a constant false. "list" is the likely one: it's what an array
# used to be called.
printf 'x = 1\nif kind(x) == "list"\n    out(1)\nout(2)\n' > "$tmp/kt.w"
if "$WORD" build "$tmp/kt.w" -o "$exe" >"$tmp/err" 2>&1; then
  bad "an unknown kind name is refused" "it built instead"
else
  case "$(cat "$tmp/err")" in
    *"kind() never answers 'list'"*) ok "an unknown kind name is a located compile error" ;;
    *) bad "an unknown kind name is refused" "wrong message: $(cat "$tmp/err")" ;;
  esac
fi
# ...and the same check accepts the five real names.
run "each of the five names is accepted" "true true true true true" <<'EOF'
out((kind(1) == "number") . " " . (kind("s") == "text") . " " . (kind(bytes(1)) == "bytes") . " " . (kind(array(1)) == "array") . " " . (kind({}) == "map"))
EOF
# is_number() is gone, and calling it is an ordinary undefined-function error.
printf 'out(is_number(1))\n' > "$tmp/isn.w"
if "$WORD" build "$tmp/isn.w" -o "$exe" >"$tmp/err" 2>&1; then
  bad "is_number is retired" "it still builds"
else
  case "$(cat "$tmp/err")" in
    *"undefined function 'is_number'"*) ok "is_number() is retired, with an ordinary undefined-function error" ;;
    *) bad "is_number is retired" "wrong message: $(cat "$tmp/err")" ;;
  esac
fi

echo "== gating: a program that uses none of it carries none of it =="
printf 'out("hi")\n' > "$tmp/hw.w"
"$WORD" build -asm "$tmp/hw.w" > "$tmp/hw.s" 2>/dev/null
for sym in rt_txchar rt_txdecode rt_txsplit rt_txpad rt_kind kindlit_num; do
  if grep -q "$sym" "$tmp/hw.s"; then bad "hello world carries $sym" "it should be gated out"; fi
done
grep -q rt_txchar "$tmp/hw.s" || grep -q rt_kind "$tmp/hw.s" || ok "hello world carries none of the txt/kind runtime"
printf 'import txt\nout(char(65))\n' > "$tmp/c.w"
"$WORD" build -asm "$tmp/c.w" 2>/dev/null | grep -q rt_txchar \
  && ok "a program that calls char() does carry it" \
  || bad "char() program missing rt_txchar" "the gate is inverted"
printf 'out(kind(1))\n' > "$tmp/k.w"
"$WORD" build -asm "$tmp/k.w" 2>/dev/null | grep -q kindlit_num \
  && ok "a program that calls kind() carries its literals" \
  || bad "kind() program missing kindlit_num" "the gate is inverted"

echo "== encode: the byte length a Content-Length actually wants =="
run "ASCII is one byte per code point" "3 3" <<'EOF'
import txt
s = "abc"
out(len(s) . " " . len(encode(s)))
EOF
run "len counts code points, encode counts bytes" "7 10" <<'EOF'
import txt
s = "h" . char(233) . "llo " . char(9731)
out(len(s) . " " . len(encode(s)))
EOF
run "every UTF-8 width, one at a time" "1 2 3 4" <<'EOF'
import txt
out(len(encode(char(65))) . " " . len(encode(char(233))) . " " . len(encode(char(9731))) . " " . len(encode(char(128169))))
EOF
run "the boundary code points on each side" "1 2 2 3 3 4" <<'EOF'
import txt
out(len(encode(char(127))) . " " . len(encode(char(128))) . " " . len(encode(char(2047))) . " " . len(encode(char(2048))) . " " . len(encode(char(65535))) . " " . len(encode(char(65536))))
EOF
run "empty text encodes to no bytes" "0 bytes" <<'EOF'
import txt
out(len(encode("")) . " " . kind(encode("")))
EOF
run "the result is byte-backed" "bytes" <<'EOF'
import txt
out(kind(encode("hello")))
EOF
run "decode undoes it" "true" <<'EOF'
import txt
s = "h" . char(233) . "llo " . char(9731)
out(decode(encode(s)) == s)
EOF
run "and it undoes decode, which is the round trip that matters" "true" <<'EOF'
import txt
b = bytes("68c3a96c6c6f20e29883")
out(encode(decode(b)) == b)
EOF
run "the bytes themselves are right" "104 195 169" <<'EOF'
import txt
b = encode("h" . char(233))
out(b[0] . " " . b[1] . " " . b[2])
EOF
# A byte-backed argument isn't handed back unchanged, the way decode hands back
# text: its elements (0 to 255) are read as code points, so each one above 0x7F
# becomes two bytes.
run "a byte-backed argument is re-encoded, not passed through" "2 4" <<'EOF'
import txt
b = bytes("c3a9")
out(len(b) . " " . len(encode(b)))
EOF
# A whole number outside 0..0x10FFFF gets encode's own fault. It used to be
# "text: expected a whole number", which is wrong for 1114112 and -5: both are
# whole numbers, they just aren't code points.
faults "a code point above the last plane faults" "encode: not a code point (0 to 0x10FFFF)" <<'EOF'
import txt
out(len(encode(char(1114112))))
EOF
faults "a negative one faults the same way" "encode: not a code point" <<'EOF'
import txt
out(len(encode(char(0 - 5))))
EOF
# A surrogate (U+D800..U+DFFF) has no UTF-8 either. It used to come out as the
# three bytes ED A0 80, which no decoder takes back. It faults the same way as
# one in a path or in write()'s data, and the two code points either side of
# the range still encode.
faults "a surrogate is not a character" "not a character" <<'EOF'
import txt
out(len(encode("a" . char(55296))))
EOF
faults "the last surrogate is not a character" "not a character" <<'EOF'
import txt
out(len(encode(char(57343))))
EOF
run "the code points either side of the surrogates encode" "3 3" <<'EOF'
import txt
out(len(encode(char(55295))) . " " . len(encode(char(57344))))
EOF
# An element that isn't a whole number at all still faults "whole number".
faults "a nested region is not a character" "whole number" <<'EOF'
import txt
a = array(1)
a[0] = "x"
out(len(encode(a)))
EOF
# A singleton in a text region isn't one either. true is the word 22, and
# shifted down like a number it became the byte 11.
faults "true in a text region is not a code point" "whole number" <<'EOF'
import txt
t = text(2)
t[0] = true
t[1] = 65
out(len(encode(t)))
EOF
faults "nor is none" "whole number" <<'EOF'
import txt
t = text(1)
t[0] = none
out(len(encode(t)))
EOF
faults "nor is a float" "whole number" <<'EOF'
import txt
t = text(1)
t[0] = 65.0
out(len(encode(t)))
EOF
faults "a number where a region belongs faults" "region expected" <<'EOF'
import txt
out(len(encode(7)))
EOF

echo "== the module needs no import, and is still gated by USE =="
# char() without `import txt` builds: the compiler knows char is in txt.
printf 'out(char(65))\n' > "$tmp/n.w"
if "$WORD" build "$tmp/n.w" -o "$exe" >"$tmp/err" 2>&1 && [ "$("$exe")" = "A" ]; then
  ok "char() works with no import at all"
else
  bad "char() without an import" "[$(cat "$tmp/err")]"
fi
# ...and what brings the runtime in is the call, not the import line: a
# program that never calls into txt carries none of it.
printf 'out(1)\n' > "$tmp/g.w"
"$WORD" build -asm "$tmp/g.w" 2>/dev/null | grep -q rt_txchar \
  && bad "txt runtime leaked into a program that never calls it" "gate is by import, not by use" \
  || ok "a program that calls nothing from txt still carries none of it"

echo ""
echo "test_txt: $pass passed, $fail failed"
[ "$fail" = 0 ]
