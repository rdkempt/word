#!/bin/sh
# test_slice_scaling.sh: a loop that takes a slice each pass must stay flat in
# memory, instead of growing with the number of slices.
#
# copy() allocates (SPEC 9) and the arena only gives memory back in the cases
# SPEC 3.5 lists. So a loop like
#
#     loop x in offsets
#         t = copy(s, x, x + 64)
#
# used to keep every window it had finished with: 800k of them peaked at 419 MB.
# The dead-store rewind now gives the region back when a unique local is
# overwritten, so the peak is one window. Two checks:
#
#   1. Flat: three loop shapes, each making about 2M slices, run under an
#      address-space cap far below what holding them all would need. A leak
#      can't fit, so the result doesn't depend on sampling RSS (see
#      test_arena_reset.sh for the same approach).
#   2. Not over-eager: a slice that is kept must still be there. The rewind
#      depends on the uniqueness proof, and if that proof is wrong a region is
#      handed out twice and reads back as plausible garbage, with no crash. A
#      second program keeps 200 slices, an aliased pair and a slice of a slice,
#      and checks every element.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

# 2,000,000 windows of 64 elements is 2M x (64*8 + 24) = about 1.07 GB held,
# and one window at a time is a few KB. The cap sits between them, with room
# for the 128 MiB the arena maps up front.
CAP=400000                      # KB of address space
fail=0

build() { "$WORD" build "$tmp/$1.w" -o "$tmp/$1" >/dev/null 2>&1; }

capped() {                      # capped <prog> -> rc, out
  set +e
  ( ulimit -v "$CAP"; exec "$tmp/$1" ) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
}

flat() {                        # flat <name> <expected> <what>
  build "$1"
  t0=$(date +%s%N); capped "$1"; t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  if [ "$rc" = 0 ] && [ "$out" = "$2" ]; then
    echo "  ok: $3, 2M slices in ${ms} ms inside a ${CAP} KB cap"
  else
    echo "  FAIL: $3 (rc=$rc out=[$out] err=[$err])"; fail=1
  fi
}

# --- 1. flat: the three loop shapes -----------------------------------------

# `t = copy(...)` in a counted loop, where t is first bound inside the loop.
cat > "$tmp/decl.w" <<'EOF'
s = text(4096)
i = 0
loop i < 4096
    s[i] = i % 251
    i = i + 1
sum = 0
r = 0
loop r < 500
    j = 0
    loop j < 4000
        t = copy(s, j, j + 64)
        sum = sum + t[0] + t[63]
        j = j + 1
    r = r + 1
out(sum)
EOF

# `t = copy(...)` storing into a local bound before the loop.
sed 's/^sum = 0/t = copy(s, 0, 64)\nsum = 0/' \
    "$tmp/decl.w" > "$tmp/assign.w"

# `loop x in y`, the shape this started from.
cat > "$tmp/foreach.w" <<'EOF'
s = text(4096)
i = 0
loop i < 4096
    s[i] = i % 251
    i = i + 1
off = text(4000)
k = 0
loop k < 4000
    off[k] = k
    k = k + 1
sum = 0
r = 0
loop r < 500
    loop x in off
        t = copy(s, x, x + 64)
        sum = sum + t[0] + t[63]
    r = r + 1
out(sum)
EOF

# The three programs walk the same windows, so they must print the same sum.
# It comes from an uncapped run of decl.w instead of a hardcoded number, so
# the check is on flatness and not on what `i % 251` adds up to.
WANT=$(cd "$tmp" && "$WORD" run decl.w 2>/dev/null || true)
[ -n "$WANT" ] || { echo "FAIL: could not compute the expected sum"; exit 1; }

flat decl    "$WANT" "t = copy(...) in a counted loop"
flat assign  "$WANT" "t = copy(...) into a local declared outside"
flat foreach "$WANT" "loop x in y"

# --- 2. not over-eager: a kept slice is still there --------------------------

cat > "$tmp/keep.w" <<'EOF'
s = text(300)
i = 0
loop i < 300
    s[i] = i
    i = i + 1

// every slice is stored, so none of them is dead
held = text(200)
j = 0
loop j < 200
    t = copy(s, j, j + 64)
    held[j] = t
    j = j + 1

// a second variable aliasing the first, then the first reassigned
u = copy(s, 0, 64)
v = u
u = copy(s, 100, 164)

// a slice of a slice, where the right-hand side names the target
w = copy(s, 0, 128)
w = copy(w, 8, 72)

bad = 0
a = 0
loop a < 200
    h = held[a]
    if len(h) != 64
        bad = bad + 1
    b = 0
    loop b < 64
        if h[b] != a + b
            bad = bad + 1
        b = b + 1
    a = a + 1
c = 0
loop c < 64
    if v[c] != c
        bad = bad + 1
    if u[c] != 100 + c
        bad = bad + 1
    if w[c] != 8 + c
        bad = bad + 1
    c = c + 1
out(bad)
EOF
build keep
got=$("$tmp/keep")
if [ "$got" = 0 ]; then
  echo "  ok: 200 kept slices, an aliased pair and a self-referring slice all intact"
else
  echo "  FAIL: $got element(s) of a kept slice came back wrong, the rewind is over-eager"; fail=1
fi

if [ "$fail" = 0 ]; then
  echo "test_slice_scaling: PASS (slice in a loop is flat in memory, and a kept slice survives)"
  exit 0
fi
echo "test_slice_scaling: FAIL"
exit 1
