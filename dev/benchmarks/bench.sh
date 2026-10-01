#!/bin/sh
# bench.sh: run the cross-language benchmark suite.
#
# Every benchmark folder holds the same program written in word and in each
# comparison language. This script builds each one (recording build time and
# artifact size), runs it REPS times, checks that every language printed the
# same answer, and writes both a table for people and results.csv.
#
# Every rep is kept, not just the best one, and the median is the headline: the
# ratios are computed from it. The minimum is biased low (it's the one luckiest
# rep, and the more reps there are the lower it goes), while a shared machine's
# occasional slow rep doesn't move the median at all. So each row also has the
# minimum, the p95, the sample standard deviation, and the first run of the set.
# The rep count is in the row, and dev/benchmarks/README.md says what each of
# those figures is worth at that count.
#
# A row is a measurement only when it says `ok`. A build that fails, a run that
# exits non-zero or answers differently from one rep to the next, and an answer
# that differs from the other languages' each get a row that says so instead
# (BUILD FAILED, FAILED(...), MISMATCH(...)), and each makes this script exit 1,
# which stops bench.yml before it renders or publishes anything. None of them
# used to fail the run: a failed word run could come out marked `ok`, become
# the answer the other languages were checked against, and exit 0.
#
# The comparison toolchains (gcc, g++, rustc, go, python3, node) are dev-only:
# nothing here is needed to build or run word itself. A missing one is skipped.
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}
# 10 instead of 5: the spread columns below are only worth printing if there
# are enough samples for a median and a p95 to mean anything, and 10 is where
# that starts while keeping the whole suite inside a few minutes.
REPS=${REPS:-10}
RUNSTAT="$here/runstat"

[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
[ -x "$RUNSTAT" ] || cc -O2 "$here/runstat.c" -o "$RUNSTAT" || exit 1

# ---- the revision the numbers belong to ------------------------------------
# Asked before this script writes anything. results.csv and environment.txt
# are tracked, and asking after they'd been rewritten used to make every run
# (a fresh CI checkout included) call its own tree dirty. The files the
# benchmark jobs regenerate are left out of the question. Any other tracked
# file that differs from HEAD is a real difference from the revision named, so
# it's named too.
revision=$(cd "$root" && git rev-parse --short HEAD 2>/dev/null) || revision=""
if [ -z "$revision" ]; then
  revision="(not a git checkout)"
elif ! changed=$(cd "$root" && git diff --name-only HEAD -- . \
        ':(exclude)dev/benchmarks/results.csv' ':(exclude)dev/benchmarks/environment.txt' \
        ':(exclude)dev/benchmarks/compilespeed.txt' ':(exclude)dev/benchmarks/scaling.txt' \
        ':(exclude)docs/PERFORMANCE.md' 2>/dev/null); then
  revision="$revision (tree state unknown)"
elif [ -n "$changed" ]; then
  nchanged=$(printf '%s\n' "$changed" | wc -l | tr -d ' ')
  names=$(printf '%s\n' "$changed" | head -5 | paste -sd, - | sed 's/,/, /g')
  [ "$nchanged" -gt 5 ] && names="$names and $((nchanged - 5)) more"
  revision="$revision (dirty tree: $names)"
fi

BENCHES=${*:-"hello fib sieve mandelbrot vecmath strbuild strchain slicebench sortints mapbench jsonbench nethttp nethttps"}
out="$here/results.csv"
echo "benchmark,language,build_ms,artifact_bytes,run_ms,run_ms_median,run_ms_p95,run_ms_stddev,run_ms_first,reps,peak_rss_kb,ok" > "$out"

# ---- the environment the numbers came from ---------------------------------
# "word is 1.2x C" means little without saying which C. The comparison
# toolchain versions are written here, next to results.csv, and rendered onto
# the page beside the ratios they explain (they used to be in CI's log only).
env_out="$here/environment.txt"
{
  echo "measured    $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo "revision    $revision"
  # Where it ran, recorded here so it doesn't depend on who renders the page.
  if [ -n "$GITHUB_ACTIONS" ]; then
    echo "machine     GitHub Actions \`$RUNNER_OS/$RUNNER_ARCH\` (a shared runner)"
  else
    echo "machine     a developer machine"
  fi
  cpu=$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //')
  [ -n "$cpu" ] || cpu=$(uname -p 2>/dev/null || echo unknown)
  echo "cpu         $cpu ($(nproc 2>/dev/null || echo '?') cores)"
  echo "kernel      $(uname -sr)"
  echo "reps        $REPS per benchmark per language"
  echo ""
  for c in gcc g++ rustc go python3 node; do
    printf '%-11s ' "$c"
    if ! command -v "$c" >/dev/null 2>&1; then echo "(absent, skipped)"; continue; fi
    v=$("$c" --version 2>/dev/null | head -1)
    [ -n "$v" ] || v=$("$c" version 2>/dev/null | head -1)
    echo "${v:-(version unknown)}"
  done
} > "$env_out"

have() { command -v "$1" >/dev/null 2>&1; }

# millis() runs a command and echoes its wall time in ms (build timing).
millis() {
    s=$(date +%s%N); "$@" >/dev/null 2>&1; rc=$?; e=$(date +%s%N)
    echo $(( (e - s) / 1000000 )) ; return $rc
}

# stats_of() reads one millisecond figure per line and echoes
# "min median p95 stddev". It's all done in awk in one pass over the sorted
# samples, so there's no shell float arithmetic (dash has none) and no
# dependency beyond what already renders these tables.
#
# p95 is nearest-rank: the ceil(0.95 * n)-th smallest sample. At ten reps that's
# the slowest run and nothing more. It's printed so a reader can see the tail,
# not because ten samples estimate a 95th percentile. The standard deviation is
# the sample one (n-1), for the same reason: it says how far the reps spread.
# It isn't a significance test (at ten reps nothing here can show that a 5%
# difference is real), but a gap that's small beside it hasn't been shown.
stats_of() {
    sort -n | awk '
      { v[n++] = $1; s += $1 }
      END {
        if (n == 0) { print "0 0 0 0"; exit }
        mean = s / n
        med = (n % 2) ? v[int(n / 2)] : (v[n / 2 - 1] + v[n / 2]) / 2
        r = int(0.95 * n); if (r < 0.95 * n) r++; if (r < 1) r = 1
        for (i = 0; i < n; i++) { d = v[i] - mean; ss += d * d }
        sd = (n > 1) ? sqrt(ss / (n - 1)) : 0
        printf "%.3f %.3f %.3f %.3f\n", v[0], med, v[r - 1], sd
      }'
}

# sample() runs $BIN REPS times via runstat, echoing
# "min median p95 stddev first reps peak-rss stdout-digest", or, when a rep
# fails, the label its row gets instead, and returning 1.
#
# `first` is the first of the reps, kept separately because it's the one run
# whose page cache and dynamic loader state differ from the rest. It isn't a
# true cold start (the binary was built moments earlier and is still in cache),
# so it's called `first`.
#
# Every rep's answer is held to the first rep's, not only the last rep's to the
# other languages': a program whose answer moves between runs isn't doing a
# fixed amount of work, and a rep that went wrong without a sign would
# otherwise be timed with the rest.
sample() {
    : > "$tmp/times"
    brss=0; digest=""; first=""
    i=0
    while [ $i -lt "$REPS" ]; do
        "$RUNSTAT" "$@" >"$tmp/stdout" 2>"$tmp/stderr"
        stats=$(grep '^RUNSTAT' "$tmp/stderr" | tail -1)
        ms=$(echo "$stats" | cut -d' ' -f2); rss=$(echo "$stats" | cut -d' ' -f3)
        rc=$(echo "$stats" | cut -d' ' -f4)
        if [ "$rc" != 0 ]; then
            # The program's own first error line goes in the row, so it says
            # what went wrong and not only that something did. It's a CSV
            # field, so its commas are replaced.
            why=$(grep -v '^RUNSTAT' "$tmp/stderr" | head -1 | tr -d '\r' | tr ',' ';' | cut -c1-160)
            echo "FAILED(exit ${rc:-?} on rep $((i + 1))${why:+: $why})"
            return 1
        fi
        got=$(tr -d ' \n' < "$tmp/stdout")
        if [ $i = 0 ]; then digest=$got
        elif [ "$got" != "$digest" ]; then
            echo "FAILED(rep $((i + 1)) answered differently from rep 1)"
            return 1
        fi
        [ -n "$first" ] || first=$ms
        echo "$ms" >> "$tmp/times"
        [ "$rss" -gt "$brss" ] && brss=$rss
        i=$((i + 1))
    done
    echo "$(stats_of < "$tmp/times") $first $REPS $brss $digest"
}

# fail_row <language> <label>: the row a language gets when it produced no
# measurement. It's printed, and written to results.csv with no figures so the
# reason stays with the numbers (mkperf.sh renders only `ok` rows), and it
# fails the benchmark it belongs to.
fail_row() {
    printf "%-8s %10s %12s %10s %10s %9s %10s  %s\n" "$1" - - - - - - "$2"
    echo "$b,$1,,,,,,,,,,$2" >> "$out"
    bad=1
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
failed=""; skipped=""

for b in $BENCHES; do
    d="$here/$b"
    # One that was asked for and isn't there fails instead of skipping: a
    # misspelt name, or a folder the default list still names after it's gone,
    # would otherwise measure nothing and pass.
    [ -d "$d" ] || { echo "FAIL $b (no such folder)"; failed="$failed $b"; continue; }
    echo ""
    echo "== $b =========================================================="
    printf "%-8s %10s %12s %10s %10s %9s %10s\n" \
        language build_ms artifact_B run_ms median stddev rss_KB
    # A benchmark that needs something running (the net ones need a local
    # server) provides setup.sh / teardown.sh. Setup failing is a skip, not an
    # error: it's how a machine without python3 or openssl opts out. A skipped
    # benchmark has no rows at all, so it's named again at the end.
    if [ -f "$d/setup.sh" ]; then
        if ! sh "$d/setup.sh" "$tmp"; then
            echo "  SKIP $b (setup could not start what it needs)"
            skipped="$skipped $b"
            continue
        fi
    fi
    ( cd "$d" || exit 1
      # gen.w writes the input the programs read. If it fails, that input is
      # missing, or left over from some other run.
      if [ -f gen.w ] && ! "$WORD" run gen.w >/dev/null 2>&1; then
          echo "  gen.w FAILED, so there is nothing to measure"; exit 1
      fi
      expect=""; bad=0
      for lang in word c cpp rust go python node; do
        case $lang in
          word)   src="$b.w";   [ -f "$src" ] || continue
                  # built from the repo root with an absolute source path. (A net
                  # program's library is inside the word binary, so nothing on
                  # disk has to be found for it.)
                  bt=$(cd "$root" && millis "$WORD" build "$d/$src" -o "$tmp/$b.word") \
                      || { fail_row word "BUILD FAILED"; continue; }
                  bin="$tmp/$b.word"; set -- "$bin" ;;
          c)      src="$b.c";   [ -f "$src" ] || continue; have gcc || continue
                  bt=$(millis gcc -O2 "$src" -o "$tmp/$b.c.bin") || { fail_row c "BUILD FAILED"; continue; }
                  bin="$tmp/$b.c.bin"; set -- "$bin" ;;
          cpp)    src="$b.cpp"; [ -f "$src" ] || continue; have g++ || continue
                  bt=$(millis g++ -O2 "$src" -o "$tmp/$b.cpp.bin") || { fail_row cpp "BUILD FAILED"; continue; }
                  bin="$tmp/$b.cpp.bin"; set -- "$bin" ;;
          rust)   src="$b.rs";  [ -f "$src" ] || continue; have rustc || continue
                  bt=$(millis rustc -O -o "$tmp/$b.rs.bin" "$src") || { fail_row rust "BUILD FAILED"; continue; }
                  bin="$tmp/$b.rs.bin"; set -- "$bin" ;;
          go)     src="$b.go";  [ -f "$src" ] || continue; have go || continue
                  go build -o "$tmp/$b.go.bin" "$src" >/dev/null 2>&1   # warm the build cache first
                  bt=$(millis go build -o "$tmp/$b.go.bin" "$src") || { fail_row go "BUILD FAILED"; continue; }
                  bin="$tmp/$b.go.bin"; set -- "$bin" ;;
          python) src="$b.py";  [ -f "$src" ] || continue; have python3 || continue
                  bt=0; bin="$src"; set -- python3 "$src" ;;
          node)   src="$b.js";  [ -f "$src" ] || continue; have node || continue
                  bt=0; bin="$src"; set -- node "$src" ;;
        esac
        size=$(wc -c < "$bin" | tr -d ' ')
        if ! sample "$@" > "$tmp/sample"; then
            fail_row "$lang" "$(cat "$tmp/sample")"
            continue
        fi
        read -r rmin rmed rp95 rsd rfirst rreps rrss digest < "$tmp/sample"
        # The first language to produce an answer is the one the rest are held
        # to: word, unless word failed. A failed run doesn't get this far, so it
        # can't be the answer.
        ok=ok
        if [ -z "$expect" ]; then expect="$digest"
        elif [ "$digest" != "$expect" ]; then ok="MISMATCH($digest)"; bad=1; fi
        printf "%-8s %10s %12s %10s %10s %9s %10s  %s\n" \
            "$lang" "$bt" "$size" "$rmin" "$rmed" "$rsd" "$rrss" "$ok"
        echo "$b,$lang,$bt,$size,$rmin,$rmed,$rp95,$rsd,$rfirst,$rreps,$rrss,$ok" >> "$out"
      done
      exit $bad )
    status=$?
    [ -f "$d/teardown.sh" ] && sh "$d/teardown.sh" "$tmp"
    [ "$status" = 0 ] || failed="$failed $b"
done
echo ""
echo "results     -> $out"
echo "environment -> $env_out"
[ -z "$skipped" ] || echo "skipped    :$skipped (setup could not start what they need; no rows)"
if [ -n "$failed" ]; then
    echo "FAIL       :$failed (see the rows above); nothing from this run is a number to publish"
    exit 1
fi
