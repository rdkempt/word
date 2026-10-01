#!/bin/sh
# test_kinds.sh: the kind matrix. Each builtin, module function and operator
# that checks a kind is handed a value of every kind (number, float, text,
# bytes, array, map, true, false, null and none), and each time:
#
#   * a kind it accepts runs to exit 0;
#   * a kind it doesn't accept is a located run-time fault, exit 70 (SPEC 10.2);
#   * it never dies on a signal, and never hands back a value of the wrong kind
#     as if it were right (number(true) used to answer `true`);
#   * x86-64 and arm64 agree on the exit code and on every byte printed (arm64
#     used to cut `this needs a map` short by a byte).
#
# A refused region check is held to its exact message too, at each site that
# makes one. SPEC 10.2 says the message gives the kind that arrived, and a
# singleton used to be reported as `got a number` everywhere.
#
# The comparisons are also asked with both operands unknown, for every pair of
# kinds, and held to the exact answer or fault. A mixed pair is where a float
# used to hide the other side's kind (`none == 15.0` was true), and where the
# two targets gave different faults for the same pair.
#
# Each value is stored in an array element (or a text's) and read back, so the
# analyzer can't see its kind and the run-time check is the one tested. That's
# where a `mov` off a tagged integer, or a promote of a boxed float, would
# crash. A review by hand once missed a dozen of these (env(123) among them),
# so this suite tries every cell.
#
# No `set -e`, since most cells are meant to exit 70.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; cd "$root"
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 10"

# The arm64 half runs under qemu. It skips itself when qemu is missing (on a
# contributor's machine), and CI checks that qemu is there, as it does for the
# other cross-backend suites. Without it each cell's arm64 answer is taken to be
# the x86-64 one, so the agreement check can't fail, and the summary says the
# arm64 half didn't run.
QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
a64note=""
[ -n "$QEMU" ] || { a64note=" (x86-64 only: no qemu-aarch64, so the arm64 half didn't run)"; echo "  note: no qemu-aarch64, so the arm64 half is skipped"; }

pass=0; fail=0
bad() { fail=$((fail + 1)); echo "  FAIL $1 -- $2"; }

# every kind, and the literal that puts one into an array element
KINDS='int=5 flt=2.5 txt="hi" byt=bytes("6869") arr=array(2) map={a:1} T=true F=false nul=null non=none'

# run one (kind, program) on both targets -> sets RX/RA (exit codes) and OX/OA
# (everything each printed). X is read back out of a <store>(1): an array unless
# told otherwise, or a text, which doesn't bring in the map runtime the way
# array() does, so the program gets the kind checks a map-free program is built
# with.
# When $Y is set (KK), a second unknown, Y, is read out of another store of the
# same sort, and the body starts three lines further down.
Y=
run_cell() { # run_cell <import> <body> <init> [store]
  { [ -n "$1" ] && printf 'import %s\n' "$1"
    printf 'a = %s(1)\na[0] = %s\nX = a[0]\n' "${4:-array}" "$3"
    [ -n "$Y" ] && printf 'b = %s(1)\nb[0] = %s\nY = b[0]\n' "${4:-array}" "$Y"
    printf '%s\n' "$2"; } > "$tmp/p.w"
  rm -f "$tmp/x" "$tmp/a"
  if ! "$WORD" build "$tmp/p.w" -o "$tmp/x" >"$tmp/be" 2>&1; then RX=CE; RA=CE; OX=$(head -1 "$tmp/be"); return; fi
  OX=$($TO "$tmp/x" 2>&1 </dev/null); RX=$?
  if [ -z "$QEMU" ]; then RA=$RX; OA=$OX
  elif ! "$WORD" build -arm64 "$tmp/p.w" -o "$tmp/a" >"$tmp/be" 2>&1; then RA=CE; OA=$(head -1 "$tmp/be")
  else OA=$($TO $QEMU "$tmp/a" 2>&1 </dev/null); RA=$?; fi
}

# check one cell against the expected outcome (0 or 70). It must never die on a
# signal, the two targets must agree on the exit code and on every byte, a fault
# must be located, and the output must be exactly <want> when there is one.
check() { # check <label> <kind> <init> <expect 0|70> <import> <body> [store] [want]
  run_cell "$5" "$6" "$3" "$7"
  c="$1 [$2${7:+ from $7}]"
  [ "$RX" = CE ] && { bad "$c" "compile error: $OX"; return; }
  [ "$RA" = CE ] && { bad "$c" "arm64 compile error: $OA"; return; }
  if [ "$RX" -ge 128 ] 2>/dev/null; then bad "$c" "x86-64 SIGNAL (exit $RX): must fault, not crash"; return; fi
  if [ "$RA" -ge 128 ] 2>/dev/null; then bad "$c" "arm64 SIGNAL (exit $RA): must fault, not crash"; return; fi
  [ "$RX" = "$RA" ] || { bad "$c" "x86-64 exit $RX, arm64 exit $RA: backends disagree"; return; }
  [ "$OX" = "$OA" ] || { bad "$c" "x86-64 printed [$OX], arm64 [$OA]: backends disagree"; return; }
  [ "$RX" = "$4" ] || { bad "$c" "exit $RX, expected $4 ($OX)"; return; }
  if [ "$4" = 70 ]; then case "$OX" in *p.w:*) : ;; *) bad "$c" "fault not located: $OX"; return;; esac; fi
  [ -z "$8" ] || [ "$OX" = "$8" ] || { bad "$c" "printed [$OX], expected [$8]"; return; }
  pass=$((pass + 1))
}

# K <label> <valid-kinds|ALL> <import> <body> : valid kinds exit 0, all others 70
K() { for kv in $KINDS; do k=${kv%%=*}; init=${kv#*=}
    exp=70; [ "$2" = ALL ] && exp=0
    for v in $2; do [ "$v" = "$k" ] && exp=0; done
    check "$1" "$k" "$init" "$exp" "$3" "$4"; done; }

# Kf <label> <fault-kinds> <import> <body> : only the listed kinds are checked,
# and each must fault 70. It's for the fs verbs, where what an accepted kind does
# depends on the filesystem and only the refusal is the same everywhere.
Kf() { for kv in $KINDS; do k=${kv%%=*}; init=${kv#*=}
    for v in $2; do [ "$v" = "$k" ] && check "$1" "$k" "$init" 70 "$3" "$4"; done; done; }

# What a refused region check says (SPEC 10.2), by the kind that arrived. A
# number or a map is named from the tag; a singleton from the word itself, since
# all four carry the same tag.
regmsg() {
  case $1 in
    int|flt) echo 'region expected, got a number';;
    map) echo 'region expected, got a map';;
    T|F) echo 'region expected, got a boolean';;
    nul) echo 'region expected, got null';;
    non) echo 'region expected, got none';;
  esac
}

# R <label> <fault-kinds> <import> <body> : each listed kind must fault on the
# body's first line and print exactly `p.w:<line>: <regmsg>` (a fault gives its
# source by file name). Each cell runs with X read out of an array, where the
# map runtime is in and len, [] and copy take the paths that dispatch on a map,
# and again out of a text, where it isn't and they take the plain region check.
# A map brings the map runtime in either way, so the map cell runs once.
R() { line=4; [ -n "$3" ] && line=5
  for store in array text; do for kv in $KINDS; do k=${kv%%=*}; init=${kv#*=}
    [ "$store/$k" = text/map ] && continue
    for v in $2; do [ "$v" = "$k" ] &&
      check "$1" "$k" "$init" 70 "$3" "$4" "$store" "p.w:$line: $(regmsg "$k")"; done
  done; done; }

# What a refused condition says (SPEC 3.2), whatever arrived.
condmsg() { echo "a condition must be true or false; compare the value, as in 'x != 0' or 'x != none'"; }

# Km <label> <valid-kinds> <import> <body> <msg> [line] : K, with each refusal
# held to exactly `p.w:<line>: $(<msg> <kind>)`, as R holds it. The fault is on
# the body's first line unless [line] says where.
Km() { line=4; [ -n "$3" ] && line=5; [ -n "$6" ] && line=$6
  for kv in $KINDS; do k=${kv%%=*}; init=${kv#*=}
    exp=70; want="p.w:$line: $($5 "$k")"
    for v in $2; do [ "$v" = "$k" ] && { exp=0; want=; }; done
    check "$1" "$k" "$init" "$exp" "$3" "$4" "" "$want"; done; }

# Kv <label> <want> <import> <body> : every kind runs to exit 0 and prints
# exactly <want>. It's for an operator that accepts anything, where a bug shows
# up as a wrong answer instead of a fault: `none == 15.0` was true.
Kv() { for kv in $KINDS; do k=${kv%%=*}; init=${kv#*=}
    check "$1" "$k" "$init" 0 "$3" "$4" "" "$2"; done; }

is_num() { case $1 in int|flt) return 0;; esac; return 1; }
is_reg() { case $1 in txt|byt|arr) return 0;; esac; return 1; }
is_sig() { case $1 in T|F|nul|non) return 0;; esac; return 1; }

# What ordering a value of this kind against a number says (SPEC 3.3, 3.8).
ordmsg() {
  case $1 in
    T|F|nul|non) echo "'<' and '>' have no meaning for true, false, null or none";;
    map) echo 'this needs a number or a region, not a map';;
    *) echo 'cannot order-compare a number and text';;
  esac
}

# KK <label> <rule> <body> [store] : X and Y are both unknown, and the body runs
# once for every ordered pair of kinds. The mixed pairs are where the two
# targets used to give different faults. <rule> is called with the two kinds and
# sets EXP (0 or 70) and WANT (exactly what's printed). A text store leaves the
# map runtime out, and so leaves the map pairs out too.
KK() { line=7
  for kvx in $KINDS; do kx=${kvx%%=*}; ix=${kvx#*=}
    for kvy in $KINDS; do ky=${kvy%%=*}
      [ "$4" = text ] && { [ "$kx" = map ] || [ "$ky" = map ]; } && continue
      Y=${kvy#*=}; "$2" "$kx" "$ky"
      check "$1" "$kx,$ky" "$ix" "$EXP" '' "$3" "$4" "$WANT"
    done; done; Y=; }

# Two numbers order by value and two regions by content (SPEC 3.3). Any other
# pair faults, with one message whichever side the offending value is on and
# whatever it meets. A singleton comes first (it orders against nothing, and
# it's what the compiler reports when it can see one), then a map, and what's
# left is a region against a number. Returns 1 for a fault, having set EXP and
# WANT.
order_rule() {
  if { is_num "$1" && is_num "$2"; } || { is_reg "$1" && is_reg "$2"; }; then EXP=0; return 0; fi
  EXP=70
  if is_sig "$1" || is_sig "$2"; then WANT="p.w:$line: $(ordmsg T)"
  elif [ "$1" = map ] || [ "$2" = map ]; then WANT="p.w:$line: $(ordmsg map)"
  else WANT="p.w:$line: $(ordmsg txt)"; fi
  return 1
}
# Of the pairs that have an order, X < Y holds for these alone: 2.5 < 5, and
# array(2) (two zeros) before "hi" in either backing. X >= Y is the rest.
less() { case "$1,$2" in flt,int|arr,txt|arr,byt) return 0;; esac; return 1; }
lt_rule() { order_rule "$1" "$2" || return 0; if less "$1" "$2"; then WANT=true; else WANT=false; fi; }
ge_rule() { order_rule "$1" "$2" || return 0; if less "$1" "$2"; then WANT=false; else WANT=true; fi; }
# Equality never faults and crosses no kind (SPEC 3.3, 3.8). Each value equals a
# fresh one of its own kind, by content all the way down, and "hi" as text equals
# "hi" as bytes, which are the same two code points. Nothing else is equal.
eq_rule() { EXP=0; WANT=false
  [ "$1" = "$2" ] && WANT=true
  case "$1,$2" in txt,byt|byt,txt) WANT=true;; esac; }

echo "== region + number builtins =="
K 'len(X)'        'txt byt arr map'   '' 'out(len(X))'
K 'sort(X)'       'txt byt arr'       '' 'out(len(sort(X)))'
K 'copy(X)'       'txt byt arr map'   '' 'out(len(copy(X)))'
K 'copy(X,0)'     'txt byt arr'       '' 'out(len(copy(X, 0)))'
K 'copy(X,0,0)'   'txt byt arr'       '' 'out(len(copy(X, 0, 0)))'
# copy's start and end are indexes, so one that isn't a whole number faults the
# way p[i] does for it. They were all `index out of bounds`, even 1.0 inside
# the region. The last row is x86-64's fixed-width form, which never adds the
# end up; arm64 does, and the two still have to say the same thing.
idxmsg() {
  case $1 in
    flt) echo 'array index must be a whole number';;
    map) echo 'number expected, got a map';;
    T|F|nul|non) echo 'number expected, got true, false, null or none';;
    *) echo 'number expected, got a region';;
  esac
}
Km 'copy(s,X)'     'int'  '' 'out(len(copy("abcdefgh", X)))'        idxmsg
Km 'copy(s,X,8)'   'int'  '' 'out(len(copy("abcdefgh", X, 8)))'     idxmsg
Km 'copy(s,0,X)'   'int'  '' 'out(len(copy("abcdefgh", 0, X)))'     idxmsg
Km 'copy(s,0,0+X)' 'int'  '' 'out(len(copy("abcdefgh", 0, 0 + X)))' idxmsg
K 'find(X,s)'     'txt byt arr'       '' 'out(find(X, "a") == none)'
K 'find(s,X)'     'txt byt arr'       '' 's = array(1)
s[0] = 1
out(find(s, X) == none)'
K 'keys(X)'       'map'               '' 'out(len(keys(X)))'
K 'has(X,k)'      'map'               '' 'out(has(X, "k"))'
K 'has(m,X)'      'txt byt arr'       '' 'm = {z: 1}
out(has(m, X))'
K 'm[X]'          'txt byt arr'       '' 'out({z: 1}[X])'
K 'array(X)'      'int'               '' 'out(len(array(X)))'
K 'text(X)'       'int'               '' 'out(len(text(X)))'
K 'bytes(X)'      'int'               '' 'out(len(bytes(X)))'
K 'round(X)'      'int flt'           '' 'out(round(X))'
# round() answers an integer, so a float past -2^62 .. 2^62 - 1 faults. Both
# targets checked the 64-bit word instead, and let 2^62 .. 2^63 through with the
# sign wrapped. The nearest whole number is exact on both too: x86-64 added 0.5
# and truncated, which rounded these two up where arm64 did not.
rmsg="round() has no whole number for inf, nan or a value past the integer range"
for v in 4611686018427387904.0 6000000000000000000.0 '0.0 - 6000000000000000000.0' '0.0 - 4611686018427388928.0'; do
  check "round($v)" flt "$v" 70 '' 'out(round(X))' '' "p.w:4: $rmsg"; done
check 'round(-2^62)'     flt '0.0 - 4611686018427387904.0' 0 '' 'out(round(X))' '' '-4611686018427387904'
check 'round(2^62 - 512)' flt '4611686018427387392.0'      0 '' 'out(round(X))' '' '4611686018427387392'
check 'round(0.49999999999999994)' flt '0.49999999999999994' 0 '' 'out(round(X))' '' '0'
check 'round(2^52 + 1)'  flt '4503599627370497.0'          0 '' 'out(round(X))' '' '4503599627370497'
K 'number(X)'     'int flt txt byt arr' '' 'x = number(X)'
K 'kind(X)'       ALL                 '' 'out(kind(X))'
K 'env(X)'        'txt byt arr'       '' 'x = env(X)'

echo "== operators =="
K 'X . text'      ALL                 '' 'out(X . "z")'
Kv 'X == 1'       false               '' 'out(X == 1)'
K 'X + 1'         'int flt'           '' 'out(X + 1)'
K 'X - 1'         'int flt'           '' 'out(X - 1)'
K 'X * 2'         'int flt'           '' 'out(X * 2)'
K 'X % 2'         'int'               '' 'out(X % 2)'
Km 'X < 1'        'int flt'           '' 'out(X < 1)'        ordmsg
K 'X << 1'        'int'               '' 'out(X << 1)'
K '~X'            'int'               '' 'out(~X)'
# The same operators when the answer goes into a u32 local, a local every
# assignment masks to 32 bits, which the compiler keeps raw and computes in
# 32-bit registers (gen_u32). A program with a float in it has no u32 locals,
# so the float cell takes the ordinary path. The others must fault the way the
# operator does. They used to print the low bits of a pointer or a singleton's
# word, and exit 0.
K 'u = X & mask'  'int'               '' 'u = 0
u = X & 4294967295
out(u)'
K 'u = (X ^ 5) & mask' 'int'          '' 'u = 0
u = (X ^ 5) & 4294967295
out(u)'
K 'u = (X + 1) & mask' 'int'          '' 'u = 0
u = (X + 1) & 4294967295
out(u)'
K 'u = ~X & mask' 'int'               '' 'u = 0
u = (~X) & 4294967295
out(u)'
K 'u = rotate(X) & mask' 'int'        '' 'u = 0
u = ((X << 8) | (X >> 24)) & 4294967295
out(u)'
# A refused condition is reported on the line that tests it. X is read out of an
# array on the line above, and that line's store is what `if X` and `loop X`
# used to report: a plain local left nothing in them that stored a line.
Km '!X'           'T F'               '' 'out(!X)'           condmsg
Km 'if X'         'T F'               '' 'if X
    out("y")
out("z")' condmsg
Km 'else if X'    'T F'               '' 'if false
    out("n")
else if X
    out("y")' condmsg 6
Km 'loop X'       'T F'               '' 'loop X
    break' condmsg
# A contract hook's answer is a condition as well (SPEC 3.2): `true` passes,
# `false` is the violation, and nothing else is an answer. The check compared
# with the integer 0 alone, so `false`, null and none all passed, on both
# targets. The answer is a parameter here, so only the run-time test can judge
# it, and the refusal names the hook's own line, 8.
hookmsg() { case $1 in F) echo "contract violation in f";; *) condmsg;; esac; }
Km 'f:before answers X' 'T'           '' 'f(v)
    return 7

f:before
    return v

out(f(X))' hookmsg 8
Km 'f:after answers X'  'T'           '' 'f(v)
    return v

f:after
    return result

out(f(X))' hookmsg 8
K 'X[0]'          'txt byt arr'       '' 'out(X[0])'
# "hi" and bytes("6869") are both literals, and a literal is read-only: those
# two cells fault too, with `write to a literal`.
K 'X[0] = v'      'arr'               '' 'X[0] = 1'
K 'loop c in X'   'txt byt arr'       '' 'loop c in X
    out(c)'
K 'text[X]'       'int'               '' 'out("0123456789"[X])'

echo "== against a float =="
# A comparison with a float on one side runs in doubles, and the other side was
# converted as if it were an integer whatever it held: a singleton, a map's
# cell, a region's address. null, false, true and none are the words 6, 14, 22
# and 30, so `none == 15.0` was true, and so was `true < 20.5`, on both targets.
# Equality crosses no kind (SPEC 3.3), so it's false for anything that isn't a
# number, however it's reached: directly, as a branch, or inside a structure.
Kv 'X == 1.5'     false '' 'out(X == 1.5)'
Kv '1.5 == X'     false '' 'out(1.5 == X)'
Kv 'X != 1.5'     true  '' 'out(X != 1.5)'
Kv 'X == 3.0..15.0' false '' 'out(X == 3.0 || X == 7.0 || X == 11.0 || X == 15.0)'
Kv 'if X == 15.0' n     '' 'if X == 15.0
    out("y")
else
    out("n")'
Kv '[X] == [15.0]' false '' 'b = array(1)
b[0] = 15.0
c = array(1)
c[0] = X
out(c == b)'
Kv '{k: X} == {k: 15.0}' false '' 'out({k: X} == {k: 15.0})'
# Ordering against a float faults with the message for X's kind, as it does
# against an integer.
Km 'X < 1.5'      'int flt' '' 'out(X < 1.5)'  ordmsg
Km '1.5 < X'      'int flt' '' 'out(1.5 < X)'  ordmsg
Km 'X >= 1.5'     'int flt' '' 'out(X >= 1.5)' ordmsg
Km 'if X > 20.5'  'int flt' '' 'if X > 20.5
    out("y")' ordmsg
Km 'sort([X, 1.5])' 'int flt' '' 's = array(2)
s[0] = X
s[1] = 1.5
out(len(sort(s)))' ordmsg 7

echo "== inside a region: the element decides =="
# A lexicographic comparison orders the element pair that decides it by the same
# rules (SPEC 3.3), so `[X] < [1]` answers for a number element and faults for
# any other with the message X gets on its own. It used to compare the element
# words, which for anything but two integers are two addresses: `[["b"]] < [["a"]]`
# was true, and so was the reverse.
Km '[X] < [1]'    'int flt' '' 'e = array(1)
e[0] = X
f = array(1)
f[0] = 1
out(e < f)' ordmsg 8
Km '[1] < [X]'    'int flt' '' 'e = array(1)
e[0] = 1
f = array(1)
f[0] = X
out(e < f)' ordmsg 8
Km '[[X]] < [[1]]' 'int flt' '' 'e = array(1)
e[0] = X
f = array(1)
f[0] = 1
g = array(1)
g[0] = e
h = array(1)
h[0] = f
out(g < h)' ordmsg 12
# An element that's the same word as the one it meets is equal without being
# looked at, whatever it is, which is what lets a cyclic value compare against
# itself. So these answer for every kind, a map and a singleton included.
Kv '[X] < [X]'    false '' 'e = array(1)
e[0] = X
f = array(1)
f[0] = X
out(e < f)'
Kv '[X] <= [X]'   true  '' 'e = array(1)
e[0] = X
f = array(1)
f[0] = X
out(e <= f)'
Kv '[X] == [X]'   true  '' 'e = array(1)
e[0] = X
f = array(1)
f[0] = X
out(e == f)'
# Except a nan: it is a nan at any depth (SPEC 2.6, 3.3), so two regions
# holding one are neither equal nor ordered, even when both elements are the
# same boxed word. Whether they share a box depends on the backend: arm64 does,
# and it answered true here where x86-64 answered false.
check '[nan] vs [nan]' flt '0.0 / 0.0' 0 '' 'e = array(1)
e[0] = X
f = array(1)
f[0] = X
out((e == f) . " " . (e == copy(e)) . " " . (e <= f) . " " . (e >= copy(e)) . " " . (e < f))' '' 'false false false false false'
# sort orders by the same comparison, so a region whose elements have no order
# faults where the comparison would.
Km 'sort([[X], [1]])' 'int flt' '' 'e = array(1)
e[0] = X
f = array(1)
f[0] = 1
g = array(2)
g[0] = e
g[1] = f
out(len(sort(g)))' ordmsg 11

echo "== stored into a byte region =="
# A byte-backed element keeps the low byte of an integer (SPEC 9), so any other
# value is refused where it is stored. x86-64 had no check and kept the low byte
# of the pointer or tag word ("hi" read back as 8, true as 11), and on both
# targets a float stored its box pointer. Each shape of the store is asked: the
# backing known with a literal index and with a variable one, and unknown with
# each, which is the store that tests the flag at run time.
bytemsg() {
  case $1 in
    flt) echo 'operator needs whole numbers';;
    map) echo 'number expected, got a map';;
    T|F|nul|non) echo 'number expected, got true, false, null or none';;
    *) echo 'number expected, got a region';;
  esac
}
Km 'bytes(2)[0] = X' 'int' '' 'b = bytes(2)
b[0] = X
out(b[0])' bytemsg 5
Km 'bytes(2)[i] = X' 'int' '' 'b = bytes(2)
i = 1
b[i] = X
out(b[1])' bytemsg 6
Km 'r[0] = X, r text or bytes' 'int' '' 'r = text(2)
if len(a) == 1
    r = bytes(2)
r[0] = X
out(r[0])' bytemsg 7
Km 'r[i] = X, r out of an array' 'int' '' 's = array(1)
s[0] = bytes(2)
r = s[0]
i = 1
r[i] = X
out(r[1])' bytemsg 8

echo "== rendered as text =="
# An element that is not an integer can be written neither as a character nor
# as a number (SPEC 9.1). A region, a map and a float faulted, but a singleton
# was written as the control byte its tag word shifts down to (true as 0x0B), by
# out, by a join and inside JSON. encode took it for a code point the same way.
charmsg() { echo 'not a character'; }
txtmsg() { echo 'text: expected a whole number'; }
Km 'out(text with X)' 'int' '' 't = text(2)
t[0] = 65
t[1] = X
out(t)' charmsg 7
Km 'out("" . text with X)' 'int' '' 't = text(2)
t[0] = 65
t[1] = X
out("" . t)' charmsg 7
Km 'out({k: text with X})' 'int' '' 't = text(2)
t[0] = 65
t[1] = X
out({k: t})' charmsg 7
Km 'encode(text with X)' 'int' txt 't = text(2)
t[0] = 65
t[1] = X
out(len(encode(t)))' txtmsg 8

echo "== two unknowns: every pair of kinds =="
KK 'X < Y'        lt_rule 'out(X < Y)'
KK 'X < Y'        lt_rule 'out(X < Y)' text
KK 'if X >= Y'    ge_rule 'if X >= Y
    out(true)
else
    out(false)'
KK 'X == Y'       eq_rule 'out(X == Y)'

echo "== json =="
K 'parse(X)'      'txt byt arr'       json 'x = parse(X)'
K 'stringify(X)'  'int flt txt byt arr map T F nul' json 'x = stringify(X)'

echo "== fs =="
K 'read(X)'       'txt byt arr'       fs 'x = read(X)'
K 'dir(X)'        'txt byt arr'       fs 'x = dir(X)'
Kf 'write(X,d)'   'int flt map T F nul non' fs 'write(X, "d")'
Kf 'write(f,X)'   'int flt map T F nul non' fs 'write("kinds_wt", X)'
Kf 'rename(X,b)'  'int flt map T F nul non' fs 'rename(X, "b")'
Kf 'rename(a,X)'  'int flt map T F nul non' fs 'rename("kinds_rn", X)'
# A path is written as the UTF-8 of its code points, so an element that isn't a
# code point (a float, a region, a singleton) is a fault, as it is for out().
K 'read(path of X)' 'int'             fs 'p = text(1)
p[0] = X
x = read(p)'
# So is the data write and append are handed, and the fault comes before the
# file is opened. Each element's low byte used to be written, whatever it was:
# part of a pointer for a region, and a different byte on each target for a
# float.
Km 'write(f, data of X)'  'int'      fs "p = text(1)
p[0] = X
x = write(\"$tmp/kinds_wd\", p)" charmsg 7
Km 'append(f, data of X)' 'int'      fs "p = text(1)
p[0] = X
x = append(\"$tmp/kinds_wd\", p)" charmsg 7
# And the integers that are not code points: a negative number, a surrogate
# (U+D800..U+DFFF) and anything past U+10FFFF, in the data write() is handed, in
# a path and in encode(). A surrogate used to pass all three as the bytes
# ED A0 80. The code points at each edge are still taken, on both targets.
for cp in "0 - 1" 55296 57343 1114112; do
  check "write(f, data of $cp)" int "$cp" 70 fs "p = text(1)
p[0] = X
x = write(\"$tmp/kinds_wd\", p)" '' "p.w:7: not a character"
done
for cp in 55296 57343; do
  check "read(path of $cp)" int "$cp" 70 fs 'p = text(1)
p[0] = X
x = read(p)' '' "p.w:7: not a character"
  check "encode(text of $cp)" int "$cp" 70 txt 'p = text(1)
p[0] = X
x = encode(p)' '' "p.w:7: not a character"
done
for cp in 0 55295 57344 1114111; do
  check "write(f, data of $cp)" int "$cp" 0 fs "p = text(1)
p[0] = X
x = write(\"$tmp/kinds_wd\", p)" '' ''
  check "encode(text of $cp)" int "$cp" 0 txt 'p = text(1)
p[0] = X
out(len(encode(p)))' '' ''
done

echo "== txt =="
K 'char(X)'       'int'               txt 'x = char(X)'
K 'decode(X)'     'txt byt arr'       txt 'x = decode(X)'
K 'encode(X)'     'txt byt arr'       txt 'x = encode(X)'
K 'split(X,c)'    'txt byt arr'       txt 'x = split(X, ",")'
K 'split(a,X)'    'txt byt arr'       txt 'x = split("a", X)'
K 'pad(X,3,1)'    'txt byt arr'       txt 'x = pad(X, 3, 1)'
K 'pad(a,X,1)'    'int'               txt 'x = pad("a", X, 1)'
K 'pad(a,3,X)'    'int'               txt 'x = pad("a", 3, X)'

# One row per place a region check can refuse, on both targets. NR is every kind
# that is neither a region nor a map; a row adds `map` where a map is refused
# with this message too, and leaves it out where a map is accepted or refused
# for another reason (`X[0]` on a map asks for the key 0, a number).
echo "== region expected, and what it got =="
NR='int flt T F nul non'
R 'len(X)'        "$NR"       ''   'out(len(X))'
R 'X[0]'          "$NR"       ''   'out(X[0])'
R 'X[0] = v'      "$NR"       ''   'X[0] = 1'
R 'loop c in X'   "$NR map"   ''   'loop c in X
    out(c)'
R 'copy(X)'       "$NR"       ''   'out(len(copy(X)))'
R 'copy(X,0)'     "$NR map"   ''   'out(len(copy(X, 0)))'
R 'copy(X,0,0)'   "$NR map"   ''   'out(len(copy(X, 0, 0)))'
R 'sort(X)'       "$NR map"   ''   'out(len(sort(X)))'
R 'find(X,s)'     "$NR map"   ''   'out(find(X, "a"))'
R 'find(s,X)'     "$NR map"   ''   'out(find("a", X))'
# A map used as a map key got the ordering message, `this needs a number or a
# region, not a map`, where SPEC 10.2 says a key that is not text is `region
# expected` like any other.
R 'm[X]'          "$NR map"   ''   'out({z: 1}[X])'
R 'has(m,X)'      "$NR map"   ''   'out(has({z: 1}, X))'
Km 'm[X] = v'     'txt byt arr' ''  'm = {z: 1}
m[X] = 1' regmsg 5
R 'env(X)'        "$NR map"   ''   'out(env(X))'
R 'parse(X)'      "$NR map"   json 'out(parse(X))'
R 'read(X)'       "$NR map"   fs   'out(read(X))'
R 'dir(X)'        "$NR map"   fs   'out(dir(X))'
R 'write(X,d)'    "$NR map"   fs   'out(write(X, "d"))'
R 'write(f,X)'    "$NR map"   fs   'out(write("kinds_wt", X))'
R 'rename(X,b)'   "$NR map"   fs   'out(rename(X, "kinds_rn"))'
R 'rename(a,X)'   "$NR map"   fs   'out(rename("kinds_rn", X))'
R 'decode(X)'     "$NR map"   txt  'out(decode(X))'
R 'encode(X)'     "$NR map"   txt  'out(encode(X))'
R 'split(X,c)'    "$NR map"   txt  'out(split(X, ","))'
R 'split(a,X)'    "$NR map"   txt  'out(split("a", X))'
R 'pad(X,3,1)'    "$NR map"   txt  'out(pad(X, 3, 1))'

# The net verbs check their arguments at the call, before the bundled library
# runs, so a refusal gives the caller's line and comes before anything is sent.
# It used to give a line of the library, `p.w:5841` in this five-line p.w. The
# url and the body must be regions and the flag true or false, and the first
# argument written is the first one refused.
#
# A url that is a region reaches the network (DNS, for "hi"), so for the url
# only the refusals are checked. The body and the flag are checked for every
# kind, with a url nothing listens on: an accepted kind answers none there
# without reaching anything, and so would a refused one whose check waited for
# the connection, which is where the body's was. A number body was not refused
# at all: it was sent as no body.
echo "== net: a wrong kind is refused at the call =="
U='"http://127.0.0.1:9/"'
# post(u, X, X): the body is refused before the flag, and a region body gets as
# far as the flag, which refuses it as a condition.
bodyflagmsg() { case $1 in txt|byt|arr) condmsg;; *) regmsg "$1";; esac; }
R  'get(X)'       "$NR map"     net 'x = get(X)'
R  'head(X)'      "$NR map"     net 'x = head(X)'
R  'delete(X)'    "$NR map"     net 'x = delete(X)'
R  'post(X,b)'    "$NR map"     net 'x = post(X, "b")'
R  'put(X,b)'     "$NR map"     net 'x = put(X, "b")'
R  'get(X,X)'     "$NR map"     net 'x = get(X, X)'
R  'post(X,X,X)'  "$NR map"     net 'x = post(X, X, X)'
Km 'post(u,X)'    'txt byt arr' net "x = post($U, X)"          regmsg
Km 'put(u,X)'     'txt byt arr' net "x = put($U, X)"           regmsg
Km 'get(u,X)'     'T F'         net "x = get($U, X)"           condmsg
Km 'head(u,X)'    'T F'         net "x = head($U, X)"          condmsg
Km 'delete(u,X)'  'T F'         net "x = delete($U, X)"        condmsg
Km 'post(u,b,X)'  'T F'         net "x = post($U, \"b\", X)"   condmsg
Km 'put(u,b,X)'   'T F'         net "x = put($U, \"b\", X)"    condmsg
Km 'post(u,X,X)'  ''            net "x = post($U, X, X)"       bodyflagmsg

# The sys verbs import themselves, so any program can reach them, and none of
# them used to look at what it was given: recv(3, 100) and connect(5, 80) died
# on SIGSEGV, recv into a text wrote raw bytes over its tagged words, and exec
# walked whatever it got as a list of regions. Each argument is checked now,
# before the OS sees it. A whole number (an fd, a port, a timeout, a mark)
# refuses a float as not whole and anything else as not a number. An address
# or a buffer is bytes, and text or an array is refused by the name kind()
# gives it. No cell reaches the network: fd 5 is not a socket, a zero-length
# buffer moves nothing, and an address that is not four bytes answers 0 before
# any syscall.
echo "== sys: every argument is checked =="
intmsg() {
  case $1 in
    flt) echo 'operator needs whole numbers';;
    txt|byt|arr) echo 'number expected, got a region';;
    map) echo 'number expected, got a map';;
    *) echo 'number expected, got true, false, null or none';;
  esac
}
bytesmsg() {
  case $1 in
    txt) echo 'bytes expected, got text';;
    arr) echo 'bytes expected, got an array';;
    *) regmsg "$1";;
  esac
}
# recv writes into its buffer, and the one bytes value in KINDS is a literal.
recvmsg() { case $1 in byt) echo 'write to a literal';; *) bytesmsg "$1";; esac; }
# exec's list is the compiler's own: element 0 counts the arguments after it,
# so "hi" read as a list counts 104 of them in a region of two.
listmsg() { case $1 in txt|byt) echo 'index 104 out of bounds for a region of length 2';; *) regmsg "$1";; esac; }
Km 'connect(X,p)'  'byt'         '' 'out(connect(X, 9))'         bytesmsg
Km 'connect(a,X)'  'int'         '' 'out(connect(bytes(3), X))'  intmsg
Km 'udp(X,p)'      'byt'         '' 'out(udp(X, 53))'            bytesmsg
Km 'udp(a,X)'      'int'         '' 'out(udp(bytes(3), X))'      intmsg
Km 'send(X,b)'     'int'         '' 'out(send(X, bytes(0)))'     intmsg
Km 'send(f,X)'     'byt'         '' 'out(send(-1, X))'           bytesmsg
Km 'recv(X,b)'     'int'         '' 'out(recv(X, bytes(0)))'     intmsg
Km 'recv(f,X)'     ''            '' 'out(recv(0, X))'            recvmsg
Km 'timeout(X,ms)' 'int'         '' 'x = timeout(X, 100)'        intmsg
Km 'timeout(f,X)'  'int'         '' 'x = timeout(5, X)'          intmsg
Km 'close(X)'      'int'         '' 'x = close(X)'               intmsg
Km 'asmput(X)'     'txt byt arr' '' 'asmput(X)
out(len(asmtake()))' regmsg
# A mark is a whole number, and 5 words is inside what this program has used.
Km 'reset(X)'      'int'         '' 'p = text(8)
reset(X)
out("ok")' intmsg 5
# A mark is a number: how many words of the arena are in use. It used to be
# the bump pointer itself, which carries the region tag, so out(mark()) and
# kind(mark()) read unallocated memory as a region and died on SIGSEGV. reset
# takes a mark back only while it is inside what the arena holds, so one from
# before an earlier reset, or a number that never was a mark, is a fault. X is
# the mark here, taken on the line that stores it.
check 'kind(mark())'        mark 'mark()' 0  '' 'out(kind(X))' '' 'number'
check '"" . mark()'         mark 'mark()' 0  '' 's = "" . X
out(len(s) > 0)' '' 'true'
check 'len(mark())'         mark 'mark()' 70 '' 'out(len(X))' '' 'p.w:4: region expected, got a number'
check 'reset(mark())'       mark 'mark()' 0  '' 't = text(9)
reset(X)
out(mark() == X)' '' 'true'
check 'reset(a stale mark)' mark 'mark()' 70 '' 't = text(9)
m2 = mark()
reset(X)
reset(m2)' '' 'p.w:7: index out of bounds'
check 'reset(not a mark)'   mark 'mark()' 70 '' 'reset(X - X - 1)' '' 'p.w:4: index out of bounds'
Km 'writex(p,X)'   'txt byt arr' '' 'out(writex("/nonexistent/kinds", X))' regmsg
Km 'exec(p,X)'     'arr'         '' 'x = exec("/nonexistent/kinds", X)
out("failed")' listmsg
Km 'exec(p,[1,X])' 'txt byt arr' '' 'l = array(2)
l[0] = 1
l[1] = X
x = exec("/nonexistent/kinds", l)
out("failed")' regmsg 7
# A path that is a region names a file, so these two run in directories of
# their own: writex creates "hi", and exec finds nothing called "hi" to run.
mkdir -p "$tmp/sysw" "$tmp/syse"
cd "$tmp/sysw"
Km 'writex(X,d)'   'txt byt arr' '' 'out(writex(X, bytes(0)))'   regmsg
cd "$tmp/syse"
Km 'exec(X,l)'     'txt byt arr' '' 'l = text(1)
l[0] = 0
x = exec(X, l)
out("failed")' regmsg 6
cd "$root"

echo "test_kinds: $pass passed, $fail failed$a64note"
[ "$fail" = 0 ] || exit 1
