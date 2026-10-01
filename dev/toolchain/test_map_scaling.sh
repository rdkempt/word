#!/bin/sh
# test_map_scaling.sh: a map must stay O(1) per operation, so the hash has to
# keep the index scattered.
#
# `{}` is an open-addressing table with linear probing over an insertion-ordered
# pair region (SPEC 3.7), and the index is the low bits of the hash
# (`and rax, size-1`). Plain djb2 (`h*33 + c`) barely changes the low bits
# between neighbouring keys, so keys like `"k" . i` fell into long runs: 500,000
# of them took about thirty probes per operation. The hash now multiplies by the
# odd golden-ratio constant and shifts the high half down, and the same keys
# take about one.
#
# A clustered hash gives the same answers (`keys` is insertion order, never
# hash order), so only the clock shows it. Without the multiply, the first case
# below takes over 60 s instead of 0.3 s, so a limit of a few seconds has lots
# of room on a slow or loaded runner.
#
# Three key shapes, because they cluster differently: a common prefix and
# suffix around a varying middle (the worst), the bare `"k" . i` of the
# benchmark, and keys that differ only in their last character.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

LIMIT=8000                      # ms; the clustered version needs minutes

# case <name> <n> <key-expr-with-VAR> : build, run, check the sum, check the time
case_run() {
  nm="$1"; n="$2"; kx="$3"
  cat > "$tmp/m.w" <<EOF
n = $n
m = {}
i = 0
loop i < n
    m[$(echo "$kx" | sed 's/VAR/i/g')] = i
    i = i + 1
sum = 0
j = 0
loop j < n
    sum = sum + m[$(echo "$kx" | sed 's/VAR/j/g')]
    j = j + 1
out(len(m) . " " . sum)
EOF
  "$WORD" build "$tmp/m.w" -o "$tmp/m" >/dev/null 2>&1 || {
    echo "test_map_scaling: FAIL ($nm: build failed)"; exit 1; }
  t0=$(date +%s%N); got=$("$tmp/m"); t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  want="$n $(( (n - 1) * n / 2 ))"
  if [ "$got" != "$want" ]; then
    echo "test_map_scaling: FAIL ($nm n=$n gave '$got', want '$want')"; exit 1
  fi
  if [ "$ms" -gt "$LIMIT" ]; then
    echo "test_map_scaling: FAIL ($nm n=$n took ${ms} ms > ${LIMIT} ms, the hash is clustering)"; exit 1
  fi
  echo "  ok: $nm n=$n in ${ms} ms"
}

case_run "prefix and suffix" 200000 '"key-" . VAR . "-suffix"'
case_run "prefix and suffix" 400000 '"key-" . VAR . "-suffix"'
case_run "bare counter"      400000 '"k" . VAR'
case_run "differ at the end" 400000 'VAR . "z"'

# A key spelled a different way must still find its value. The hash runs on
# elements, so a byte-backed key, a joined key and a key sliced out of a
# longer text have to hash the same. (rt_map_hash promotes a byte-backed key
# first, and this case breaks if it stops.)
cat > "$tmp/mk.w" <<'EOF'
m = {}
m["alpha"] = 1
m["beta"] = 2
b = bytes(5)
b[0] = 97
b[1] = 108
b[2] = 112
b[3] = 104
b[4] = 97
j = "al" . "pha"
out(m[b] . " " . m[j] . " " . m[copy("xxbetayy", 2, 6)])
EOF
"$WORD" build "$tmp/mk.w" -o "$tmp/mk" >/dev/null 2>&1 || {
  echo "test_map_scaling: FAIL (key-spelling build failed)"; exit 1; }
got=$("$tmp/mk")
if [ "$got" != "1 1 2" ]; then
  echo "test_map_scaling: FAIL (a key spelled three ways must hash the same: got '$got', want '1 1 2')"; exit 1
fi
echo "  ok: a byte-backed, a joined and a sliced key all hash as the text they equal"

echo "test_map_scaling: PASS (insert + read back stays linear across four key shapes)"
