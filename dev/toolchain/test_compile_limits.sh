#!/bin/sh
# test_compile_limits.sh: the compiler against source that's extreme in shape
# rather than in size.
#
# Whatever the input, the compiler has to finish promptly with one of two
# outcomes (SPEC 10.1):
#
#   COMPILES: exit 0, an executable is written, and it runs and prints the
#             right answer (compiling alone doesn't count).
#   REFUSED:  exit 1, one diagnostic on stderr in the form
#             `<file>.w:<line>[:<col>]: <message>`, nothing on stdout, and no
#             executable.
#
# Anything else is a bug, and each kind is checked for by name:
#
#   * exit 70: word's run-time fault code. The compiler is a word program, so
#     this means the compiler itself faulted, with a message naming a line of
#     compiler/word.w instead of the user's `.w` file.
#   * a signal: it crashed.
#   * a timeout: the input controls a bound it shouldn't.
#
# test_fuzz_frontend.sh checks the same thing over mutated real sources, which
# finds token-level trouble. This one uses source that's extreme by
# construction, which is where the structural limits are. The older stress
# tests were broad (thousands of functions, tens of thousands of literals, 256
# locals) and shallow, and depth is where the compiler fell over. Writing this
# suite found three compiler faults: 10,000 nested parentheses used up the
# compiler's stack, 19 nested loops overflowed the register-pinning weight (ten
# per level), and 10,000 joins on one line used up the stack in check_expr.
# The last only showed on a native word.exe, whose stack was 1 MB then. A PE
# gets 8 MB now, and the suite is still worth running on both.
#
# No `set -e`, since most cases here exit nonzero.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"
cd "$root"
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

# How long any one compile may take. It's generous: the slowest case here
# (16,600 functions) compiles in well under a second on a laptop, so this only
# fires when the input controls a bound, not on a slow machine.
SECS=${LIMIT_SECS:-60}
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout $SECS"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1 -- $2"; }
src="$tmp/p.w"; exe="$tmp/p"

# The check, on whatever is at $src (or $2 when a folder case names its own
# entry file). $3, when given, is what a successful build's program must
# print. When it's the word REFUSED, the build must fail with a located
# diagnostic instead.
invariant() { nm="$1"; f="${2:-$src}"; want="$3"
  rm -f "$exe"
  sout=$($TO "$WORD" build "$f" -o "$exe" 2>"$tmp/diag"); rc=$?
  diag=$(cat "$tmp/diag")
  if [ "$rc" = 124 ]; then bad "$nm" "the compiler did not finish inside ${SECS}s"; return; fi
  if [ "$rc" -ge 128 ] 2>/dev/null; then bad "$nm" "the compiler died on a signal (exit $rc)"; return; fi
  if [ "$rc" = 70 ]; then
    bad "$nm" "the COMPILER faulted (exit 70): $(printf '%s' "$diag" | head -1)"; return; fi
  if [ "$rc" = 0 ]; then
    if [ "$want" = REFUSED ]; then bad "$nm" "compiled, but this shape must be refused"; return; fi
    if [ ! -x "$exe" ]; then bad "$nm" "exit 0 but no executable at $exe"; return; fi
    got=$($TO "$exe" 2>&1 </dev/null); prc=$?
    if [ -n "$want" ] && { [ "$got" != "$want" ] || [ "$prc" != 0 ]; }; then
      bad "$nm" "compiled, but printed [$got] rc=$prc, want [$want]"; return; fi
    ok "$nm (compiles, and runs)"; return
  fi
  if [ "$rc" != 1 ]; then bad "$nm" "exit $rc: neither a build (0) nor a refusal (1)"; return; fi
  # A refusal: located, on stderr, nothing on stdout, and no executable.
  case "$diag" in *.w:[0-9]*) loc=1;; *) loc=0;; esac
  if [ "$loc" = 0 ]; then bad "$nm" "refused, but the diagnostic is not located: [$(printf '%s' "$diag" | head -1)]"; return; fi
  case "$diag" in *word.w:*) own=1;; *) own=0;; esac
  if [ "$own" = 1 ]; then bad "$nm" "the diagnostic names the COMPILER's source: [$(printf '%s' "$diag" | head -1)]"; return; fi
  if [ -n "$sout" ]; then bad "$nm" "refused, but wrote to stdout: [$sout]"; return; fi
  if [ -x "$exe" ]; then bad "$nm" "refused, but an executable was written"; return; fi
  if [ -n "$want" ] && [ "$want" != REFUSED ]; then
    bad "$nm" "refused: $(printf '%s' "$diag" | head -1)"; return; fi
  ok "$nm (refused: $(printf '%s' "$diag" | head -1 | sed 's/.*\.w:/…:/'))"; }

# gen <awk program> : write $src from an awk BEGIN block. Every generator here
# builds its lines with `print`, so there is no backslash escape to lose.
gen() { awk "$1" > "$src"; }

echo "== structural depth: the nine shapes that recurse, at 10,000 =="
gen 'BEGIN{s="out("; for(i=0;i<10000;i++) s=s "("; s=s "1"; for(i=0;i<10000;i++) s=s ")"; print s ")"}'
invariant "10,000 nested parentheses" "" REFUSED
gen 'BEGIN{print "id(x)"; print "    return x"; print ""; s="out("; for(i=0;i<10000;i++) s=s "id("; s=s "1"; for(i=0;i<10000;i++) s=s ")"; print s ")"}'
invariant "10,000 nested calls" "" REFUSED
gen 'BEGIN{print "a = array(1)"; s="out("; for(i=0;i<10000;i++) s=s "a["; s=s "0"; for(i=0;i<10000;i++) s=s "]"; print s ")"}'
invariant "10,000 nested subscripts" "" REFUSED
gen 'BEGIN{s="out(len("; for(i=0;i<10000;i++) s=s "array("; s=s "1"; for(i=0;i<10000;i++) s=s ")"; print s "))"}'
invariant "10,000 nested array literals" "" REFUSED
gen 'BEGIN{s="out("; for(i=0;i<10000;i++) s=s "{a: "; s=s "1"; for(i=0;i<10000;i++) s=s "}"; print s ")"}'
invariant "10,000 nested map literals" "" REFUSED
gen 'BEGIN{s="out("; for(i=0;i<10000;i++) s=s "1 + ("; s=s "1"; for(i=0;i<10000;i++) s=s ")"; print s ")"}'
invariant "10,000 right-nested binary operators" "" REFUSED
gen 'BEGIN{s="out("; for(i=0;i<10000;i++) s=s "!"; print s "true)"}'
invariant "10,000 prefix operators" "" REFUSED
gen 'BEGIN{print "x = 0"; for(i=0;i<2000;i++){t=""; for(j=0;j<i;j++) t=t "    "; print t "if x == 0"} t=""; for(j=0;j<2000;j++) t=t "    "; print t "out(1)"}'
invariant "2,000 nested if blocks" "" REFUSED
gen 'BEGIN{print "f(x)"; print "    if x == 0"; print "        return 0"; for(i=1;i<2000;i++){print "    else if x == " i; print "        return " i} print "    return 0 - 1"; print ""; print "out(f(1))"}'
invariant "a 2,000-arm else-if chain" "" REFUSED

echo "== nested loops, where the weight is ten per level =="
# 10^depth overflowed the compiler's own arithmetic at 19 levels, and the
# running total it feeds overflowed at 25. Both saturate now, so the only limit
# left is the language's block limit (512).
for n in 5 18 19 25 100 512; do
  awk -v n=$n 'BEGIN{print "x = 0"; for(i=0;i<n;i++){t=""; for(j=0;j<i;j++) t=t "    "; print t "loop x < 0"} t=""; for(j=0;j<n;j++) t=t "    "; print t "x = 1"; print "out(x)"}' > "$src"
  invariant "$n nested loops" "" "0"
done
awk 'BEGIN{n=520; print "x = 0"; for(i=0;i<n;i++){t=""; for(j=0;j<i;j++) t=t "    "; print t "loop x < 0"} t=""; for(j=0;j<n;j++) t=t "    "; print t "x = 1"; print "out(x)"}' > "$src"
invariant "520 nested loops (past the block limit)" "" REFUSED

echo "== breadth: wide rather than deep =="
gen 'BEGIN{s="m = {"; for(i=0;i<10000;i++) s=s "k" i ": " i ", "; print s "}"; print "out(len(m))"}'
invariant "a 10,000-pair map literal" "" "10000"

echo "== a chain leans LEFT, so it is depth the parser does not feel =="
# `a . b . c . ...` parses in constant stack (pbinary loops instead of
# recursing), but the tree grows a level per operator, and the analyzer and the
# code generator walk the tree. 10,000 of them used up the compiler's stack in
# check_expr on the 1 MB stack a native word.exe had then. Linux's 8 MB stack
# hid it.
for op in '. "x"' '+ v' '* v' '| v' '&& true' '== v'; do
  awk -v o="$op" 'BEGIN{print "v = 1"; s="out(v"; for(i=0;i<10000;i++) s=s " " o; print s ")"}' > "$src"
  invariant "a 10,000-operand chain of '$op'" "" REFUSED
done
# A chain has its own, larger budget, because a chained operator costs the
# compiler about one frame where a level of nesting costs about eleven. On a
# 1 MB stack the compiler survived about 4,000 chained operators and about 730
# levels of nested map literal, so the depths that must still compile are
# generous.
awk 'BEGIN{print "v = 1"; s="out(len(v"; for(i=0;i<1024;i++) s=s " . \"x\""; print s "))"}' > "$src"
invariant "a 1,024-operand chain still compiles" "" "1025"
awk 'BEGIN{print "v = 1"; s="out(len(v"; for(i=0;i<1025;i++) s=s " . \"x\""; print s "))"}' > "$src"
invariant "1,025 is one too many: the boundary is exact" "" REFUSED
# The budget counts the operators as written, before constant folding, which
# keeps the rule predictable (SPEC 10.1).
awk 'BEGIN{s="out(1"; for(i=0;i<1025;i++) s=s " + 1"; print s ")"}' > "$src"
invariant "1,025 constant terms, which fold to one number" "" REFUSED
awk 'BEGIN{s="out(1"; for(i=0;i<1024;i++) s=s " + 1"; print s ")"}' > "$src"
invariant "1,024 of them still fold and compile" "" "1025"

# ...and the two budgets are separate, so the deepest of each at once still fits.
awk 'BEGIN{print "v = 1"; s="out(len("; for(i=0;i<250;i++) s=s "("; s=s "v"; for(i=0;i<1000;i++) s=s " . \"x\""; for(i=0;i<250;i++) s=s ")"; print s "))"}' > "$src"
invariant "250 levels of nesting around a 1,000-operand chain" "" "1001"

echo "== breadth, continued =="
gen 'BEGIN{s="f("; for(i=0;i<10000;i++){ if(i) s=s ", "; s=s "a" i} print s ")"; print "    return a0"; s="out(f("; for(i=0;i<10000;i++){ if(i) s=s ", "; s=s i} print s "))"}'
invariant "a function of 10,000 parameters" "" "0"
gen 'BEGIN{s="s = \""; for(i=0;i<1000000;i++) s=s "x"; print s "\""; print "out(len(s))"}'
invariant "a 1 MB string literal" "" "1000000"
gen 'BEGIN{print "n = 0"; for(i=0;i<10000;i++) print "n = n + " i; print "out(n)"}'
invariant "10,000 top-level statements" "" "49995000"
gen 'BEGIN{for(i=0;i<200000;i++) print "// a comment line"; print "out(1)"}'
invariant "200,000 comment lines" "" "1"
gen 'BEGIN{print "f()"; for(i=0;i<10000;i++) print "    n" i " = " i; print "    return 1"; print ""; print "out(f())"}'
invariant "a 10,000-statement function body" "" REFUSED
gen 'BEGIN{s="n"; for(i=0;i<100000;i++) s=s "x"; print s " = 1"; print "out(" s ")"}'
invariant "a 100,000-character identifier" "" "1"
gen 'BEGIN{s="n = "; for(i=0;i<1000000;i++) s=s "9"; print s}'
invariant "a 1,000,000-digit number literal" "" REFUSED
# The assembler's label table used to be a fixed 65,536 slots, and `word build`
# hung looking for a free one. 16,600 small functions emit about 66,700 labels.
gen 'BEGIN{for(i=0;i<16600;i++){printf "f%d(x)\n    if x > %d\n        return x\n    return %d\n", i, i, i}; print "s = 0"; for(i=0;i<16600;i++) printf "s = s + f%d(1)\n", i; print "out(s)"}'
invariant "16,600 functions, past the old 65,536-label table" "" "137771701"

echo "== malformed AND extreme: a refusal is still a located diagnostic =="
gen 'BEGIN{s="out("; for(i=0;i<10000;i++) s=s "("; print s "1"}'
invariant "10,000 unclosed parentheses" "" REFUSED
gen 'BEGIN{s="out("; for(i=0;i<10000;i++) s=s "["; print s "1"}'
invariant "10,000 unclosed brackets" "" REFUSED
gen 'BEGIN{s=""; for(i=0;i<10000;i++) s=s ")"; print s}'
invariant "10,000 stray closing parentheses" "" REFUSED
gen 'BEGIN{s="out("; for(i=0;i<10000;i++) s=s "{a: "; print s "1"}'
invariant "10,000 unclosed map literals" "" REFUSED
gen 'BEGIN{for(i=0;i<5000;i++){t=""; for(j=0;j<i;j++) t=t "    "; print t "if true"}}'
invariant "5,000 if headers with no body" "" REFUSED

echo "== files and folders =="
printf 'out(1)' > "$src"
invariant "a file with no trailing newline" "" "1"
printf '\n\n\n\n' > "$src"
invariant "a file of only newlines" "" ""
: > "$src"
invariant "an empty file" "" ""
printf 'out(1)\n\000\001\002binary\n' > "$src"
invariant "a file with NUL and control bytes" "" REFUSED

# A folder is the program (SPEC 11): a flat directory of many files, and an
# entry file a long way down a path.
mkdir -p "$tmp/many"
i=0; while [ $i -lt 500 ]; do printf 'g%d()\n    return %d\n' $i $i > "$tmp/many/s$i.w"; i=$((i+1)); done
awk 'BEGIN{s="out("; for(i=0;i<500;i++){ if(i) s=s " + "; s=s "g" i "()"} print s ")"}' > "$tmp/many/app.w"
invariant "a folder of 501 files" "$tmp/many/app.w" "124750"

deep="$tmp/deep"; i=0
while [ $i -lt 100 ]; do deep="$deep/d"; i=$((i+1)); done
mkdir -p "$deep"; printf 'out(2)\n' > "$deep/app.w"
invariant "app.w a hundred directories down" "$deep/app.w" "2"

# A subdirectory isn't scanned (SPEC 11), so a broken file in one can't reach
# the build.
mkdir -p "$tmp/sub/nested/deeper"
printf 'out(3)\n' > "$tmp/sub/app.w"
printf 'this is not word source at all ((( \n' > "$tmp/sub/nested/deeper/junk.w"
invariant "a subdirectory is not scanned, whatever is in it" "$tmp/sub/app.w" "3"

echo
echo "test_compile_limits: $pass passed, $fail failed (compile budget ${SECS}s)"
[ "$fail" = 0 ]
