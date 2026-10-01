#!/bin/sh
# scaling.sh: measure how three word operations scale with n, to tell a
# constant factor from the wrong complexity. An O(n^2) operation quadruples
# when n doubles, and all three are close to linear now:
#
#   1. sort(region)     rt_sort was an insertion sort and is now a bottom-up
#                       merge sort, so the curve is n log n (roughly 2x per
#                       doubling, not 4x).
#   2. s = s . a . b    a left-nested join chain mustn't copy the whole region
#                       again on every pass. The in-place append used to fire
#                       only when the join's left operand was the assignment
#                       target. The chain is now lowered to one append per
#                       operand, so it's flat, and faster than the
#                       `s = s . (a . b)` workaround, which still builds a
#                       temporary region per pass.
#   3. t = copy(s, ...) a loop that copies has to stay flat in memory. copy
#                       allocates and the arena doesn't free on its own, so
#                       every window a loop had finished with used to stay on
#                       the peak. The dead-store rewind (x86-64, SPEC 3.5)
#                       gives each one back now. The rss column is the one to
#                       watch here, and it's the same at 4M copies as at 250k.
#
# Keep this script: it guards all three. A return to 4x per doubling in either
# time table, or an rss column that grows with n in the third, means the
# problem is back.
#
# A row is a measurement only when it has figures. A build that fails, a run
# that exits non-zero or is killed, and a run that exits 0 without printing the
# answer its program must print each get a row that says so instead (BUILD
# FAILED, FAILED(exit N: the program's first line of error), or
# MISMATCH(printed X, want Y)), and make this script exit 1, which stops
# bench.yml before it renders or publishes anything. None of them used to fail
# the run, so a program that faulted at once, or did none of its work, went
# onto the page as a small time and RSS that stayed flat as n doubled, the very
# shape these tables are read for.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; RUNSTAT="$here/runstat"
# bench.yml sends stdout to scaling.txt, so whatever its log should show goes to
# stderr.
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD" >&2; exit 1; }
[ -x "$RUNSTAT" ] || cc -O2 "$here/runstat.c" -o "$RUNSTAT" || exit 1
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# row <table> <n> <src-file> <answer>: one row: n, then the run time and peak
# RSS of that source built and run once, or the label the row gets when either
# step failed or the program didn't print <answer>. A failure also goes to
# stderr, and fails the run.
failed=0
row() {
    printf "%10s " "$2"
    if ! "$WORD" build "$3" -o "$tmp/p" >/dev/null 2>"$tmp/err"; then
        echo "BUILD FAILED"
        # The source is deleted with $tmp, so the start of the compiler's
        # error is all the log will have.
        { echo "scaling.sh: $1, n=$2: BUILD FAILED"; head -3 "$tmp/err" | sed 's/^/    /'; } >&2
        failed=$((failed + 1)); return 1
    fi
    "$RUNSTAT" "$tmp/p" >"$tmp/out" 2>"$tmp/err"
    stats=$(grep '^RUNSTAT' "$tmp/err" | tail -1)
    rc=$(echo "$stats" | cut -d' ' -f4)
    got=$(tr -d ' \n' < "$tmp/out")
    if [ "$rc" != 0 ]; then
        # runstat reports a death by signal as 128 + the signal, so a crash is
        # a failed run here too, not a fast one.
        why=$(grep -v '^RUNSTAT' "$tmp/err" | head -1 | tr -d '\r' | cut -c1-160)
        label="FAILED(exit ${rc:-?}${why:+: $why})"
    elif [ "$got" != "$4" ]; then
        # A program that printed anything but its answer didn't do the work it
        # was timed doing: a loop miscompiled into running no times is fast,
        # and flat.
        label="MISMATCH(printed $(printf '%s\n' "${got:-nothing}" | cut -c1-40), want $4)"
    else
        echo "$stats" | awk '{printf "%10.1f %10d\n", $2, $3}'
        return 0
    fi
    echo "$label"; echo "scaling.sh: $1, n=$2: $label" >&2
    failed=$((failed + 1)); return 1
}

# The answers, worked out here without word, since there's no second language
# in this script to disagree with a wrong one. awk's numbers are doubles, which
# hold every value below exactly: the largest product, 48271 times a value
# under 2^31, is still under 2^53.
#
# lcg_min <n>: the smallest of the first n values of the generator the sort
# program fills its region with, which is what sort puts first.
lcg_min() { awk -v n="$1" 'BEGIN { x = 12345
    for (i = 0; i < n; i++) { x = (x * 48271) % 2147483647; if (i == 0 || x < m) m = x }
    printf "%.0f\n", m }'; }
# copy_sum <n>: what the copy loop adds up, the first element of each window,
# (j % 4000) % 251 for every j below n: whole passes over the 4000 starts, then
# part of one.
copy_sum() { awk -v n="$1" 'BEGIN { for (i = 0; i < 4000; i++) whole += i % 251
    for (i = 0; i < n % 4000; i++) part += i % 251
    printf "%.0f\n", int(n / 4000) * whole + part }'; }

echo "== sort(region): time vs n (expect ~2x per doubling: n log n) =="
printf "%10s %10s %10s\n" n ms rss_KB
for n in 50000 100000 200000 400000; do
    cat > "$tmp/s.w" <<EOF
n = $n
a = text(n)
x = 12345
i = 0
loop i < n
    x = (x * 48271) % 2147483647
    a[i] = x
    i = i + 1
s = sort(a)
out(s[0])
EOF
    row "sort(region)" "$n" "$tmp/s.w" "$(lcg_min "$n")"
done

echo ""
echo "== s = s . \"a\" . \"b\"  (left-nested chain) vs n (expect flat) =="
printf "%10s %10s %10s\n" n ms rss_KB
for n in 2000 4000 8000 16000; do
    cat > "$tmp/c.w" <<EOF
s = ""
i = 0
loop i < $n
    s = s . "a" . "b"
    i = i + 1
out(len(s))
EOF
    row "left-nested chain" "$n" "$tmp/c.w" $((2 * n))
done

echo ""
echo "== s = s . (\"a\" . \"b\")  (right-associated; misses the in-place append) =="
printf "%10s %10s %10s\n" n ms rss_KB
for n in 2000 4000 8000 16000 320000; do
    cat > "$tmp/d.w" <<EOF
s = ""
i = 0
loop i < $n
    s = s . ("a" . "b")
    i = i + 1
out(len(s))
EOF
    row "right-associated chain" "$n" "$tmp/d.w" $((2 * n))
done

echo ""
echo "== t = copy(s, j, j + 64) in a loop vs n (expect flat rss) =="
printf "%10s %10s %10s\n" n ms rss_KB
for n in 250000 500000 1000000 2000000 4000000; do
    cat > "$tmp/e.w" <<EOF
s = text(4096)
i = 0
loop i < 4096
    s[i] = i % 251
    i = i + 1
sum = 0
j = 0
loop j < $n
    t = copy(s, j % 4000, j % 4000 + 64)
    sum = sum + t[0]
    j = j + 1
out(sum)
EOF
    row "copy loop" "$n" "$tmp/e.w" "$(copy_sum "$n")"
done

if [ "$failed" != 0 ]; then
    echo "scaling.sh: FAIL: $failed of its rows measured nothing, so nothing from this run is a number to publish" >&2
    exit 1
fi
