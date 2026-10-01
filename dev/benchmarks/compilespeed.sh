#!/bin/sh
# compilespeed.sh: compiler throughput on the same generated work in each
# language, N chained functions compiled to a native binary. It measures the
# toolchain, not the program (nothing is run).
#
# word's build is compile, assemble and link in one process with no external
# as/ld, so its number is the whole pipeline.
#
# A row is a measurement only when it has figures. A build that fails gets a
# row that says BUILD FAILED instead and makes this script exit 1, which stops
# bench.yml before it renders or publishes anything. (A failed build used to be
# printed and skipped with exit 0, and a word self-build that died at once went
# onto the page as a time.) A comparison toolchain that isn't installed is
# skipped, as in bench.sh; one that's installed and fails is a failure.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}
N=${N:-4000}
# bench.yml sends stdout to compilespeed.txt, so whatever its log should show
# goes to stderr.
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
have() { command -v "$1" >/dev/null 2>&1; }
# millis <cmd...>: runs a build, echoes its wall time in ms and returns its
# status. What the build said on stderr is left in $tmp/err.
millis() { s=$(date +%s%N); "$@" >/dev/null 2>"$tmp/err"; rc=$?; e=$(date +%s%N)
           echo $(( (e - s) / 1000000 )); return $rc; }
# build_failed <name> <lines>: the row a build gets when it failed. It fails the
# run, and goes to stderr too with the start of the compiler's error: the source
# it was given is deleted with $tmp, so that's all the log will have.
failed=""
build_failed() {
    printf "%-8s %10s   BUILD FAILED\n" "$1" "$2"
    { echo "compilespeed.sh: $1: BUILD FAILED"; head -3 "$tmp/err" | sed 's/^/    /'; } >&2
    failed="$failed $1"
}

awk -v n="$N" 'BEGIN{
  print "f0(a, b)"; print "    return a + b";
  for(i=1;i<n;i++){ printf "f%d(a, b)\n", i; printf "    return f%d(a, b) + %d\n", i-1, i%7 }
  printf "out(f%d(1, 2))\n", n-1 }' > "$tmp/p.w"
awk -v n="$N" 'BEGIN{
  print "#include <stdio.h>";
  print "static long f0(long a, long b){ return a + b; }";
  for(i=1;i<n;i++) printf "static long f%d(long a, long b){ return f%d(a,b) + %d; }\n", i, i-1, i%7;
  printf "int main(void){ printf(\"%%ld\\n\", f%d(1,2)); return 0; }\n", n-1 }' > "$tmp/p.c"
awk -v n="$N" 'BEGIN{
  print "fn f0(a: i64, b: i64) -> i64 { a + b }";
  for(i=1;i<n;i++) printf "fn f%d(a: i64, b: i64) -> i64 { f%d(a,b) + %d }\n", i, i-1, i%7;
  printf "fn main(){ println!(\"{}\", f%d(1,2)); }\n", n-1 }' > "$tmp/p.rs"
awk -v n="$N" 'BEGIN{
  print "package main"; print ""; print "import \"fmt\""; print "";
  print "func f0(a, b int64) int64 { return a + b }";
  for(i=1;i<n;i++) printf "func f%d(a, b int64) int64 { return f%d(a,b) + %d }\n", i, i-1, i%7;
  printf "func main(){ fmt.Println(f%d(1,2)) }\n", n-1 }' > "$tmp/p.go"
# Go caches build results by source content, so a warm-up run with the same
# input would make the measured build a cache hit. A unique trailing comment
# forces a real compile of the package and leaves the stdlib cache alone.
echo "// build-id $$ $(date +%s%N)" >> "$tmp/p.go"

printf "%d chained functions per source\n\n" "$N"
printf "%-8s %10s %10s %12s %14s\n" language lines build_ms artifact_B "lines/sec"
for lang in word c c0 rust go; do
  case $lang in
    word) src="$tmp/p.w";  cmd="$WORD build $src -o $tmp/out" ;;
    c)    have gcc || continue;   src="$tmp/p.c";  cmd="gcc -O2 $src -o $tmp/out" ;;
    c0)   have gcc || continue;   src="$tmp/p.c";  cmd="gcc -O0 $src -o $tmp/out" ;;
    rust) have rustc || continue; src="$tmp/p.rs"; cmd="rustc -O -o $tmp/out $src" ;;
    go)   have go || continue;    src="$tmp/p.go"; cmd="go build -o $tmp/out $src" ;;
  esac
  lines=$(wc -l < "$src" | tr -d ' ')
  ms=$(millis $cmd) || { build_failed "$lang" "$lines"; continue; }
  size=$(wc -c < "$tmp/out" 2>/dev/null | tr -d ' ')
  lps=$(awk -v l="$lines" -v m="$ms" 'BEGIN{ printf "%.0f", (m>0)? l*1000/m : 0 }')
  printf "%-8s %10s %10s %12s %14s\n" "$lang" "$lines" "$ms" "$size" "$lps"
done

echo ""
# The size is read, not typed: a typed size here once said 11.5k while the row
# beneath it printed 29,131. It counts the whole file, the NETLIB text included.
wlines=$(wc -l < "$root/compiler/word.w" | tr -d ' ')
echo "== word compiling its own ${wlines}-line toolchain (compile+assemble+link) =="
if ms=$(millis "$WORD" build "$root/compiler/word.w" -o "$tmp/word.rebuilt"); then
  printf "word.w   %10s %10s %12s %14s\n" "$wlines" "$ms" \
      "$(wc -c < "$tmp/word.rebuilt" | tr -d ' ')" \
      "$(awk -v l="$wlines" -v m="$ms" 'BEGIN{printf "%.0f", (m>0)? l*1000/m : 0}')"
else
  build_failed word.w "$wlines"
fi

if [ -n "$failed" ]; then
  echo "compilespeed.sh: FAIL:$failed; nothing from this run is a number to publish" >&2
  exit 1
fi
