#!/bin/sh
# mkperf.sh: render docs/PERFORMANCE.md from the numbers bench.sh,
# compilespeed.sh and scaling.sh produced. Reads dev/benchmarks/results.csv (and
# compilespeed.txt, scaling.txt and environment.txt when they're there) and
# writes docs/PERFORMANCE.md.
#
# It only renders, so run the three scripts first, then this. bench.yml is set
# up to do that on every push to main, so the page on main has the numbers for
# main's own HEAD.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
csv="$here/results.csv"
out="$root/docs/PERFORMANCE.md"
[ -f "$csv" ] || { echo "mkperf: no $csv; run bench.sh first"; exit 1; }

# Every awk below reads results.csv by column number, so check that the header
# is the one they were written for. A shifted column still renders, just wrong:
# when the spread columns went in, peak RSS moved from $6 to $11 and the peak
# RSS column became a ratio of medians with no error. Failing the job is better.
want_header='benchmark,language,build_ms,artifact_bytes,run_ms,run_ms_median,run_ms_p95,run_ms_stddev,run_ms_first,reps,peak_rss_kb,ok'
got_header=$(head -1 "$csv")
if [ "$got_header" != "$want_header" ]; then
  echo "mkperf: results.csv is not the shape this renderer reads."
  echo "  want: $want_header"
  echo "  got:  $got_header"
  echo "  re-run bench.sh, or update the column numbers in this script to match."
  exit 1
fi

# Describe the machine that measured, which may not be the one rendering.
# bench.sh writes environment.txt as it runs, so these fields describe the run
# the numbers came from even when the page is rendered later or somewhere else.
# Each one falls back to asking this machine, so an older results.csv still
# renders.
envf="$here/environment.txt"
efield() { [ -f "$envf" ] && awk -v k="$1" '$1 == k { $1 = ""; sub(/^ +/, ""); print; exit }' "$envf"; }

cpu=$(efield cpu)
if [ -z "$cpu" ]; then
  cpu=$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //')
  [ -n "$cpu" ] || cpu=$(uname -p 2>/dev/null || echo unknown)
  cpu="$cpu ($(nproc 2>/dev/null || echo '?') cores)"
fi
kern=$(efield kernel); [ -n "$kern" ] || kern=$(uname -sr)
when=$(efield measured); [ -n "$when" ] || when=$(date -u '+%Y-%m-%d %H:%M UTC')
rev=$(efield revision)
[ -n "$rev" ] || rev=$(cd "$root" && git rev-parse --short HEAD 2>/dev/null || echo "(not a git checkout)")
# bench.sh names the changed files when the tree is dirty. A bare "(dirty tree)"
# with no names comes from a harness that asked git after rewriting two tracked
# files of its own, which labels every run that way, so the page says the label
# may not mean anything changed.
case "$rev" in
  *" (dirty tree)") rev="${rev% (dirty tree)} (labelled \"dirty tree\" with no files named, so the tree may have been clean)" ;;
esac
reps=$(efield reps); [ -n "$reps" ] || reps="(not recorded)"
# Where the numbers were measured, as bench.sh recorded it. Asking the renderer
# would call CI's numbers "a developer machine" when someone re-renders the page
# by hand, so only an environment.txt from before bench.sh wrote this line falls
# back to asking.
where=$(efield machine)
if [ -z "$where" ]; then
  if [ -n "$GITHUB_RUN_ID" ]; then
    where="GitHub Actions \`$RUNNER_OS/$RUNNER_ARCH\` (a shared runner)"
  else
    where="a developer machine"
  fi
fi

{
cat <<EOF
# Performance

How fast \`word\` is, measured. This page is generated: \`dev/benchmarks/mkperf.sh\`
renders it from the numbers \`dev/benchmarks/bench.sh\`, \`compilespeed.sh\` and
\`scaling.sh\` produce, and \`.github/workflows/bench.yml\` is set up to regenerate it
on every push to \`main\`. Don't edit it by hand, since the next run overwrites it.
The Measured and Revision rows say which run these numbers came from.

| | |
|---|---|
| Measured | $when |
| Revision | \`$rev\` |
| Machine | $where |
| CPU | $cpu |
| Kernel | $kern |
| Reps | $reps |

> **Trust the ratios more than the milliseconds.** These runs happen on whatever
> machine ran them, usually a shared CI runner, so absolute times move between runs
> and can't be compared across revisions. word's time next to a C program built with
> \`gcc -O2\`, on the same machine in the same run, is what stays comparable. That's
> the column to watch, and the one a regression shows up in.

## word vs C, at a glance

Run time, peak memory and artifact size, each as word's figure divided by C's. Lower
is better, and 1.00 means word matched a \`gcc -O2\` binary. Run time is the median
of the reps. n/a means there's no C figure to compare with. \`mapbench\` has no C
version (C's standard library has no hash map), and neither do the JSON and net
ones, which are compared with Go, Python and Node instead, since a JSON parser or
an HTTPS client written in C from scratch would be a different exercise.

| benchmark | word | C | word ÷ C | peak RSS, word ÷ C | size, word ÷ C |
|---|---|---|---|---|---|
EOF

awk -F, '
  NR == 1 { next }
  $12 != "ok" { next }
  # $6 is the median, $11 peak RSS and $4 artifact bytes. The columns next to
  # them are the other spread figures, and an off-by-one gives a plausible ratio
  # with no error. The median is used instead of $5 (the minimum) for the
  # reasons under "How to read the five timing columns" below.
  { run[$1 "," $2] = $6; rss[$1 "," $2] = $11; sz[$1 "," $2] = $4
    if (!seen[$1]++) order[++n] = $1 }
  END {
    for (i = 1; i <= n; i++) {
      b = order[i]
      w = run[b ",word"]; c = run[b ",c"]
      if (w == "") continue
      if (c == "") { printf "| `%s` | %s ms | n/a | n/a | n/a | n/a |\n", b, w; continue }
      rr = (c > 0) ? sprintf("%.2f×", w / c) : "n/a"
      mm = (rss[b ",c"] > 0) ? sprintf("%.2f×", rss[b ",word"] / rss[b ",c"]) : "n/a"
      ss = (sz[b ",c"] > 0) ? sprintf("%.2f×", sz[b ",word"] / sz[b ",c"]) : "n/a"
      printf "| `%s` | %s ms | %s ms | **%s** | %s | %s |\n", b, w, c, rr, mm, ss
    }
  }' "$csv"

echo ""
echo "## Every language, every benchmark"
echo ""
echo "No rep is thrown away, so each row shows where the runs landed as well as the"
echo "typical one. \`peak_rss_KB\` is the peak across the whole set. \`build_ms\` is one"
echo "build of a single file (Go's is timed after a warm-up build, so it's lower than a"
echo "cold one, and Python and Node have no build). A missing row means that language"
echo "has no version of the benchmark, or its toolchain wasn't installed on the machine"
echo "that measured. Every comparison toolchain is dev-only, and none of them is needed"
echo "to build or run word."
echo ""
echo "How to read the five timing columns:"
echo ""
echo "- **median** is the middle rep, and it's what the ratios above are computed from."
echo "  Half the reps were faster and half slower, so one rep slowed by whatever else"
echo "  the machine was doing doesn't move it, and neither does taking more reps."
echo "- **min** is the fastest rep, the best case the machine allowed. It's biased low,"
echo "  since it's the single luckiest run and it drops as the rep count rises, so it"
echo "  sits beside the median instead of replacing it. Far below the median means the"
echo "  machine was noisy and the absolute times are worth less."
echo "- **p95** is nearest-rank over the reps. At ten reps that's the slowest run and"
echo "  nothing more. It's here to show the tail, not to estimate one."
echo "- **stddev** is the sample standard deviation across the reps: how far they"
echo "  spread. It describes this run's noise. It isn't a significance test, and at ten"
echo "  reps nothing on this page can establish that a difference is real. A gap"
echo "  between two languages that's small next to either one's spread hasn't been"
echo "  shown."
echo "- **first** is the first rep of the set, whose page-cache and dynamic-loader"
echo "  state differ from the rest. It isn't a true cold start, since the binary was"
echo "  built moments earlier."
echo ""

awk -F, '
  NR == 1 { next }
  { if (!seen[$1]++) order[++n] = $1
    row[$1] = row[$1] sprintf("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n",
                              $2, $3, $4, $6, $5, $7, $8, $9, $11, $12) }
  END {
    for (i = 1; i <= n; i++) {
      b = order[i]
      printf "### %s\n\n", b
      print "| language | build_ms | artifact_B | median | min | p95 | stddev | first | peak_rss_KB | |"
      print "|---|---|---|---|---|---|---|---|---|---|"
      printf "%s\n", row[b]
    }
  }' "$csv"

if [ -f "$here/compilespeed.txt" ]; then
  echo "## Compile speed"
  echo ""
  echo "The compiler's own throughput, on generated sources and on itself. word"
  echo "compiles, assembles and links in one process, with its own assembler and"
  echo "linker, and there's no LLVM in the path."
  echo ""
  echo '```'
  cat "$here/compilespeed.txt"
  echo '```'
  echo ""
fi

if [ -f "$here/scaling.txt" ]; then
  echo "## Scaling guards"
  echo ""
  echo "The shapes that mustn't go quadratic: \`sort\` and a join chain in time, and"
  echo "\`copy\` in a loop, which has to stay flat in memory."
  echo "\`dev/toolchain/test_sort_scaling.sh\`, \`test_append_scaling.sh\` and"
  echo "\`test_slice_scaling.sh\` hold the same shapes to a bound (and"
  echo "\`test_compile_scaling.sh\` does it for the compiler), and \`ci.yml\` runs them,"
  echo "so a regression fails those suites as well as showing up here."
  echo ""
  echo '```'
  cat "$here/scaling.txt"
  echo '```'
  echo ""
fi

if [ -f "$envf" ]; then
  echo "## The machine, and which compilers these ratios are against"
  echo ""
  echo "\"word is 1.2x C\" isn't a claim until it says which C. This is what"
  echo "\`bench.sh\` recorded about its own run, written next to \`results.csv\` as it"
  echo "measured, so it describes the machine these numbers came from and not"
  echo "whichever machine rendered the page."
  echo ""
  echo '```'
  cat "$envf"
  echo '```'
  echo ""
fi

cat <<'EOF'
## Reproducing this

```sh
sh dev/benchmarks/bench.sh          # -> dev/benchmarks/results.csv (+ the table above)
sh dev/benchmarks/compilespeed.sh   # -> dev/benchmarks/compilespeed.txt
sh dev/benchmarks/scaling.sh        # -> dev/benchmarks/scaling.txt
sh dev/benchmarks/mkperf.sh         # -> docs/PERFORMANCE.md
```

`bench.sh` runs each program ten times in each language and skips any comparison
language it can't find. The whole suite takes a few minutes. `REPS=3 sh
dev/benchmarks/bench.sh fib` narrows it to one benchmark with fewer reps, though
with three reps the spread columns don't mean much. It also writes
`dev/benchmarks/environment.txt`, which is the block above.

Nothing in `dev/benchmarks/` is needed to build or run word. gcc, g++, rustc, go,
python3 and node are dev-only, like GNU `as` and `openssl` elsewhere in the tree.
EOF
} > "$out"

echo "mkperf: wrote $out"
