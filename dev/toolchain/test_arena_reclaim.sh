#!/bin/sh
# test_arena_reclaim.sh: the places where the runtime stopped charging a whole
# run for values that die right away.
#
# The arena is a bump allocator with no garbage collector (SPEC 3.5), so peak
# memory grows with everything a program ever allocated, not with what it
# holds. That's the right trade for short scripts, but some of the benchmarks
# were paying it for pure garbage: a loop counter rendered to text and copied
# out in the next instruction, the dead half of every doubling copy, a map key
# that exists for one lookup, and a float box that exists only to carry a value
# across a call.
#
# The mechanisms, none of them a garbage collector:
#
#   1. join and append render a number or a float into a static scratch region
#      instead of an arena one (rt_as_region_scr).
#   2. append extends in place when the region it's growing is the most recent
#      allocation: a bump instead of an allocate-and-copy (.app_grow).
#   3. an owned temporary in an argument position is popped off the bump
#      pointer once the operation that used it is done (rt_popregion). A `.`
#      join qualifies, and so does a call to one of the builtins that always
#      allocate their result: slice, sort, keys, and everything that decodes
#      text, including the net verbs.
#   4. a parameter every caller passes a float to is passed as a raw double, so
#      the box that only existed to cross the call is never made (gen_call).
#   5. the region a name is about to overwrite is given back, even when the
#      name was passed to a function that only reads it (infer_retention).
#
# Each of them can hand the same bytes out twice if it's wrong, so most of this
# file checks that values stay correct. The capped runs check that memory
# actually went down.
#
# No `set -e`, so a failing case is counted and the rest still run.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$root"
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 60"
p="$tmp/p.w"; exe="$tmp/p"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  OK   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1 -- $2"; }

prog() { cat > "$p"; nm="$1"; want="$2"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then bad "$nm" "build failed: $("$WORD" build "$p" -o "$exe" 2>&1 | head -1)"; return; fi
  got=$($TO "$exe" 2>&1); rc=$?
  if [ "$got" = "$want" ] && [ "$rc" = 0 ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc want [$want]"; fi; }

echo "== rendering a number through the scratch says the same thing =="
# A join of two numbers uses both scratches at once, and the second mustn't
# overwrite the first. That's why there are two.
prog "a join of two numbers uses both scratches" "12 -1-2 0 0" <<'EOF'
a = 1
b = 2
c = 0
out((a . b) . " " . ((0 - a) . (0 - b)) . " " . (c . "") . " " . ("" . c))
EOF
prog "the 63-bit extremes render intact" "2305843009213693951 -2305843009213693951" <<'EOF'
hi = 2305843009213693951
out(hi . " " . (0 - hi))
EOF
prog "floats render through the scratch too" "3.14 -0.5 inf 2.5x" <<'EOF'
z = 0.0
out((3.14 . " ") . ((0.0 - 0.5) . " ") . ((1.0 / z) . " ") . (2.5 . "x"))
EOF
# A float too long for the scratch has to fall back to allocating instead of
# being cut short.
prog "a long float falls back rather than truncating" "1" <<'EOF'
x = 1.0
i = 0
loop i < 60
    x = x * 10.0
    i = i + 1
t = "" . x
u = "" . x
if t == u
    out(1)
else
    out(0)
EOF

echo "== extending in place must not change what the region holds =="
# The expected pair is cross-checked against CPython:
#   s = "".join("<"+str(i)+">" for i in range(100000))
#   len(s), sum(ord(c) for c in s)  ->  688890 37916720
prog "a grow-heavy append loop is byte-for-byte right" "688890 37916720" <<'EOF'
n = 100000
s = "" . ""
i = 0
loop i < n
    s = s . "<" . i . ">"
    i = i + 1
sum = 0
j = 0
loop j < len(s)
    sum = sum + s[j]
    j = j + 1
out(len(s) . " " . sum)
EOF
# With another allocation in between, the region isn't the most recent one
# half the time, so both the in-place path and the copy path run.
prog "interleaved allocation exercises both growth paths" "6 1" <<'EOF'
s = "" . ""
other = "" . ""
i = 0
loop i < 3
    s = s . "ab"
    other = other . "zz"
    i = i + 1
if s == "ababab"
    out(len(s) . " 1")
else
    out(len(s) . " 0")
EOF
prog "a region grown past a chunk boundary is still intact" "1" <<'EOF'
s = "" . ""
i = 0
loop i < 300000
    s = s . "abcdefghij"
    i = i + 1
if len(s) == 3000000 && s[2999999] == 106 && s[0] == 97
    out(1)
else
    out(0)
EOF

echo "== popping an owned temporary must never hand the bytes out twice =="
# A map key is kept by the map, so it must never be popped. Every key is read
# back after 20,000 later joins.
prog "keys stored in a map survive later allocation" "20000 199990000" <<'EOF'
n = 20000
m = {}
i = 0
loop i < n
    m["k" . i] = i
    i = i + 1
junk = ""
j = 0
loop j < 20000
    junk = "" . j
    j = j + 1
sum = 0
q = 0
loop q < n
    sum = sum + m["k" . q]
    q = q + 1
out(len(m) . " " . sum)
EOF
prog "has() with a joined key does not disturb the map" "20000 20000" <<'EOF'
n = 20000
m = {}
i = 0
loop i < n
    m["k" . i] = i
    i = i + 1
c = 0
j = 0
loop j < n
    if has(m, "k" . j)
        c = c + 1
    j = j + 1
out(len(m) . " " . c)
EOF
prog "out of a join prints the right thing every time" "line 0/line 1/line 2/" <<'EOF'
s = ""
i = 0
loop i < 3
    s = s . ("line " . i) . "/"
    i = i + 1
out(s)
EOF
# A join whose result is kept isn't in an argument position, so nothing may pop
# it. This is the case that breaks if the rule is ever widened too far.
prog "a kept join is untouched by later pops" "hello 3" <<'EOF'
kept = "hel" . "lo"
m = {}
m["a"] = 1
i = 0
c = 0
loop i < 3
    if has(m, "a" . "")
        c = c + 1
    i = i + 1
out(kept . " " . c)
EOF

echo "== the same rule, widened to calls that always allocate =="
# `.` isn't the only operation that always allocates. slice, sort, keys and
# everything that decodes text (in, args, env, fs.read, the net verbs) do too,
# so a call to one in an argument position is owned there as well. The danger
# is the same: a result that's kept must never be popped, and neither must the
# region it came from.
prog "len of a slice in a loop, values intact" "3 300000" <<'EOF'
s = "abcdefghij"
i = 0
t = 0
loop i < 100000
    t = t + len(copy(s, 2, 5))
    i = i + 1
out(len(copy(s, 0, 3)) . " " . t)
EOF
prog "a kept slice survives everything allocated after it" "cde abcdefghij" <<'EOF'
s = "abcdefghij"
kept = copy(s, 2, 5)
i = 0
loop i < 50000
    junk = copy(s, 0, 4)
    i = i + 1
out(kept . " " . s)
EOF
prog "sorting in an argument position leaves the input alone" "3 9 1" <<'EOF'
r = text(3)
r[0] = 9
r[1] = 1
r[2] = 5
i = 0
loop i < 20000
    junk = len(sort(r))
    i = i + 1
out(len(sort(r)) . " " . r[0] . " " . r[1])
EOF
prog "keys() in an argument position leaves the map alone" "2 2 1" <<'EOF'
m = {}
m["a"] = 1
m["b"] = 2
i = 0
loop i < 20000
    junk = len(keys(m))
    i = i + 1
k = keys(m)
out(len(keys(m)) . " " . len(m) . " " . m[k[0]])
EOF
prog "out of a slice prints the right bytes" "bcd" <<'EOF'
s = "abcdefghij"
out(copy(s, 1, 4))
EOF
prog "a joined key built from a slice still finds its entry" "1" <<'EOF'
m = {}
m["ab"] = 1
s = "xxabxx"
out(m[copy(s, 2, 4)])
EOF

echo "== a raw float parameter is invisible from either side =="
prog "float arguments through several call shapes" "6.25 6.25 0.5 2.5" <<'EOF'
sq(v)
    return v * v
outer(v)
    return sq(v)
down(v)
    if v <= 1.0
        return v
    return down(v - 1.0)
show(v)
    return v
out(sq(2.5) . " " . outer(2.5) . " " . down(5.5) . " " . show(2.5))
EOF
prog "two float parameters, and one of each" "13.0 7.5" <<'EOF'
add2(x, y)
    return x + y
mix(x, n)
    return x * n
out(add2(6.0, 7.0) . " " . mix(2.5, 3))
EOF
prog "a contract hook sees the same value the body does" "guard:2.5
6.25" <<'EOF'
sq(v)
    return v * v

sq:before
    out("guard:" . v)
    return true

out(sq(2.5))
EOF

echo "== and the memory actually went down =="
# Each of these runs under an address-space cap that the build before this work
# couldn't fit in (it reported "out of memory") and this one can. The sizes
# matter: `ulimit -v` bounds virtual address space and the arena reserves its
# first chunk up front, so a workload has to outgrow that chunk before the
# difference shows. Every one of these does.
cat > "$p" <<'EOF'
m = {}
m["k1"] = 1
i = 0
c = 0
loop i < 2000000
    if has(m, "k" . i)
        c = c + 1
    i = i + 1
out(c)
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$( (ulimit -v 200000; $TO "$exe") 2>&1 ); rc=$?
  if [ "$rc" = 0 ] && [ "$got" = 1 ]; then ok "two million dead map keys fit in 200 MB"
  else bad "dead map keys" "rc=$rc out=[$got]"; fi
else bad "dead map keys" "build failed"; fi

cat > "$p" <<'EOF'
s = "" . ""
i = 0
loop i < 900000
    s = s . "<" . i . ">"
    i = i + 1
out(len(s))
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$( (ulimit -v 200000; $TO "$exe") 2>&1 ); rc=$?
  if [ "$rc" = 0 ] && [ -n "$got" ]; then ok "a 900k-iteration join chain fits in 200 MB"
  else bad "join chain under a cap" "rc=$rc out=[$got]"; fi
else bad "join chain under a cap" "build failed"; fi

# A chain of joins used as a temporary: each iteration's line is used by len()
# and popped. Joined pair by pair, the chain's intermediates sat below it in the
# arena where the pop couldn't reach, about 450 bytes an iteration. Joined in
# one go (rt_joinn) there's one region, and it's popped.
cat > "$p" <<'EOF'
i = 0
t = 0
loop i < 2000000
    t = t + len("id=" . i . " name=user" . (i % 97) . ";")
    i = i + 1
out(t)
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$( (ulimit -v 200000; $TO "$exe") 2>&1 ); rc=$?
  if [ "$rc" = 0 ] && [ "$got" = 44682700 ]; then ok "two million five-part joins fit in 200 MB"
  else bad "a join chain's intermediates under a cap" "rc=$rc out=[$got]"; fi
else bad "a join chain's intermediates under a cap" "build failed"; fi

echo "== a callee that only READS its argument no longer blocks the rewind =="
# The rewind used to stop at every user call, because nothing told the caller
# what the callee did with the region. Now infer_retention works it out, and the
# risk is getting it wrong: a region handed back, stored or passed on is still
# reachable after the call, and rewinding it hands the same bytes out twice.
#
# Each case below reads its kept region back after later iterations have
# allocated over it. Each slice is kept in its own slot, since in one slot the
# last window would be there either way.
prog "a region stored into another region survives" "1,2,3,4 | 8,9,10,11 | 16,17,18,19" <<'EOF'
keep(box, i, t)
    box[i] = t
    return 0
show(r)
    return r[0] . "," . r[1] . "," . r[2] . "," . r[3]
main()
    y = bytes(64)
    i = 0
    loop i < 64
        y[i] = i + 1
        i = i + 1
    box = array(16)
    n = 0
    loop n < 16
        t = copy(y, n, n + 4)
        keep(box, n, t)
        n = n + 1
    out(show(box[0]) . " | " . show(box[7]) . " | " . show(box[15]))
    return 0
main()
EOF
prog "a region stored into a map survives" "1,2,3,4 | 16,17,18,19" <<'EOF'
keep(m, k, t)
    m[k] = t
    return 0
show(r)
    return r[0] . "," . r[1] . "," . r[2] . "," . r[3]
main()
    y = bytes(64)
    i = 0
    loop i < 64
        y[i] = i + 1
        i = i + 1
    m = {}
    n = 0
    loop n < 16
        t = copy(y, n, n + 4)
        keep(m, "k" . n, t)
        n = n + 1
    out(show(m["k0"]) . " | " . show(m["k15"]))
    return 0
main()
EOF
prog "a region handed straight back survives" "1,2,3,4" <<'EOF'
give_back(t)
    return t
main()
    y = bytes(256)
    i = 0
    loop i < 256
        y[i] = i % 251 + 1
        i = i + 1
    r = 0
    n = 0
    loop n < 16
        t = copy(y, n * 8, n * 8 + 64)
        if n == 0
            r = give_back(t)
        n = n + 1
    out(r[0] . "," . r[1] . "," . r[2] . "," . r[3])
    return 0
main()
EOF
prog "a region passed on to a keeper survives" "1,2,3,4 | 16,17,18,19" <<'EOF'
keep(box, i, t)
    box[i] = t
    return 0
via(box, i, t)
    keep(box, i, t)
    return 0
show(r)
    return r[0] . "," . r[1] . "," . r[2] . "," . r[3]
main()
    y = bytes(64)
    i = 0
    loop i < 64
        y[i] = i + 1
        i = i + 1
    box = array(16)
    n = 0
    loop n < 16
        t = copy(y, n, n + 4)
        via(box, n, t)
        n = n + 1
    out(show(box[0]) . " | " . show(box[15]))
    return 0
main()
EOF
prog "a region put in a map literal that is returned survives" "1,2,3,4" <<'EOF'
keep_lit(t)
    o = {a: t}
    return o
main()
    y = bytes(64)
    i = 0
    loop i < 64
        y[i] = i + 1
        i = i + 1
    lo = 0
    n = 0
    loop n < 16
        t = copy(y, n, n + 4)
        if n == 0
            lo = keep_lit(t)
        n = n + 1
    v = lo["a"]
    out(v[0] . "," . v[1] . "," . v[2] . "," . v[3])
    return 0
main()
EOF

# And the memory. Four million 64-byte windows through a read-only helper is
# about 350 MB of arena if none of them is given back. The cap is 200 MB, so
# this run either reclaims or dies.
cat > "$p" <<'EOF'
look(t)
    return t[0] + t[63]
main()
    y = bytes(4096)
    i = 0
    loop i < 4096
        y[i] = i % 251
        i = i + 1
    acc = 0
    n = 0
    loop n < 4000000
        t = copy(y, n % 2048, n % 2048 + 64)
        acc = acc + look(t)
        n = n + 1
    out(acc)
    return 0
main()
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$( (ulimit -v 200000; $TO "$exe") 2>&1 ); rc=$?
  if [ "$rc" = 0 ] && [ "$got" = 988437325 ]; then ok "four million slices through a helper fit in 200 MB"
  else bad "slices through a helper under a cap" "rc=$rc out=[$got]"; fi
else bad "slices through a helper under a cap" "build failed"; fi

cat > "$p" <<'EOF'
dist(x, y)
    return x * x + y * y
i = 0
c = 0
loop i < 6000000
    a = i * 0.5
    b = a + 1.5
    if dist(a, b) > 1000000.0
        c = c + 1
    i = i + 1
out(c)
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$( (ulimit -v 200000; $TO "$exe") 2>&1 ); rc=$?
  if [ "$rc" = 0 ] && [ "$got" = 5998587 ]; then ok "six million float calls fit in 200 MB"
  else bad "float calls under a cap" "rc=$rc out=[$got]"; fi
else bad "float calls under a cap" "build failed"; fi

echo ""
echo "test_arena_reclaim: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
