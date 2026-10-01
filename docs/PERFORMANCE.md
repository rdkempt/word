# Performance

How fast `word` is, measured. This page is generated: `dev/benchmarks/mkperf.sh`
renders it from the numbers `dev/benchmarks/bench.sh`, `compilespeed.sh` and
`scaling.sh` produce, and `.github/workflows/bench.yml` is set up to regenerate it
on every push to `main`. Don't edit it by hand, since the next run overwrites it.
The Measured and Revision rows say which run these numbers came from.

| | |
|---|---|
| Measured | 2026-09-24 19:35 UTC |
| Revision | `b3a2487` |
| Machine | a developer machine |
| CPU | Intel(R) Core(TM) Ultra 9 275HX (24 cores) |
| Kernel | Linux 6.6.87.2-microsoft-standard-WSL2 |
| Reps | 10 per benchmark per language |

> **Trust the ratios more than the milliseconds.** These runs happen on whatever
> machine ran them, usually a shared CI runner, so absolute times move between runs
> and can't be compared across revisions. word's time next to a C program built with
> `gcc -O2`, on the same machine in the same run, is what stays comparable. That's
> the column to watch, and the one a regression shows up in.

## word vs C, at a glance

Run time, peak memory and artifact size, each as word's figure divided by C's. Lower
is better, and 1.00 means word matched a `gcc -O2` binary. Run time is the median
of the reps. n/a means there's no C figure to compare with. `mapbench` has no C
version (C's standard library has no hash map), and neither do the JSON and net
ones, which are compared with Go, Python and Node instead, since a JSON parser or
an HTTPS client written in C from scratch would be a different exercise.

| benchmark | word | C | word ÷ C | peak RSS, word ÷ C | size, word ÷ C |
|---|---|---|---|---|---|
| `hello` | 0.213 ms | 0.379 ms | **0.56×** | 0.57× | 1.28× |
| `fib` | 6.263 ms | 1.981 ms | **3.16×** | 0.50× | 1.28× |
| `sieve` | 43.076 ms | 27.815 ms | **1.55×** | 1.04× | 1.28× |
| `mandelbrot` | 8.839 ms | 8.465 ms | **1.04×** | 0.50× | 1.54× |
| `vecmath` | 2.697 ms | 1.258 ms | **2.14×** | 0.50× | 1.54× |
| `strbuild` | 1.680 ms | 0.718 ms | **2.34×** | 1.45× | 1.27× |
| `strchain` | 6.049 ms | 4.629 ms | **1.31×** | 5.01× | 1.27× |
| `slicebench` | 9.948 ms | 7.660 ms | **1.30×** | 0.50× | 1.28× |
| `sortints` | 1.175 ms | 4.322 ms | **0.27×** | 0.57× | 1.27× |
| `mapbench` | 55.077 ms | n/a | n/a | n/a | n/a |
| `jsonbench` | 21.593 ms | n/a | n/a | n/a | n/a |
| `nethttp` | 86.489 ms | n/a | n/a | n/a | n/a |
| `nethttps` | 50.395 ms | n/a | n/a | n/a | n/a |

## Every language, every benchmark

No rep is thrown away, so each row shows where the runs landed as well as the
typical one. `peak_rss_KB` is the peak across the whole set. `build_ms` is one
build of a single file (Go's is timed after a warm-up build, so it's lower than a
cold one, and Python and Node have no build). A missing row means that language
has no version of the benchmark, or its toolchain wasn't installed on the machine
that measured. Every comparison toolchain is dev-only, and none of them is needed
to build or run word.

How to read the five timing columns:

- **median** is the middle rep, and it's what the ratios above are computed from.
  Half the reps were faster and half slower, so one rep slowed by whatever else
  the machine was doing doesn't move it, and neither does taking more reps.
- **min** is the fastest rep, the best case the machine allowed. It's biased low,
  since it's the single luckiest run and it drops as the rep count rises, so it
  sits beside the median instead of replacing it. Far below the median means the
  machine was noisy and the absolute times are worth less.
- **p95** is nearest-rank over the reps. At ten reps that's the slowest run and
  nothing more. It's here to show the tail, not to estimate one.
- **stddev** is the sample standard deviation across the reps: how far they
  spread. It describes this run's noise. It isn't a significance test, and at ten
  reps nothing on this page can establish that a difference is real. A gap
  between two languages that's small next to either one's spread hasn't been
  shown.
- **first** is the first rep of the set, whose page-cache and dynamic-loader
  state differ from the rest. It isn't a true cold start, since the binary was
  built moments earlier.

### hello

| language | build_ms | artifact_B | median | min | p95 | stddev | first | peak_rss_KB | |
|---|---|---|---|---|---|---|---|---|---|
| word | 7 | 20480 | 0.213 | 0.191 | 0.282 | 0.026 | 0.223 | 768 | ok |
| c | 89 | 15952 | 0.379 | 0.328 | 0.447 | 0.035 | 0.380 | 1344 | ok |
| cpp | 124 | 15952 | 0.353 | 0.330 | 0.443 | 0.038 | 0.443 | 1344 | ok |
| go | 55 | 2397238 | 0.984 | 0.868 | 1.334 | 0.133 | 0.972 | 2112 | ok |
| python | 0 | 26 | 6.559 | 6.031 | 18.384 | 3.775 | 18.384 | 8448 | ok |
| node | 0 | 33 | 48.230 | 46.050 | 107.405 | 18.846 | 107.405 | 52636 | ok |

### fib

| language | build_ms | artifact_B | median | min | p95 | stddev | first | peak_rss_KB | |
|---|---|---|---|---|---|---|---|---|---|
| word | 6 | 20480 | 6.263 | 5.792 | 6.543 | 0.260 | 6.353 | 768 | ok |
| c | 84 | 15984 | 1.981 | 1.880 | 2.198 | 0.127 | 2.198 | 1536 | ok |
| cpp | 109 | 15984 | 2.023 | 1.880 | 2.174 | 0.091 | 2.127 | 1536 | ok |
| go | 46 | 2397295 | 6.949 | 6.513 | 7.424 | 0.265 | 6.943 | 2112 | ok |
| python | 0 | 122 | 139.002 | 134.945 | 142.323 | 2.416 | 141.747 | 8448 | ok |
| node | 0 | 86 | 61.942 | 59.043 | 67.080 | 2.791 | 66.813 | 57820 | ok |

### sieve

| language | build_ms | artifact_B | median | min | p95 | stddev | first | peak_rss_KB | |
|---|---|---|---|---|---|---|---|---|---|
| word | 6 | 20480 | 43.076 | 42.204 | 45.882 | 1.319 | 42.204 | 11824 | ok |
| c | 84 | 16008 | 27.815 | 26.272 | 29.960 | 1.189 | 26.825 | 11328 | ok |
| cpp | 170 | 16400 | 30.148 | 29.190 | 32.727 | 1.117 | 29.890 | 13248 | ok |
| go | 47 | 2397318 | 29.684 | 28.354 | 31.114 | 0.833 | 29.653 | 12480 | ok |
| python | 0 | 414 | 902.272 | 870.562 | 1483.636 | 186.460 | 932.936 | 18240 | ok |
| node | 0 | 220 | 88.142 | 83.525 | 91.396 | 2.679 | 91.396 | 68760 | ok |

### mandelbrot

| language | build_ms | artifact_B | median | min | p95 | stddev | first | peak_rss_KB | |
|---|---|---|---|---|---|---|---|---|---|
| word | 7 | 24576 | 8.839 | 8.743 | 9.370 | 0.240 | 8.743 | 768 | ok |
| c | 76 | 15960 | 8.465 | 8.083 | 8.796 | 0.250 | 8.184 | 1536 | ok |
| cpp | 105 | 15960 | 8.344 | 7.980 | 8.878 | 0.316 | 8.653 | 1536 | ok |
| go | 55 | 2397536 | 9.142 | 8.589 | 9.642 | 0.383 | 9.100 | 2112 | ok |
| python | 0 | 443 | 558.501 | 542.512 | 601.268 | 16.935 | 573.172 | 8640 | ok |
| node | 0 | 444 | 59.163 | 55.906 | 62.401 | 1.665 | 58.178 | 60888 | ok |

### vecmath

| language | build_ms | artifact_B | median | min | p95 | stddev | first | peak_rss_KB | |
|---|---|---|---|---|---|---|---|---|---|
| word | 7 | 24576 | 2.697 | 2.427 | 3.001 | 0.176 | 3.001 | 768 | ok |
| c | 82 | 15960 | 1.258 | 1.201 | 1.541 | 0.095 | 1.289 | 1536 | ok |
| cpp | 85 | 15960 | 1.306 | 1.229 | 1.555 | 0.114 | 1.261 | 1536 | ok |
| go | 53 | 2397404 | 2.557 | 2.389 | 2.964 | 0.182 | 2.577 | 2112 | ok |
| python | 0 | 166 | 276.171 | 266.764 | 293.617 | 8.482 | 275.555 | 8448 | ok |
| node | 0 | 207 | 52.978 | 49.920 | 54.996 | 1.744 | 53.722 | 58588 | ok |

### strbuild

| language | build_ms | artifact_B | median | min | p95 | stddev | first | peak_rss_KB | |
|---|---|---|---|---|---|---|---|---|---|
| word | 6 | 20480 | 1.680 | 1.417 | 2.009 | 0.186 | 1.666 | 3072 | ok |
| c | 80 | 16064 | 0.718 | 0.671 | 0.964 | 0.105 | 0.671 | 2112 | ok |
| cpp | 199 | 16552 | 1.419 | 1.315 | 1.800 | 0.175 | 1.800 | 4032 | ok |
| go | 44 | 2397614 | 2.103 | 1.925 | 2.269 | 0.112 | 2.183 | 4224 | ok |
| python | 0 | 148 | 27.352 | 25.696 | 30.407 | 1.551 | 25.696 | 10560 | ok |
| node | 0 | 215 | 53.793 | 51.823 | 55.372 | 1.289 | 55.070 | 65324 | ok |

### strchain

| language | build_ms | artifact_B | median | min | p95 | stddev | first | peak_rss_KB | |
|---|---|---|---|---|---|---|---|---|---|
| word | 6 | 20480 | 6.049 | 5.065 | 7.521 | 0.754 | 7.521 | 15384 | ok |
| c | 93 | 16096 | 4.629 | 4.423 | 5.184 | 0.271 | 4.423 | 3072 | ok |
| cpp | 193 | 16832 | 6.308 | 5.937 | 6.564 | 0.198 | 6.386 | 5088 | ok |
| go | 52 | 2397830 | 7.978 | 7.624 | 8.936 | 0.444 | 8.446 | 9600 | ok |
| python | 0 | 162 | 87.136 | 77.104 | 92.462 | 5.908 | 87.750 | 22464 | ok |
| node | 0 | 224 | 75.800 | 71.248 | 82.013 | 3.331 | 77.495 | 81344 | ok |

### slicebench

| language | build_ms | artifact_B | median | min | p95 | stddev | first | peak_rss_KB | |
|---|---|---|---|---|---|---|---|---|---|
| word | 6 | 20480 | 9.948 | 9.794 | 10.886 | 0.394 | 9.839 | 1536 | ok |
| c | 101 | 16056 | 7.660 | 7.239 | 8.131 | 0.340 | 7.976 | 3072 | ok |
| cpp | 178 | 16512 | 8.627 | 8.420 | 9.509 | 0.316 | 8.508 | 4992 | ok |
| go | 63 | 2397342 | 7.787 | 7.361 | 8.208 | 0.288 | 7.419 | 3648 | ok |
| python | 0 | 185 | 190.743 | 178.169 | 209.107 | 8.662 | 209.107 | 10176 | ok |
| node | 0 | 268 | 84.273 | 80.619 | 91.437 | 3.154 | 86.603 | 68956 | ok |

### sortints

| language | build_ms | artifact_B | median | min | p95 | stddev | first | peak_rss_KB | |
|---|---|---|---|---|---|---|---|---|---|
| word | 6 | 20480 | 1.175 | 1.103 | 1.444 | 0.096 | 1.444 | 1152 | ok |
| c | 75 | 16088 | 4.322 | 4.081 | 4.766 | 0.228 | 4.127 | 2024 | ok |
| cpp | 217 | 17008 | 3.223 | 2.919 | 4.422 | 0.452 | 3.248 | 3840 | ok |
| go | 44 | 2423030 | 5.092 | 4.656 | 5.348 | 0.222 | 4.802 | 2688 | ok |
| python | 0 | 147 | 17.532 | 16.649 | 18.904 | 0.692 | 18.360 | 10944 | ok |
| node | 0 | 264 | 63.276 | 61.493 | 66.873 | 1.882 | 63.596 | 65084 | ok |

### mapbench

| language | build_ms | artifact_B | median | min | p95 | stddev | first | peak_rss_KB | |
|---|---|---|---|---|---|---|---|---|---|
| word | 7 | 28672 | 55.077 | 53.216 | 68.138 | 4.354 | 68.138 | 72920 | ok |
| cpp | 267 | 18000 | 169.767 | 160.182 | 179.099 | 5.246 | 174.830 | 40212 | ok |
| go | 64 | 2397486 | 140.480 | 131.266 | 144.753 | 4.883 | 143.739 | 52416 | ok |
| python | 0 | 140 | 181.659 | 173.694 | 197.190 | 6.876 | 185.786 | 62788 | ok |
| node | 0 | 183 | 234.094 | 219.729 | 245.433 | 10.705 | 242.552 | 118052 | ok |

### jsonbench

| language | build_ms | artifact_B | median | min | p95 | stddev | first | peak_rss_KB | |
|---|---|---|---|---|---|---|---|---|---|
| word | 8 | 32768 | 21.593 | 20.272 | 34.879 | 4.792 | 29.145 | 78224 | ok |
| go | 58 | 3132494 | 43.587 | 43.114 | 45.231 | 0.668 | 44.226 | 26688 | ok |
| python | 0 | 376 | 32.281 | 29.676 | 42.963 | 3.655 | 42.963 | 22716 | ok |
| node | 0 | 384 | 62.745 | 60.949 | 65.849 | 1.532 | 64.306 | 70808 | ok |

### nethttp

| language | build_ms | artifact_B | median | min | p95 | stddev | first | peak_rss_KB | |
|---|---|---|---|---|---|---|---|---|---|
| word | 104 | 421888 | 86.489 | 83.236 | 89.903 | 1.956 | 86.089 | 66976 | ok |
| go | 58 | 8549481 | 44.373 | 42.853 | 50.499 | 2.144 | 50.499 | 13796 | ok |
| python | 0 | 163 | 65.953 | 63.873 | 77.020 | 4.136 | 77.020 | 22656 | ok |
| node | 0 | 435 | 128.482 | 122.814 | 132.586 | 3.205 | 132.267 | 66864 | ok |

### nethttps

| language | build_ms | artifact_B | median | min | p95 | stddev | first | peak_rss_KB | |
|---|---|---|---|---|---|---|---|---|---|
| word | 115 | 421888 | 50.395 | 49.139 | 60.692 | 3.322 | 60.692 | 16912 | ok |
| go | 61 | 8548648 | 30.145 | 28.847 | 30.962 | 0.631 | 30.162 | 13056 | ok |
| python | 0 | 226 | 57.932 | 56.595 | 58.762 | 0.849 | 58.632 | 22080 | ok |
| node | 0 | 481 | 107.343 | 105.014 | 112.509 | 2.494 | 111.370 | 63964 | ok |

## Compile speed

The compiler's own throughput, on generated sources and on itself. word
compiles, assembles and links in one process, with its own assembler and
linker, and there's no LLVM in the path.

```
4000 chained functions per source

language      lines   build_ms   artifact_B      lines/sec
word           8001        104       360448          76933
c              4002       1212        15952           3302
c0             4002        572       454328           6997
go             4006        381      2810937          10514

== word compiling its own 46910-line toolchain (compile+assemble+link) ==
word.w        46910        547      5402624          85759
```

## Scaling guards

The shapes that mustn't go quadratic: `sort` and a join chain in time, and
`copy` in a loop, which has to stay flat in memory.
`dev/toolchain/test_sort_scaling.sh`, `test_append_scaling.sh` and
`test_slice_scaling.sh` hold the same shapes to a bound (and
`test_compile_scaling.sh` does it for the compiler), and `ci.yml` runs them,
so a regression fails those suites as well as showing up here.

```
== sort(region): time vs n (expect ~2x per doubling: n log n) ==
         n         ms     rss_KB
     50000        1.2       1152
    100000        2.0       2304
    200000        3.8       4608
    400000        7.2      11020

== s = s . "a" . "b"  (left-nested chain) vs n (expect flat) ==
         n         ms     rss_KB
      2000        0.2        576
      4000        0.2        576
      8000        0.6        576
     16000        0.3        576

== s = s . ("a" . "b")  (right-associated; misses the in-place append) ==
         n         ms     rss_KB
      2000        0.3        576
      4000        0.3        576
      8000        0.4        576
     16000        0.6       1152
    320000        7.9      30892

== t = copy(s, j, j + 64) in a loop vs n (expect flat rss) ==
         n         ms     rss_KB
    250000        2.7        576
    500000        5.2        576
   1000000        9.9        576
   2000000       17.9        576
   4000000       36.6        768
```

## The machine, and which compilers these ratios are against

"word is 1.2x C" isn't a claim until it says which C. This is what
`bench.sh` recorded about its own run, written next to `results.csv` as it
measured, so it describes the machine these numbers came from and not
whichever machine rendered the page.

```
measured    2026-09-24 19:35 UTC
revision    b3a2487
machine     a developer machine
cpu         Intel(R) Core(TM) Ultra 9 275HX (24 cores)
kernel      Linux 6.6.87.2-microsoft-standard-WSL2
reps        10 per benchmark per language

gcc         gcc (Debian 15.2.0-7) 15.2.0
g++         g++ (Debian 15.2.0-7) 15.2.0
rustc       (absent, skipped)
go          go version go1.26.4 linux/amd64
python3     Python 3.13.12
node        v24.15.0
```

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
