#!/bin/sh
# test_append_scaling.sh: an append loop has to be amortized O(1) per append,
# so linear in total. Before the uniqueness pass and capacity doubling it was
# O(n^2): n=20000 took 6.6 s and n=40000 was killed for running out of memory.
#
# It covers both spellings, because for a long time only the first was fast:
#
#   s = s . x            the two-operand form
#   s = s . a . b        a join chain. It associates left, so the outer join's
#                        left operand was a temporary instead of s, and the
#                        in-place path didn't fire. Every iteration copied the
#                        whole region, and 20000 iterations took 104 s and
#                        13.6 GB.
#
# The check has a wide margin: build the loop at a large n, check the length
# is exact and that it finishes under the limit (it takes a few ms; the old
# code would need minutes and gigabytes). A second size that also stays fast
# shows the growth is linear.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

gen() {                       # $1 = n : write and build an n-append loop
  cat > "$tmp/app_$1.w" <<EOF
s = ""
i = 0
loop i < $1
    s = s . "x"
    i = i + 1
out(len(s))
EOF
  "$WORD" build "$tmp/app_$1.w" -o "$tmp/app_$1" >/dev/null 2>&1
}

genchain() {                  # $1 = n : the same loop written as a join chain
  cat > "$tmp/ch_$1.w" <<EOF
s = ""
i = 0
loop i < $1
    s = s . "x" . "y"
    i = i + 1
out(len(s))
EOF
  "$WORD" build "$tmp/ch_$1.w" -o "$tmp/ch_$1" >/dev/null 2>&1
}

run() {                       # $1 = n : set GOT to stdout, MS to elapsed ms
  t0=$(date +%s%N)
  GOT=$("$tmp/app_$1")
  t1=$(date +%s%N)
  MS=$(( (t1 - t0) / 1000000 ))
}

# Quadratic scaling from 6.6 s at n=20000 would put n=400000 at about 44
# minutes, if it didn't run out of memory first. Linear takes a few ms, so
# 5000 ms leaves plenty of room for a slow or loaded CI machine.
LIMIT=5000
for N in 400000 800000; do
  gen "$N"
  run "$N"
  if [ "$GOT" != "$N" ]; then
    echo "test_append_scaling: FAIL (n=$N produced len '$GOT', want $N)"; exit 1
  fi
  if [ "$MS" -gt "$LIMIT" ]; then
    echo "test_append_scaling: FAIL (n=$N took ${MS} ms > ${LIMIT} ms, a quadratic regression in string append)"; exit 1
  fi
  eval "ms_$N=$MS"
done

# The chain form, at the same sizes. The quadratic version needed 104 s and
# 13.6 GB at n=20000.
for N in 400000 800000; do
  genchain "$N"
  t0=$(date +%s%N); GOT=$("$tmp/ch_$N"); t1=$(date +%s%N)
  MS=$(( (t1 - t0) / 1000000 ))
  WANT=$(( N * 2 ))
  if [ "$GOT" != "$WANT" ]; then
    echo "test_append_scaling: FAIL (chain n=$N produced len '$GOT', want $WANT)"; exit 1
  fi
  if [ "$MS" -gt "$LIMIT" ]; then
    echo "test_append_scaling: FAIL (chain n=$N took ${MS} ms > ${LIMIT} ms: the join chain is not hitting the in-place append path)"; exit 1
  fi
  eval "ch_$N=$MS"
done

echo "test_append_scaling: PASS (s = s . x: n=400000 in ${ms_400000} ms, n=800000 in ${ms_800000} ms;"
echo "                           s = s . a . b: n=400000 in ${ch_400000} ms, n=800000 in ${ch_800000} ms"
echo "                           and both are amortised O(1))"
