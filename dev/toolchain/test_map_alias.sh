#!/bin/sh
# test_map_alias.sh: the map-key aliasing matrix.
#
# SPEC 3.7: a map keeps the key's region, not a copy of it, and the key's slot
# in the index was chosen from its contents. So the region is read-only from
# the moment it becomes a key. This checks every way a program can get hold of
# that same region, and that the rule holds for each of them.
#
# There are fourteen ways: the name; the element `keys(m)` hands back; the
# for-each variable over `keys(m)`; an element of `copy(keys(m))` and of
# `sort(keys(m))`; a key of `copy(m)`, which is shallow and so shares the key
# words; the key stored into an array and read back; the same through another
# map's value; the same through a function call; a byte-backed key; a key
# `json.parse` built; a key of a nested map; a key that is a string literal;
# and a key re-inserted into a second map. The for-each variable is a single
# write case, and the other thirteen are the rows of the matrix.
#
# The columns are what a program then does with it: WRITE (refused with a
# located fault), READ (every reading use works), APPEND (the name moves, the
# key doesn't), COPY (the copy is writable and the map is untouched) and REKEY
# (one region keying two maps at once). The last column checks that the map
# still agrees with itself: its keys find their values, `len(keys(m))` is 1,
# and the JSON round trip holds.
#
# The bug this was written for: `keys(m)[0][0] = 'x'` changed a key without
# naming it, and the only check covered writes through the name.
#
# No `set -e`: the write cases are meant to fault and exit 70.
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

# Nothing below pipes into a helper. A case on the right of a pipe runs in a
# subshell, so its pass and fail counts are lost when the subshell exits (that
# once hid a real regression in test_lang.sh). Each program is written to $gen
# and handed to the helper by redirection instead.

# run <name> <expect-rc> <expect-output>: the program arrives on stdin.
run() { cat > "$p"; nm="$1"; erc="$2"; want="$3"
  if ! "$WORD" build "$p" -o "$exe" >"$tmp/berr" 2>&1; then
    bad "$nm" "did not build: $(head -1 "$tmp/berr")"; return; fi
  got=$($TO "$exe" 2>&1 </dev/null); rc=$?
  if [ "$rc" = "$erc" ] && [ "$got" = "$want" ]; then ok "$nm"; return; fi
  bad "$nm" "got [$(printf '%s' "$got" | tr '\n' '|')] rc=$rc, want [$(printf '%s' "$want" | tr '\n' '|')] rc=$erc"; }

# dies <name> <substring>: must build, then fault with a located message that
# contains $2, and exit 70.
dies() { cat > "$p"; nm="$1"; sub="$2"
  if ! "$WORD" build "$p" -o "$exe" >"$tmp/berr" 2>&1; then
    bad "$nm" "did not build: $(head -1 "$tmp/berr")"; return; fi
  got=$($TO "$exe" 2>&1 </dev/null); rc=$?
  case "$got" in *"$sub"*) m=1;; *) m=0;; esac
  case "$got" in *"p.w:"*) loc=1;; *) loc=0;; esac
  if [ "$m" = 1 ] && [ "$rc" = 70 ] && [ "$loc" = 1 ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc (want located [$sub], rc=70)"; fi; }

# ---------------------------------------------------------------------------
# Each reach leaves the map in `m` (one pair, key "abc" -> 1) and a reference
# to that key's region in `x`. There's no `import` line: a module function
# resolves on first use (SPEC 11.1), and an import has to come before any other
# line, which reach() has already written.
# ---------------------------------------------------------------------------
reach() {
  case "$1" in
  name)        printf 'k = "" . "abc"\nm = {}\nm[k] = 1\nx = k\n' ;;
  keys-index)  printf 'k = "" . "abc"\nm = {}\nm[k] = 1\nx = keys(m)[0]\n' ;;
  copy-keys)   printf 'k = "" . "abc"\nm = {}\nm[k] = 1\nx = copy(keys(m))[0]\n' ;;
  sort-keys)   printf 'k = "" . "abc"\nm = {}\nm[k] = 1\nx = sort(keys(m))[0]\n' ;;
  copy-map)    printf 'k = "" . "abc"\nm = {}\nm[k] = 1\nc = copy(m)\nx = keys(c)[0]\n' ;;
  in-array)    printf 'k = "" . "abc"\nm = {}\nm[k] = 1\na = array(1)\na[0] = keys(m)[0]\nx = a[0]\n' ;;
  in-map-val)  printf 'k = "" . "abc"\nm = {}\nm[k] = 1\nn = {}\nn["v"] = keys(m)[0]\nx = n["v"]\n' ;;
  thru-fn)     printf 'id(v)\n    return v\n\nk = "" . "abc"\nm = {}\nm[k] = 1\nx = id(keys(m)[0])\n' ;;
  bytes-key)   printf 'b = bytes(3)\nb[0] = 97\nb[1] = 98\nb[2] = 99\nm = {}\nm[b] = 1\nx = b\n' ;;
  parsed-key)  printf 'm = parse("{\\"abc\\":1}")\nx = keys(m)[0]\n' ;;
  nested-map)  printf 'k = "" . "abc"\nouter = {}\nouter["in"] = {}\nouter["in"][k] = 1\nm = outer["in"]\nx = keys(m)[0]\n' ;;
  literal-key) printf 'm = {}\nm["abc"] = 1\nx = keys(m)[0]\n' ;;
  rekeyed)     printf 'k = "" . "abc"\nfirst = {}\nfirst[k] = 9\nm = {}\nm[keys(first)[0]] = 1\nx = keys(m)[0]\n' ;;
  esac
}

# A literal's region was already read-only, and writing it faults `write to a
# literal`. Every other row faults `write to a map key`.
wrmsg() { case "$1" in literal-key) echo "write to a literal";; *) echo "write to a map key";; esac; }

ROWS="name keys-index copy-keys sort-keys copy-map in-array in-map-val thru-fn bytes-key parsed-key nested-map literal-key rekeyed"

echo "== a write through any reference to a key is refused =="
for r in $ROWS; do
  { reach "$r"; printf "x[0] = 'v'\nout(m)\n"; } > "$gen"
  dies "write: $r" "$(wrmsg "$r")" < "$gen"
done

# The for-each variable is its own case: the loop binds it, so no assignment
# names it and a per-name analysis has nothing to look at.
printf 'k = "" . "abc"\nm = {}\nm[k] = 1\nloop x in keys(m)\n    x[0] = 118\nout(m)\n' > "$gen"
dies "write: the for-each variable over keys(m)" "write to a map key" < "$gen"

echo "== reading one is unaffected, and the map is unchanged after =="
for r in $ROWS; do
  { reach "$r"
    printf 'out(len(x))\nout(x[0])\nout(x)\nout(x . "!")\nout(copy(x))\nout(x == "abc")\n'
    printf 'out(has(m, x))\nout(m[x])\nout(m["abc"])\nout(m)\n'
  } > "$gen"
  run "read: $r" 0 '3
97
abc
abc!
abc
true
true
1
1
{"abc":1}' < "$gen"
done

echo "== an append moves the name, never the key =="
for r in $ROWS; do
  { reach "$r"; printf 'x = x . "z"\nout(x)\nout(m["abc"])\nout(m["abcz"])\nout(m)\n'; } > "$gen"
  run "append: $r" 0 'abcz
1
none
{"abc":1}' < "$gen"
done

echo "== copy() is the writable one =="
for r in $ROWS; do
  { reach "$r"; printf "c = copy(x)\nc[0] = 'v'\nout(c)\nout(m[\"abc\"])\nout(m)\n"; } > "$gen"
  run "copy: $r" 0 'vbc
1
{"abc":1}' < "$gen"
done

echo "== the same region may key two maps at once =="
for r in $ROWS; do
  { reach "$r"; printf 'n = {}\nn[x] = 2\nout(m["abc"])\nout(n["abc"])\nout(m)\nout(n)\n'; } > "$gen"
  run "rekey: $r" 0 '1
2
{"abc":1}
{"abc":2}' < "$gen"
done

echo "== and the map still agrees with itself =="
# The original bug: out(m) printed a key m couldn't find. Every row looks each
# of its keys back up in m, and checks the JSON round trip (SPEC 3.7).
for r in $ROWS; do
  { reach "$r"
    printf 's = ""\nloop e in keys(m)\n    s = s . e . "=" . m[e] . ";"\n'
    printf 'out(s)\nout(len(keys(m)))\nout(parse(stringify(m)) == m)\nout(x == keys(m)[0])\n'
  } > "$gen"
  run "agrees: $r" 0 'abc=1;
1
true
true' < "$gen"
done

echo "== the shapes the rule exists to make impossible =="
# Two distinct keys that a write would make the same text.
printf 'a = "" . "ab"\nb = "" . "ac"\nm = {}\nm[a] = 1\nm[b] = 2\na[1] = 99\nout(m)\n' > "$gen"
dies "two keys cannot be made equal" "write to a map key" < "$gen"

# A key that is also an ordinary value elsewhere is still a key.
printf 'k = "" . "abc"\nm = {}\nm[k] = 1\na = array(1)\na[0] = k\na[0][0] = 118\nout(m)\n' > "$gen"
dies "a key stored as a value is still a key" "write to a map key" < "$gen"

# copy(m) is shallow (SPEC 9): the copy holds the same key words, so a write
# through the copy's keys is refused too...
printf 'k = "" . "abc"\nm = {}\nm[k] = 1\nc = copy(m)\nkeys(c)[0][0] = 118\n' > "$gen"
dies "copy(m) shares its keys, so the copy's keys refuse too" "write to a map key" < "$gen"
# ...but its values are its own.
printf 'k = "" . "abc"\nm = {}\nm[k] = 1\nc = copy(m)\nc["abc"] = 5\nout(m . " " . c)\n' > "$gen"
run "copy(m) is an independent value store" 0 '{"abc":1} {"abc":5}' < "$gen"

# A name that only overwrote an existing pair isn't kept as the key, so it stays
# an ordinary writable region, and writing it can't change the map.
printf 'a = "" . "abc"\nb = "" . "abc"\nm = {}\nm[a] = 1\nm[b] = 2\nb[0] = 118\nout(m . " " . b . " " . m["abc"])\n' > "$gen"
run "only the key that was INSERTED is retained" 0 '{"abc":2} vbc 2' < "$gen"

# A byte-backed key hashes as the text it equals, and stays byte-backed.
printf 'b = bytes(3)\nb[0] = 97\nb[1] = 98\nb[2] = 99\nm = {}\nm[b] = 1\nout(m["abc"])\nout(kind(keys(m)[0]))\nout(m)\n' > "$gen"
run "a byte-backed key is the text it equals" 0 '1
bytes
{"abc":1}' < "$gen"

# A hundred keys, every one of them reached through keys() and asked back.
printf 'm = {}\ni = 0\nloop i < 100\n    m["k" . i] = i\n    i = i + 1\nbad = 0\nloop e in keys(m)\n    if m[e] == none\n        bad = bad + 1\nout(len(keys(m)) . " " . bad . " " . m["k99"])\n' > "$gen"
run "a hundred keys all answer through keys()" 0 '100 0 99' < "$gen"

# And a program with no map at all still writes its own regions.
printf 's = "" . "abcd"\ns[0] = 118\nout(s)\n' > "$gen"
run "a program with no map writes freely" 0 'vbcd' < "$gen"

# ---------------------------------------------------------------------------
# The thirteen row refusals again on arm64, where a different emitter sets and
# tests the mark. Both targets must print the same fault, byte for byte.
# ---------------------------------------------------------------------------
QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
if [ -n "$QEMU" ]; then
  echo "== and arm64 refuses each of them the same way =="
  for r in $ROWS; do
    { reach "$r"; printf "x[0] = 'v'
out(m)
"; } > "$gen"
    cp "$gen" "$p"
    if ! "$WORD" build -arm64 "$p" -o "$tmp/a64" >"$tmp/berr" 2>&1; then
      bad "arm64 write: $r" "did not build: $(head -1 "$tmp/berr")"; continue; fi
    if ! "$WORD" build "$p" -o "$exe" >"$tmp/berr" 2>&1; then
      bad "arm64 write: $r" "x86-64 did not build"; continue; fi
    chmod +x "$tmp/a64"
    oa=$($TO $QEMU "$tmp/a64" 2>&1 </dev/null); ra=$?
    ox=$($TO "$exe" 2>&1 </dev/null); rx=$?
    want=$(wrmsg "$r")
    case "$oa" in *"$want"*) m=1;; *) m=0;; esac
    if [ "$oa" = "$ox" ] && [ "$ra" = "$rx" ] && [ "$m" = 1 ] && [ "$ra" = 70 ]; then
      ok "arm64 write: $r [$oa]"
    else
      bad "arm64 write: $r" "arm64 [$oa] rc=$ra, x86-64 [$ox] rc=$rx (want both [$want], rc=70)"
    fi
  done
else
  echo "  (skipping the arm64 half: no qemu-aarch64)"
fi

echo
echo "test_map_alias: $pass passed, $fail failed"
[ "$fail" = 0 ]
