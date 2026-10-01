# benchmarks

The same thirteen programs, written in `word` and in up to six other languages, plus `scaling.sh`,
which checks how three operations grow as n doubles, and `compilespeed.sh`, which measures how fast
the compiler builds.

Nothing here is needed to build or run `word`. `gcc`, `g++`, `rustc`, `go`, `python3` and `node` are
dev-only, the same way `as` and `openssl` are elsewhere in this repo. If one is missing, its rows are
skipped and nothing fails.

## Running

```sh
sh dev/benchmarks/bench.sh                 # everything, 10 reps each
REPS=3 sh dev/benchmarks/bench.sh fib      # one benchmark, fewer reps
sh dev/benchmarks/scaling.sh               # how sort, a join chain and copy grow with n
sh dev/benchmarks/compilespeed.sh          # compiler throughput
```

`bench.sh` builds each variant (recording the build time and the size of what it built), runs it
`REPS` times, checks that every language printed the same answer, and writes `results.csv` and
`environment.txt`.

A row is a measurement only when its last column says `ok`. Anything else says why it isn't:

- `BUILD FAILED`.
- `FAILED(...)`: a run exited non-zero (the row carries the program's first line of complaint), or
  its answer changed between reps.
- `MISMATCH(...)`: its answer differs from the first language's (word's, unless word failed), so the
  programs aren't computing the same thing.

Any of these makes `bench.sh` exit 1, and so does a named benchmark with no folder or a `gen.w` that
fails. In `bench.yml` that stops the job before it renders or pushes anything. A benchmark whose
`setup.sh` can't start what it needs (the net ones, without `python3` or `openssl`) is skipped
instead of failed, and it's named again at the end of the run, since it has no rows at all.

Timing and peak RSS come from `runstat.c`, a 22-line `fork`/`wait4` wrapper, because GNU `time(1)`
isn't installed everywhere.

`compilespeed.sh` and `scaling.sh` follow the same rule. A build that fails is a `BUILD FAILED` row
in either one. In `scaling.sh`, a run that exits non-zero or is killed is `FAILED(exit N: ...)`, with
the program's first line of complaint (`runstat` reports a signal as 128 plus its number, so a crash
counts as a failed run and not a fast one). A run that exits 0 is held to its answer: each program
prints a number the script works out without word (the length a join chain reaches, the smallest
value the sort puts first, the sum the copy loop adds up), and anything else is
`MISMATCH(printed X, want Y)`. There's no second language in `scaling.sh` to disagree with it, and a
loop miscompiled into running no times would be fast and flat, which is the shape those tables are
read for. Without these checks, a program that faulted straight away would go onto the page as a
small, flat row. Any of them makes the script exit 1 and stops the same job. `bench.yml` sends both
scripts' stdout to `compilespeed.txt` and `scaling.txt`, so each failure is also written to stderr,
where the job log shows it, with the start of the compiler's complaint when a build failed. A
comparison toolchain `compilespeed.sh` can't find is skipped, as in `bench.sh`, and one that's
installed and fails is a failure.

### What each row carries

Every rep counts, not just the best, and the headline is the median. A single number can't tell you
whether a 5% gap between two languages is a result or sits inside the run-to-run spread, so each row
also shows where the runs landed:

| Column | What it is | What it's for |
|---|---|---|
| `run_ms` | the fastest rep | the best case the machine allowed. It's biased low (it's the single luckiest rep, and it drops as the rep count rises), so it sits beside the median instead of replacing it. Far below the median means the machine was noisy and the absolute times are worth less than usual |
| `run_ms_median` | the middle rep | the headline, and what every ratio is computed from. One rep slowed by the machine doesn't move it, and neither does taking more reps |
| `run_ms_p95` | nearest rank, the ceil(0.95n)-th smallest | the tail. At ten reps that's the slowest rep and nothing more. It isn't an estimate of a 95th percentile |
| `run_ms_stddev` | the sample standard deviation (n-1) | how far the reps spread. It describes this run's noise. It isn't a significance test, and at ten reps it can't establish that a difference between two languages is real: a gap that's small next to either one's spread hasn't been shown |
| `run_ms_first` | the first rep of the set | the page cache and the dynamic loader. It isn't a true cold start, since the binary was built moments earlier |
| `reps` | how many runs the five above summarize | so you don't have to take any of them on trust about their sample size |

Two rows from a GitHub Actions run on 2026-09-10 show why the extra columns are there. Node's first
rep of `hello` took 1,852.5 ms against a median of 23.9 ms, and its first rep of `fib`
947.7 ms against 47.8 ms. Best-of-N hides that completely. It's most likely the page cache on a fresh
runner, but the numbers only show that the effect is there, not what causes it. Rust's `mapbench` is
the other kind: its reps ran from 191.4 ms to 231.9 ms with an ordinary first rep of 216.0 ms. That's
most likely the shared machine, not the program, and it's the kind of row whose absolute milliseconds
I wouldn't quote.

### What the numbers are measured against

`environment.txt`, which `bench.sh` writes as it runs, records the CPU, the core count, the kernel,
the revision, the rep count, and the version of every comparison toolchain. The revision is marked
dirty, with the changed files named, when a tracked file other than the ones these scripts regenerate
differs from it (`bench.sh` checks that before it writes anything, since two of the files it writes
are tracked). "word is 1.2x C" isn't a claim until it says which C. `mkperf.sh` puts the file on
`docs/PERFORMANCE.md` next to the ratios it explains, instead of leaving it in a CI log.

## What each one measures

| Benchmark | What it stresses | Languages |
|---|---|---|
| `hello` | process startup, artifact size, floor RSS | all |
| `fib` | function-call overhead, integer arithmetic (naive `fib(32)`) | all |
| `sieve` | array indexing and tight loops, 10^7 flags | all |
| `mandelbrot` | pure floating point, 200x200 grid, 500 iterations | all |
| `strbuild` | region append, 200k two-operand joins then a full scan | all |
| `strchain` | the multi-part join chain `s = s . a . b . c`, 200k times, the shape that has to hit the in-place append path | all |
| `slicebench` | 1.6M short-lived `copy` windows out of a 200k region: throughput, and whether a transient is charged to peak memory | all |
| `sortints` | the built-in `sort` over 50,000 integers | all |
| `mapbench` | hash-map insert + lookup, 500k text keys | all but C (no stdlib hash map) |
| `jsonbench` | parse 1.5 MB of JSON, walk it, re-serialize | word, Go, Python, Node (the only four with JSON built in) |
| `vecmath` | float arithmetic *across a call*, 3M times: what a float costs as a parameter, which every other float benchmark here keeps inside one frame | all |
| `nethttp` | 200 HTTP GETs against a local server, a fresh connection each | word, Go, Python, Node |
| `nethttps` | 20 HTTPS GETs against a local server, a full TLS 1.3 handshake each: word's own TLS stack against Go's `crypto/tls` and the OpenSSL that Python and Node use | word, Go, Python, Node |

The rules the suite follows so the numbers mean something:

- **Same algorithm in every language**, even where it isn't that language's idiom. The scalar
  `sieve` inner loop is what Python would normally write as a slice assignment. `sieve_idiomatic.py`
  sits beside it to show the difference (about 2.6 times faster when I ran both in WSL) without
  letting it into the comparison.
- **Same data.** `jsonbench/gen.w` generates the shared input document, in `word`, so the benchmark
  needs no other language to make its data.
- **Same result, even when the usual mechanism differs.** `slicebench` has every language produce
  its own copy of each window, because that's what word's `copy` is (SPEC 9: it allocates a new
  region). Go and Rust would normally hand back a borrowed view, which is a different and much
  cheaper operation, and a copy timed against a pointer doesn't tell you anything.
- **Same arithmetic.** The `sortints` generator is the Lehmer LCG `x = x * 48271 % 2147483647`
  instead of one with a wider multiplier, because a wider one goes past JavaScript's exact-integer
  range and Node computes a different sequence without any error. (`word`'s integers are 63-bit, so
  word would be fine either way, but the languages wouldn't be sorting the same numbers.)
- **The median is the headline**, not the mean or the best. Half the reps were faster and half
  slower, so a stray slow rep on a shared machine doesn't move it, while the minimum is the single
  luckiest rep and drifts lower the more reps there are. The minimum and the spread are published
  beside it, so you can see when a ratio is inside the noise.

## Caveats

- One machine, one run. `environment.txt` and the top of `docs/PERFORMANCE.md` say which. Trust the
  ratios more than the absolute milliseconds.
- `bench.sh` measures wall time for the whole process, startup included. That's the fair number for
  a scripting language, and it's why `hello` is in the table at all.
- Build times are only roughly cold. Go's build cache is keyed by content, so `compilespeed.sh`
  appends a unique comment to force a real compile of the package while the standard library's cache
  stays warm. `bench.sh` builds each Go program once before the timed build, so its `build_ms` column
  understates a truly cold build.
- Rust and Go put their own runtime and standard library into every binary, debug info included,
  which is most of their size. C and C++ link the shared libc (and libstdc++). `word` links nothing
  at all.

## When the clock and the instruction count disagree

Three times while tuning the compiler, the wall clock gave me a confident wrong answer. Each one
below has the measurement that showed it and the check that catches it.

- **Wall clock on a shared container drifts about 20% between measurement windows.** The same two
  binaries, compared with the same alternating min-of-30 harness, gave `sortints` at +20% in one
  window and -4% in another an hour later. An A/A control (the identical binary as both arms) read
  -0.2% inside each window, so the harness was fair and it was the absolute timings that moved.
  Instruction counts and cachegrind's cache and branch simulation didn't change at all across the
  whole episode, and they said the change was neutral. So I take instruction counts as the primary
  measure, use cache and branch simulation to rule out what an instruction count can't see, and
  treat any wall-clock difference under about 10% as unmeasured unless both arms were sampled in the
  same window and it reproduces across windows. The one known exception is a store and a load in
  different domains, which no static count sees at all (SPEC 14's note on keeping an unboxed double
  in the SSE domain).
- **Where the code lands moves a small program by 5% either way.** Loading a leaf store's value last
  in `sieve` (so `flags[j] = 1` needs no `push`/`pop` around the region and the subscript) took it
  from 916.7M instructions to 871.0M and from 469.4M data references to 423.7M, with identical cache
  and branch simulation results, and it ran 6% slower. Putting 1, 2 or 3 dead statements in front of
  it, which moves the inner loop by a few bytes and changes nothing else, reversed the ranking in all
  three cases. The loop straddled a fetch boundary at one particular offset, and the change was
  neutral or better everywhere else. An alignment sweep is how you tell: shift the code and measure
  again before you believe the clock. (Loop heads are aligned to 16 bytes, which removes the cause.
  SPEC 14 has the numbers.)
- **It moves a large program too, and there padding doesn't help.** This is the cleanest case,
  because the control was exact. Folding five copies of the decimal digit loop into one shared
  `rt_dec_digits`, keeping `div` so the arithmetic didn't change, retired 3,636,093,179 instructions
  compiling `compiler/word.w` against the five-copy version's 3,635,905,660 (187 thousand more in 3.6
  billion) and ran 3.0% slower. Swapping that shared loop's `div` for a reciprocal then made it 1.6%
  faster while adding another 0.9M instructions. The 3% came from where the 720 KB of `.text` (its
  size then) landed, not from what the code does. The compiler is big enough to be bound by the
  instruction cache, which makes it the workload most sensitive to layout and the worst one to tune
  by the clock alone. Unlike `sieve`, padding it by 4 and by 12 bytes didn't move it. A big program's
  layout isn't one fetch boundary you can step past.

## The published page

The write-up, including what the numbers say about the language and not just the machine, is
[`docs/PERFORMANCE.md`](../../docs/PERFORMANCE.md). `mkperf.sh` renders it from `results.csv`,
`compilespeed.txt`, `scaling.txt` and `environment.txt`.

`.github/workflows/bench.yml` keeps it current. On a push to `main` that changes anything
besides the page and the four files it's rendered from (or when started by hand), it runs
`bench.sh`, `compilespeed.sh` and `scaling.sh` on `ubuntu-latest`, renders the page, copies it into
the run summary, and commits the five files back to `main` with `[skip ci]`, so the page carries the
numbers from `main`'s own HEAD. It tries the push three times, and when `main` has moved in between,
it takes the new `main` and writes its numbers over the top. Two runs never overlap, and the job has
a 30-minute timeout. The page's Measured and Revision rows say which run the numbers in the tree
came from.
