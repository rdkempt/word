#!/bin/sh
# test_sort_scaling.sh: sort() must be O(n log n). It used to be an O(n^2)
# insertion sort, and 50,000 integers took 3.1 seconds.
#
# Both checks leave a wide margin, so a loaded runner doesn't fail them:
#
#   1. A wall-clock limit at a size no quadratic sort can meet. At 3.1 s for
#      n=50000, n=400000 would take about 200 s. The limit is 20 s.
#   2. Doubling n must not quadruple the time. n log n grows by about 2.1x per
#      doubling and n^2 by 4x, so a ratio above 3 catches a quadratic sort even
#      on a machine fast enough to pass check 1.
#
# Both run twice, because sort has two paths: a region of plain integers is
# radix sorted, and one float among them sends the same data through the merge
# sort. The radix run is fast enough that at 200,000 elements it's mostly
# process startup, whose jitter moved its ratio from 166% to 249% on a loaded
# machine, so it's measured at five times that size, and every time is taken in
# microseconds.
#
# The program also checks that its result is sorted, since a fast sort that
# doesn't sort would pass a timing test.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

# Build an n-element sort that checks its own output is in order and prints
# "ok <n> <number out of order>", so the harness checks the answer too. $2 is
# "int" (every element an integer: the radix path) or "float" (one float in the
# middle: the merge path).
gen() {
  mix=""
  [ "$2" = float ] && mix="a[n >> 1] = 0.5"
  cat > "$tmp/s_$1_$2.w" <<EOF
n = $1
a = text(n)
x = 12345
i = 0
loop i < n
    x = (x * 48271) % 2147483647
    a[i] = x
    i = i + 1
$mix
s = sort(a)
bad = 0
j = 1
loop j < n
    if s[j - 1] > s[j]
        bad = bad + 1
    j = j + 1
out("ok " . len(s) . " " . bad)
EOF
  "$WORD" build "$tmp/s_$1_$2.w" -o "$tmp/s_$1_$2" >/dev/null 2>&1
}

run() { t0=$(date +%s%N); GOT=$("$tmp/s_$1_$2"); t1=$(date +%s%N); US=$(( (t1 - t0) / 1000 )); }

LIMIT=20000
summary=""
for P in int float; do
  if [ "$P" = int ]; then N1=1000000; N2=2000000; else N1=200000; N2=400000; fi
  for N in $N1 $N2; do
    gen "$N" "$P"
    run "$N" "$P"
    if [ "$GOT" != "ok $N 0" ]; then
      echo "test_sort_scaling: FAIL ($P, n=$N produced '$GOT', want 'ok $N 0': the result is not sorted)"; exit 1
    fi
    if [ "$US" -gt $((LIMIT * 1000)) ]; then
      echo "test_sort_scaling: FAIL ($P, n=$N took $((US / 1000)) ms > ${LIMIT} ms, sort has gone quadratic)"; exit 1
    fi
    eval "us_$N=$US"
  done
  # Shape check. Give the smaller measurement a floor of 1 us, so a very fast
  # machine can't divide by zero.
  eval "lo=\$us_$N1; hi=\$us_$N2"
  [ "$lo" -lt 1 ] && lo=1
  ratio=$(( hi * 100 / lo ))
  if [ "$ratio" -gt 300 ]; then
    echo "test_sort_scaling: FAIL ($P: doubling n multiplied the time by ${ratio}%; n log n is ~210%, n^2 is ~400%)"; exit 1
  fi
  summary="$summary${summary:+; }$P: n=$N1 in $((lo / 1000)) ms, n=$N2 in $((hi / 1000)) ms, ratio ${ratio}%"
done

echo "test_sort_scaling: PASS ($summary, O(n log n))"
