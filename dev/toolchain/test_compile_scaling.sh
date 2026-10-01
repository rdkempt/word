#!/bin/sh
# test_compile_scaling.sh: compiling N functions has to cost about N, whichever
# way round the call graph runs, and so does compiling one function with N
# locals.
#
# The whole-program parameter-kind pass (infer_param_kinds) is a fixpoint. When
# it re-scanned every function on each pass, it took one pass per link of a
# call chain, and with a linear name lookup on top it was cubic. It only shows
# on one shape: a chain of functions where each caller is defined after its
# callee, so what's known travels backwards through the file one link a pass.
#
#     500 functions      878 ms          1,000 functions   6,896 ms
#   2,000 functions   47,476 ms          4,000 functions 405,788 ms
#
# The same 4,000 functions with no chain took 43 ms, so the cost came from the
# graph and not the function count.
#
# Two checks, both ratios, so a slow machine doesn't matter:
#
#   1. Shape: doubling the chain length mustn't multiply the time by more than
#      3. Linear is about 2, and the cubic pass measured 7.9.
#   2. Direction: the backward chain mustn't cost more than 3x the forward
#      chain of the same size. The cubic pass measured 85x.
#
# Then one function with many locals. Every name a function holds used to sit
# in a list that each lookup walked (the frame's env, the local-kind and u32
# tables, the analyzer's scopes and kind table, the for-each and rewind sets),
# so a function with n locals cost n^2 to compile:
#
#     2,500 locals     2.1 s             5,000 locals     9.2 s
#    10,000 locals    40.2 s            20,000 locals   194.7 s
#
# Each is a map now. Three shapes, since each reaches different tables: plain
# integer locals, a for-each loop per name, and a region per name that the
# dead-store rewind tracks. Doubling the names mustn't multiply the time by
# more than 3 either; the lists measured 4.4.
#
# Each timing is the best of three runs. One wall-clock sample on a shared
# runner is too noisy for a margin of 3 against a true value of 2: this once
# failed at 359% on a compiler byte-identical to one that had just passed.
# Noise only adds time, so the minimum is the closest estimate of the real
# cost.
#
# Every binary built here also has to run and print the right answer, so a
# compiler that got fast by skipping the pass fails.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

# back <n>: f_i calls f_{i-1}, so the caller is always defined after the callee.
# fwd <n>:  f_i calls f_{i+1}, the same program with the definitions reversed.
gen_back() {
  awk -v n="$1" 'BEGIN{
    print "f0(a, b)"; print "    return a + b";
    for(i=1;i<n;i++){ printf "f%d(a, b)\n", i; printf "    return f%d(a, b) + %d\n", i-1, i%7 }
    printf "out(f%d(1, 2))\n", n-1 }' > "$tmp/back_$1.w"
}
gen_fwd() {
  awk -v n="$1" 'BEGIN{
    for(i=0;i<n-1;i++){ printf "f%d(a, b)\n", i; printf "    return f%d(a, b) + %d\n", i+1, i%7 }
    printf "f%d(a, b)\n", n-1; print "    return a + b";
    print "out(f0(1, 2))" }' > "$tmp/fwd_$1.w"
}
# 3 (f(1, 2) at the base) plus the constant each other link adds. The two
# chains add over different ranges (backward over i=1..n-1, forward over
# i=0..n-2), so the answers differ, and each is computed on its own.
want_back() { awk -v n="$1" 'BEGIN{ t=3; for(i=1;i<n;i++)   t += i%7; print t }'; }
want_fwd()  { awk -v n="$1" 'BEGIN{ t=3; for(i=0;i<n-1;i++) t += i%7; print t }'; }

build() { best=""
          for _try in 1 2 3; do
            t0=$(date +%s%N)
            "$WORD" build "$tmp/$1.w" -o "$tmp/$1" >/dev/null 2>&1 || { echo "test_compile_scaling: FAIL (build of $1 failed)"; exit 1; }
            t1=$(date +%s%N); ms=$(( (t1 - t0) / 1000000 ))
            if [ -z "$best" ] || [ "$ms" -lt "$best" ]; then best=$ms; fi
          done
          MS=$best; }

check() { got=$("$tmp/$1"); [ "$got" = "$2" ] || {
            echo "test_compile_scaling: FAIL ($1 printed '$got', want '$2')"; exit 1; }; }

gen_back 500;  build back_500;  ms_500=$MS;  check back_500  "$(want_back 500)"
gen_back 1000; build back_1000; ms_1000=$MS; check back_1000 "$(want_back 1000)"
gen_fwd  1000; build fwd_1000;  ms_fwd=$MS;  check fwd_1000  "$(want_fwd 1000)"

lo=$ms_500;  [ "$lo" -lt 1 ] && lo=1
ratio=$(( ms_1000 * 100 / lo ))
if [ "$ratio" -gt 300 ]; then
  echo "test_compile_scaling: FAIL (doubling the chain multiplied compile time by ${ratio}%; linear is ~200%, the cubic pass measured 790%)"; exit 1
fi

lof=$ms_fwd; [ "$lof" -lt 1 ] && lof=1
dir=$(( ms_1000 * 100 / lof ))
if [ "$dir" -gt 300 ]; then
  echo "test_compile_scaling: FAIL (a backward call chain cost ${dir}% of the forward one, so the fixpoint is order-dependent)"; exit 1
fi

# locals <n>: f has n integer locals, summed 500 at a time (a chain is capped at
# 1024 operators). each <n>: n for-each loops, each binding its own name.
# rewind <n>: n locals, each given a fresh region inside a loop.
gen_locals() {
  awk -v n="$1" 'BEGIN{
    print "f(x)"; print "    s = 0";
    for(i=0;i<n;i++) printf "    a%d = x + %d\n", i, i;
    for(c=0;c<n/500;c++){ printf "    s = s"; for(i=c*500;i<(c+1)*500;i++) printf " + a%d", i; print "" }
    print "    return s"; print "out(f(1))" }' > "$tmp/locals_$1.w"
}
gen_each() {
  awk -v n="$1" 'BEGIN{
    print "f(r)"; print "    s = 0";
    for(i=0;i<n;i++){ printf "    loop v%d in r\n", i; printf "        s = s + v%d\n", i }
    print "    return s";
    print "a = array(2)"; print "a[0] = 1"; print "a[1] = 2"; print "out(f(a))" }' > "$tmp/each_$1.w"
}
gen_rewind() {
  awk -v n="$1" 'BEGIN{
    print "f(t)"; print "    s = 0"; print "    i = 0"; print "    loop i < 2";
    for(k=0;k<n;k++) printf "        c%d = copy(t, 0, 1)\n", k;
    for(c=0;c<n/500;c++){ printf "        s = s"; for(k=c*500;k<(c+1)*500;k++) printf " + len(c%d)", k; print "" }
    print "        i = i + 1"; print "    return s"; print "out(f(\"abc\"))" }' > "$tmp/rewind_$1.w"
}
locals_note=""
for shape in locals each rewind; do
  for n in 4000 8000; do
    "gen_$shape" "$n"; build "${shape}_$n"
    case $shape in
      locals) want=$(( n + n * (n - 1) / 2 ));;
      each)   want=$(( 3 * n ));;
      rewind) want=$(( 2 * n ));;
    esac
    check "${shape}_$n" "$want"
    eval "ms_${shape}_$n=\$MS"
  done
  eval "a=\$ms_${shape}_4000; b=\$ms_${shape}_8000"
  [ "$a" -lt 1 ] && a=1
  r=$(( b * 100 / a ))
  if [ "$r" -gt 300 ]; then
    echo "test_compile_scaling: FAIL (doubling a function's $shape from 4000 to 8000 names multiplied compile time by ${r}% ($a ms, $b ms); linear is ~200%, the lists measured 440%)"; exit 1
  fi
  locals_note="$locals_note, $shape ${a}/${b} ms"
done

echo "test_compile_scaling: PASS (500 in ${ms_500} ms, 1000 in ${ms_1000} ms, ratio ${ratio}%; backward vs forward ${dir}%; 4000/8000 names:${locals_note#,})"
