#!/bin/sh
# test_bench_harness.sh: the benchmark scripts fail when a benchmark fails.
#
# dev/benchmarks/bench.sh produces the numbers in docs/PERFORMANCE.md. It used
# to exit 0 whatever happened: a failed build was a printed word, and a failed
# run became a row marked `ok` that the other languages were then checked
# against. When #204 broke nethttps, word's row read `ok` and the three clients
# that were right read MISMATCH.
#
# Each way a benchmark can go wrong is built here as a benchmark of its own (a
# word program and a C twin), run by a scratch copy of bench.sh. The checks
# read the exit code and the label in the row's last column, not the text it
# prints. Two outcomes that aren't failures are checked too: a clean run (every
# row `ok`, exit 0), and a setup.sh that can't start what it needs (a skip).
#
# Then the revision line in environment.txt. bench.sh has to work it out
# before it rewrites results.csv and environment.txt, which are tracked, or
# every run is labelled a "dirty tree", even on a clean CI checkout.
#
# Then bench.sh's two siblings, whose tables bench.yml publishes too.
# compilespeed.sh used to print BUILD FAILED and exit 0, and never checked
# whether word compiling itself worked. scaling.sh read neither a run's exit
# status nor its output, so a program that faulted at once, or did none of its
# work, gave a small flat row. Both generate the programs they measure, so the
# fixtures come in through what they run: the word they're given (a stand-in
# that swaps in a fixture program and is otherwise the real compiler), the
# comparison compilers on PATH (stand-ins too, so what's installed here doesn't
# decide a case), and the scratch root's compiler/word.w, which compilespeed.sh
# has word compile as its own source.
#
# bench.sh needs a C compiler (for runstat) and git (for the revision). Nothing
# here pipes into a helper: a helper on the right of a pipe runs in a subshell,
# and its counts would be lost.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
for t in cc gcc git; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: this suite needs $t"; exit 1; }
done
# The scratch tree isn't a git checkout until this suite makes it one, so git
# mustn't find a repository above it that the temp directory happens to be in.
GIT_CEILING_DIRECTORIES=$tmp; export GIT_CEILING_DIRECTORIES

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1 -- $2"; }

# Copy the three scripts and runstat.c to where they expect to be, so their
# `here` and `root` resolve inside $tmp/r and nothing in this checkout is
# written.
R="$tmp/r"; B="$R/dev/benchmarks"
mkdir -p "$B" "$R/compiler"
cp "$root/dev/benchmarks/bench.sh" "$root/dev/benchmarks/compilespeed.sh" \
   "$root/dev/benchmarks/scaling.sh" "$root/dev/benchmarks/runstat.c" "$B/"

# mk <benchmark> <word source> <C source>: one benchmark folder.
mk() { mkdir -p "$B/$1"; printf '%s\n' "$2" > "$B/$1/$1.w"; printf '%s\n' "$3" > "$B/$1/$1.c"; }
C42='#include <stdio.h>
int main(void) { printf("42\n"); return 0; }'
C43='#include <stdio.h>
int main(void) { printf("43\n"); return 0; }'
# A different answer on every run: the process id.
CPID='#include <stdio.h>
#include <unistd.h>
int main(void) { printf("%ld\n", (long)getpid()); return 0; }'

mk good      'out(6 * 7)' "$C42"
mk runfail   'x = array(1)
out(x[5])' "$C42"
mk buildfail 'out(6 *' "$C42"
mk mismatch  'out(6 * 7)' "$C43"
mk unstable  'out(6 * 7)' "$CPID"
mk genfail   'out(6 * 7)' "$C42"
printf 'x = array(1)\nout(x[5])\n' > "$B/genfail/gen.w"
mk noset     'out(6 * 7)' "$C42"
printf 'exit 1\n' > "$B/noset/setup.sh"

# bench <benchmark...>: the scratch bench.sh on those, with three reps (an
# answer that changes shows up on rep 2). Output goes to $tmp/log, the exit
# status to $rc.
bench() { REPS=3 WORD="$WORD" sh "$B/bench.sh" "$@" > "$tmp/log" 2>&1; rc=$?; }
# label <benchmark> <language>: the last column of that row of results.csv.
label() { grep "^$1,$2," "$B/results.csv" | cut -d, -f12-; }
# logged <text>: bench.sh's output said it.
logged() { grep -qF -- "$1" "$tmp/log"; }

echo "== a clean run: every row ok, exit 0 =="
bench good
if [ "$rc" = 0 ] && [ "$(label good word)" = ok ] && [ "$(label good c)" = ok ]; then
  ok "two languages that agree"
else bad "two languages that agree" "rc=$rc, word [$(label good word)], c [$(label good c)]"; fi

echo "== each way a benchmark goes wrong fails the run, and its row says which =="
# fails_with <benchmark> <language> <label prefix> <name>: bench.sh on `good`
# and that benchmark exits 1, the row's label starts with the prefix, and
# `good` beside it is still ok, so one failure doesn't spoil the other rows.
fails_with() {
  bench good "$1"; got=$(label "$1" "$2")
  case "$got" in "$3"*) m=1;; *) m=0;; esac
  if [ "$rc" = 1 ] && [ "$m" = 1 ] && [ "$(label good word)" = ok ]; then ok "$4 [$got]"
  else bad "$4" "rc=$rc, $1/$2 labelled [$got], want [$3...] and exit 1"; fi; }
fails_with runfail   word 'FAILED(exit 70 on rep 1: runfail.w:2: index 5 out of bounds' "a word run that exits 70"
fails_with buildfail word 'BUILD FAILED' "a word build that fails"
fails_with mismatch  c    'MISMATCH(43)' "a C twin with a different answer"
fails_with unstable  c    'FAILED(rep 2 answered differently from rep 1)' "an answer that moves between reps"

bench runfail
if grep -q '^runfail,word,,,,,,,,,,FAILED(' "$B/results.csv"; then ok "a failed row carries no figures"
else bad "a failed row carries no figures" "[$(grep '^runfail,word,' "$B/results.csv")]"; fi
# This is what hid the nethttps failure: the failed word run was taken as the
# answer.
if [ "$(label runfail c)" = ok ]; then ok "the C twin of a failed word run is ok, not a MISMATCH"
else bad "the C twin of a failed word run is ok, not a MISMATCH" "c labelled [$(label runfail c)]"; fi

bench good genfail
if [ "$rc" = 1 ] && logged "gen.w FAILED"; then ok "a gen.w that fails"
else bad "a gen.w that fails" "rc=$rc: $(tail -3 "$tmp/log" | tr '\n' '|')"; fi
bench good nosuch
if [ "$rc" = 1 ] && logged "FAIL nosuch (no such folder)"; then ok "a named benchmark with no folder"
else bad "a named benchmark with no folder" "rc=$rc: $(tail -3 "$tmp/log" | tr '\n' '|')"; fi
bench runfail good
if [ "$rc" = 1 ] && [ "$(label good word)" = ok ]; then ok "a failure fails the run when a pass comes after it"
else bad "a failure fails the run when a pass comes after it" "rc=$rc"; fi

echo "== a setup that cannot start is a skip, and says so =="
bench good noset
if [ "$rc" = 0 ] && logged "skipped    : noset" && [ -z "$(label noset word)" ]; then ok "a skip, with no rows, named at the end"
else bad "a skip, with no rows, named at the end" "rc=$rc: $(tail -3 "$tmp/log" | tr '\n' '|')"; fi

echo "== the revision is asked before bench.sh writes =="
rev_line() { sed -n 's/^revision    //p' "$B/environment.txt"; }
bench good
if [ "$(rev_line)" = "(not a git checkout)" ]; then ok "outside a checkout, it says so"
else bad "outside a checkout, it says so" "revision [$(rev_line)]"; fi
# A checkout in which results.csv and environment.txt are tracked, as in this one.
if ( cd "$R" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm fixture ); then
  head=$(cd "$R" && git rev-parse --short HEAD)
  bench good
  if [ "$rc" = 0 ] && [ "$(rev_line)" = "$head" ]; then ok "a clean checkout reads clean after bench.sh rewrote two tracked files [$(rev_line)]"
  else bad "a clean checkout reads clean" "rc=$rc, revision [$(rev_line)], want [$head]"; fi
  echo '// touched' >> "$B/good/good.w"
  bench good
  if [ "$(rev_line)" = "$head (dirty tree: dev/benchmarks/good/good.w)" ]; then ok "a modified source file is named [$(rev_line)]"
  else bad "a modified source file is named" "revision [$(rev_line)]"; fi
  for x in runfail buildfail mismatch unstable genfail noset; do echo '// touched' >> "$B/$x/$x.w"; done
  bench good
  case "$(rev_line)" in "$head (dirty tree: "*" and 2 more)") ok "seven are five names and a count";;
    *) bad "seven are five names and a count" "revision [$(rev_line)]";; esac
else bad "a scratch checkout" "git init/commit failed"; fi

# ---- the siblings: compilespeed.sh and scaling.sh ---------------------------
# The same two programs as the buildfail and runfail benchmarks above.
printf 'out(6 *\n' > "$tmp/buildfail.w"
printf 'x = array(1)\nout(x[5])\n' > "$tmp/runfail.w"
# word_building <name> <source>: $tmp/<name>, a word that builds <source> in
# place of whatever it's asked to build. The script's generated program is
# swapped for a fixture, and the compiler and the runtime are the real ones.
word_building() {
  src=$2
  cat > "$tmp/$1" <<EOF
#!/bin/sh
while [ \$# -gt 1 ] && [ "\$1" != -o ]; do shift; done
exec "$WORD" build "$src" -o "\$2"
EOF
  chmod +x "$tmp/$1"; }
word_building word-buildfail "$tmp/buildfail.w"
word_building word-runfail   "$tmp/runfail.w"
# Two that exit 0 without their answer: one prints another, one prints nothing.
printf 'out(6 * 7)\n' > "$tmp/answer42.w"
printf 'x = 6 * 7\nif x > 100\n    out(x)\n' > "$tmp/silent.w"
word_building word-answer42  "$tmp/answer42.w"
word_building word-silent    "$tmp/silent.w"
# A program that dies of SIGSEGV, as a miscompiled one would. There's no way
# to make a word program crash, so this one is C, and the word that "builds"
# it copies it.
printf '#include <signal.h>\nint main(void) { raise(SIGSEGV); return 0; }\n' > "$tmp/segv.c"
gcc -O2 "$tmp/segv.c" -o "$tmp/segv"
cat > "$tmp/word-segv" <<EOF
#!/bin/sh
while [ \$# -gt 1 ] && [ "\$1" != -o ]; do shift; done
exec cp "$tmp/segv" "\$2"
EOF
# A word whose first build fails and every later one is its own.
cat > "$tmp/word-once" <<EOF
#!/bin/sh
[ -f "$tmp/once" ] || { touch "$tmp/once"; echo "refused: the first build" >&2; exit 1; }
exec "$WORD" "\$@"
EOF
chmod +x "$tmp/word-segv" "$tmp/word-once"
# Stand-ins for the comparison compilers: in cc-ok a gcc, rustc and go that
# build (each writes its -o target), in cc-badrust a rustc that cannot, and in
# bare the tools compilespeed.sh uses and no compiler at all.
mkdir "$tmp/cc-ok" "$tmp/cc-badrust" "$tmp/bare"
for c in gcc rustc go; do
  printf '#!/bin/sh\nwhile [ $# -gt 1 ] && [ "$1" != -o ]; do shift; done\necho built > "$2"\n' > "$tmp/cc-ok/$c"
done
printf '#!/bin/sh\necho "error: this rustc builds nothing" >&2\nexit 1\n' > "$tmp/cc-badrust/rustc"
chmod +x "$tmp"/cc-ok/* "$tmp/cc-badrust/rustc"
for t in sh awk date dirname head mktemp rm sed tr wc; do ln -s "$(command -v "$t")" "$tmp/bare/$t"; done
# said <text>: the script printed it on stderr. bench.yml sends both scripts'
# stdout to a file, so stderr is all its log shows.
said() { grep -qF -- "$1" "$tmp/err"; }

echo "== compilespeed.sh: a build that fails fails the run; an absent toolchain is a skip =="
# compilespeed <word> <PATH>: the scratch compilespeed.sh on twenty functions,
# with that word and that PATH; its table in $tmp/out, its stderr in $tmp/err,
# its exit status in $rc.
compilespeed() { N=20 WORD="$1" PATH="$2" sh "$B/compilespeed.sh" > "$tmp/out" 2> "$tmp/err"; rc=$?; }
# cs_label <row>: what that row carries after its line count, either its
# figures or the label it got instead. cs_measured <row>: it carries figures,
# all four.
cs_label() { awk -v r="$1" '$1 == r { sub(/^[^ ]+ +[0-9]+ +/, ""); print }' "$tmp/out"; }
cs_measured() { awk -v r="$1" '$1 == r && NF == 5 && ($2 $3 $4 $5) ~ /^[0-9]+$/ { f = 1 } END { exit !f }' "$tmp/out"; }
printf 'out(6 * 7)\n' > "$R/compiler/word.w"

compilespeed "$WORD" "$tmp/cc-ok:$PATH"
if [ "$rc" = 0 ] && cs_measured word && cs_measured c && cs_measured c0 && cs_measured rust \
   && cs_measured go && cs_measured word.w; then ok "every toolchain builds: a row of figures each, exit 0"
else bad "every toolchain builds" "rc=$rc: $(tr '\n' '|' < "$tmp/out")"; fi
compilespeed "$WORD" "$tmp/bare"
if [ "$rc" = 0 ] && cs_measured word && cs_measured word.w \
   && [ -z "$(cs_label c)$(cs_label c0)$(cs_label rust)$(cs_label go)" ]; then
  ok "no comparison toolchain installed: no rows for them, exit 0"
else bad "no comparison toolchain installed" "rc=$rc: $(tr '\n' '|' < "$tmp/out") $(tr '\n' '|' < "$tmp/err")"; fi
# A toolchain that's installed and fails isn't treated as absent. The rows
# after it are still measured.
compilespeed "$WORD" "$tmp/cc-badrust:$tmp/cc-ok:$PATH"
if [ "$rc" = 1 ] && [ "$(cs_label rust)" = "BUILD FAILED" ] && cs_measured go && cs_measured word.w \
   && said "compilespeed.sh: rust: BUILD FAILED" && said "error: this rustc builds nothing"; then
  ok "a toolchain that is installed and fails [rust: $(cs_label rust)], its complaint on stderr"
else bad "a toolchain that is installed and fails" "rc=$rc, rust [$(cs_label rust)]: $(tr '\n' '|' < "$tmp/err")"; fi
compilespeed "$tmp/word-buildfail" "$tmp/cc-ok:$PATH"
if [ "$rc" = 1 ] && [ "$(cs_label word)" = "BUILD FAILED" ] && [ "$(cs_label word.w)" = "BUILD FAILED" ] \
   && cs_measured c && said "compilespeed.sh: word: BUILD FAILED"; then ok "a word that cannot build"
else bad "a word that cannot build" "rc=$rc, word [$(cs_label word)], word.w [$(cs_label word.w)]"; fi
# word failing to compile itself used to go onto the page as a number.
printf 'out(6 *\n' > "$R/compiler/word.w"
compilespeed "$WORD" "$tmp/cc-ok:$PATH"
if [ "$rc" = 1 ] && cs_measured word && [ "$(cs_label word.w)" = "BUILD FAILED" ] \
   && said "compilespeed.sh: word.w: BUILD FAILED"; then ok "word failing to compile its own source [word.w: $(cs_label word.w)]"
else bad "word failing to compile its own source" "rc=$rc, word.w [$(cs_label word.w)]"; fi

echo "== scaling.sh: a failed build or run, or a wrong answer, fails the run =="
# scaling <word>: the scratch scaling.sh with that word; its tables in
# $tmp/out, its stderr in $tmp/err, its exit status in $rc.
scaling() { WORD="$1" sh "$B/scaling.sh" > "$tmp/out" 2> "$tmp/err"; rc=$?; }
# rows, measured: how many rows the tables have, and how many of those carry
# figures (n, ms, rss) instead of a label. labels: each label, once.
rows()     { awk '$1 ~ /^[0-9]+$/ { r++ } END { print r + 0 }' "$tmp/out"; }
measured() { awk '$1 ~ /^[0-9]+$/ && NF == 3 && $2 ~ /^[0-9]+\.[0-9]$/ && $3 ~ /^[0-9]+$/ { m++ } END { print m + 0 }' "$tmp/out"; }
labels()   { awk '$1 ~ /^[0-9]+$/ && !(NF == 3 && $2 ~ /^[0-9]+\.[0-9]$/) { sub(/^ *[0-9]+ /, ""); print }' "$tmp/out" | sort -u; }
# labelled <prefix>: how many rows carry a label that starts with it.
labelled() { awk -v p="$1" '$1 ~ /^[0-9]+$/ { sub(/^ *[0-9]+ /, ""); if (index($0, p) == 1) k++ } END { print k + 0 }' "$tmp/out"; }
# on_stderr <label>: how many rows stderr names as having failed with it.
on_stderr() { grep -c "^scaling\.sh: .*, n=[0-9]*: $1" "$tmp/err"; }

# A row of figures also means the program printed the answer scaling.sh worked
# out for it without word.
scaling "$WORD"
if [ "$rc" = 0 ] && [ "$(rows)" -gt 0 ] && [ "$(measured)" = "$(rows)" ]; then ok "its own programs: $(rows) rows of figures, every answer right, exit 0"
else bad "its own programs" "rc=$rc, $(measured) of $(rows) rows measured: $(tr '\n' '|' < "$tmp/err")"; fi
scaling "$tmp/word-buildfail"
if [ "$rc" = 1 ] && [ "$(measured)" = 0 ] && [ "$(labels)" = "BUILD FAILED" ] \
   && [ "$(on_stderr "BUILD FAILED")" = "$(rows)" ] && said "buildfail.w:"; then
  ok "a build that fails [$(labels)], each row and the compiler's complaint on stderr"
else bad "a build that fails" "rc=$rc, $(measured) of $(rows) rows measured, labels [$(labels)]"; fi
scaling "$tmp/word-runfail"
case "$(labels)" in "FAILED(exit 70: runfail.w:2: index 5 out of bounds"*) m=1;; *) m=0;; esac
if [ "$rc" = 1 ] && [ "$(measured)" = 0 ] && [ "$m" = 1 ] && [ "$(on_stderr "FAILED(exit 70")" = "$(rows)" ]; then
  ok "a run that exits 70 [$(labels)]"
else bad "a run that exits 70" "rc=$rc, $(measured) of $(rows) rows measured, labels [$(labels)]"; fi
scaling "$tmp/word-segv"
if [ "$rc" = 1 ] && [ "$(measured)" = 0 ] && [ "$(labels)" = "FAILED(exit 139)" ]; then ok "a run killed by SIGSEGV [$(labels)]"
else bad "a run killed by SIGSEGV" "rc=$rc, $(measured) of $(rows) rows measured, labels [$(labels)]"; fi
# Exit 0 isn't an answer. A program that did none of its work is fast and flat.
scaling "$tmp/word-answer42"
if [ "$rc" = 1 ] && [ "$(measured)" = 0 ] && [ "$(labelled "MISMATCH(printed 42, want ")" = "$(rows)" ] \
   && [ "$(on_stderr "MISMATCH(printed 42, want ")" = "$(rows)" ]; then ok "a run that exits 0 with another answer [e.g. $(labels | head -1)]"
else bad "a run that exits 0 with another answer" "rc=$rc, $(measured) of $(rows) rows measured, labels [$(labels | tr '\n' '|')]"; fi
scaling "$tmp/word-silent"
if [ "$rc" = 1 ] && [ "$(measured)" = 0 ] && [ "$(labelled "MISMATCH(printed nothing, want ")" = "$(rows)" ]; then
  ok "a run that exits 0 and prints nothing [e.g. $(labels | head -1)]"
else bad "a run that exits 0 and prints nothing" "rc=$rc, $(measured) of $(rows) rows measured, labels [$(labels | tr '\n' '|')]"; fi
rm -f "$tmp/once"
scaling "$tmp/word-once"
if [ "$rc" = 1 ] && [ "$(measured)" = $(($(rows) - 1)) ] && [ "$(labels)" = "BUILD FAILED" ] \
   && said "refused: the first build"; then ok "one row that fails fails the run, with $(measured) measured after it"
else bad "one row that fails fails the run" "rc=$rc, $(measured) of $(rows) rows measured, labels [$(labels)]"; fi

echo
echo "test_bench_harness: $pass passed, $fail failed"
[ "$fail" = 0 ]
