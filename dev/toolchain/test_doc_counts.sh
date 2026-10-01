#!/bin/sh
# test_doc_counts.sh: the numbers the documentation states about this
# repository have to match the repository.
#
# The compiler's size, the crypto module count, the builtin count, the module
# names and test_tls_reject's case counts have each drifted in the docs at
# least once, and nobody notices that kind of thing by reading, so they're
# checked here. A stated size has to be within 2% of the real one: close
# enough for a rounded figure, and tight enough to catch one a release behind.
set -e
LC_ALL=C; export LC_ALL
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd); cd "$root"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1 -- $2"; }

# ---- the compiler's size ---------------------------------------------------
# compiler/word.w carries the net library in its NETLIB region, the text it
# bundles into programs that call a net verb (netlib_embed). That isn't the
# compiler an auditor reads. `wc -l` on the file counts both, and the size the
# docs state (and this check) is the compiler without that region. The
# BEGIN/END markers only appear whole in the region (the scanner's code splits
# them), so this matches what netlib_embed strips.
region=$(awk '/>>> NETLIB BEGIN/{f=1} f{n++} /<<< NETLIB END/{print n; exit}' compiler/word.w)
actual=$(( $(wc -l < compiler/word.w | tr -d ' ') - ${region:-0} ))
found=0
# A size claim is a count of lines on a line that also names compiler/word.w.
# Going by magnitude alone would flag docs/BOOTSTRAP.md's line count for the
# Python seed as stale compiler prose. The suites and scripts are read too,
# since a size typed into a test's output drifts the same way (lsp_probe.js
# printed an old figure in CI for a release and a half).
for f in README.md SPEC.md dev/toolchain/README.md docs/*.md \
         dev/toolchain/*.sh dev/toolchain/*.js dev/benchmarks/*.sh; do
  [ -f "$f" ] || continue
  grep -nE 'compiler/word\.w' "$f" 2>/dev/null | grep -oE '[0-9][0-9,]{3,} ?(-)?lines?' \
  | while read -r claim; do
    n=$(printf '%s' "$claim" | grep -oE '^[0-9][0-9,]*' | tr -d ',')
    [ -n "$n" ] || continue
    lo=$((actual - actual / 50)); hi=$((actual + actual / 50))
    if [ "$n" -lt "$lo" ] || [ "$n" -gt "$hi" ]; then
      echo "  FAIL: $f says '$claim' of compiler/word.w; it is $actual lines"
      echo "stale" >> "$root/.doccount.fail"
    fi
  done
  found=1
done
[ "$found" = 1 ] || bad "found no documents to check" "the glob matched nothing"
if [ -f "$root/.doccount.fail" ]; then
  fail=$((fail + $(wc -l < "$root/.doccount.fail"))); rm -f "$root/.doccount.fail"
else
  ok "every stated size of compiler/word.w is within 2% of its $actual lines"
fi

# ---- the crypto modules ----------------------------------------------------
# The library is the NETLIB region of compiler/word.w, and netlib_cat.py --list
# prints one line per module in it.
mods=$(python3 dev/toolchain/netlib_cat.py --list | wc -l | tr -d ' ')
claimed=$(grep -oE 'all [0-9]+ modules' docs/SECURITY.md | grep -oE '[0-9]+' | head -1)
if [ -z "$claimed" ]; then bad "SECURITY.md no longer states a module count" "the scrape found nothing"
elif [ "$claimed" != "$mods" ]; then bad "SECURITY.md says $claimed crypto modules" "there are $mods"
else ok "SECURITY.md's crypto module count is right ($mods)"; fi

# ---- the builtins ----------------------------------------------------------
builtins=$(sed -n '/^builtin_arity(name)/,/^    return 0 - 1/p' compiler/word.w \
           | grep -oE 'name == "[a-z_]+"' | sort -u | wc -l | tr -d ' ')
bclaim=$(grep -oiE 'the [0-9]+ builtins' docs/LEARNABILITY.md | grep -oE '[0-9]+' | head -1)
if [ -z "$bclaim" ]; then bad "LEARNABILITY.md no longer states a builtin count" "the scrape found nothing"
elif [ "$bclaim" != "$builtins" ]; then bad "LEARNABILITY.md says $bclaim builtins" "builtin_arity has $builtins"
else ok "LEARNABILITY.md's builtin count is right ($builtins)"; fi

# The same number in its other two phrasings. The summary table was once a
# count behind the compiler, and a reader quoted the table.
tclaim=$(grep -oE 'Always-available builtins \| \*\*[0-9]+\*\*' docs/LEARNABILITY.md | grep -oE '[0-9]+' | head -1)
if [ -n "$tclaim" ] && [ "$tclaim" != "$builtins" ]; then
  bad "LEARNABILITY.md's summary table says $tclaim builtins" "builtin_arity has $builtins"
elif [ -n "$tclaim" ]; then ok "and the summary table agrees"; fi

nclaim=$(grep -oE 'keep the number at [0-9]+' docs/LEARNABILITY.md | grep -oE '[0-9]+' | head -1)
if [ -n "$nclaim" ] && [ "$nclaim" != "$builtins" ]; then
  bad "LEARNABILITY.md's 'keep the number at $nclaim'" "builtin_arity has $builtins"
elif [ -n "$nclaim" ]; then ok "and so is the ceiling it says that count defends"; fi

# ---- module names ----------------------------------------------------------
# The module is `txt`. `text` is one letter away, and it turned up in prose
# for months.
for f in README.md SPEC.md docs/*.md; do
  [ -f "$f" ] || continue
  if grep -qE '`text` module|import text\b' "$f"; then
    bad "$f calls the module \`text\`" "it is \`txt\` (SPEC 12.4)"
  fi
done
grep -q 'is_module_name' compiler/word.w || bad "cannot find is_module_name" "the compiler changed shape"
for m in $(sed -n '/^is_module_name(modname)/,/^    return 0$/p' compiler/word.w \
           | grep -oE 'modname == "[a-z]+"' | sed 's/.*"\(.*\)".*/\1/'); do
  grep -q "\`$m\`" SPEC.md || bad "module '$m' is never named in SPEC.md" "the compiler has it"
done
ok "every module the compiler has is named in the SPEC, under the name it has"

# The compiler's unknown-module message has to name the same list. It once
# refused `import text` with a message that listed `text` among the valid
# modules.
have=$(sed -n '/^is_module_name(modname)/,/^    return 0$/p' compiler/word.w \
       | grep -oE 'modname == "[a-z]+"' | sed 's/.*"\(.*\)".*/\1/' | sort -u)
# "... are fs, net, json, txt and sys, and none of them needs importing ...":
# take what follows "are", stop at the ", and" that ends the list, then split on
# the separators. Cutting at ", and" keeps the rest of the sentence out of the
# list.
said=$(grep -F 'the built-in modules are' compiler/word.w | head -1 \
       | sed 's/.*the built-in modules are //; s/, and .*//; s/ and / /; s/,/ /g' \
       | tr ' ' '\n' | grep -v '^$' | sort -u)
if [ -z "$said" ]; then
  bad "the unknown-module diagnostic no longer lists the modules" "the scrape found nothing"
elif [ "$have" != "$said" ]; then
  bad "the compiler's unknown-module message names a different list than is_module_name accepts" \
      "accepts [$(echo "$have" | tr '\n' ' ')] says [$(echo "$said" | tr '\n' ' ')]"
else
  ok "the unknown-module diagnostic names exactly the modules that resolve ($(echo "$have" | tr '\n' ' '))"
fi

# ---- the reject-suite's own case counts -------------------------------------
# SECURITY.md states how many chains test_tls_reject.sh refuses and how many
# positive controls it has. Both changed when the two extension rules landed.
neg=$(grep -c '^case_run REJECTED' dev/toolchain/test_tls_reject.sh)
pos=$(grep -c '^case_run ACCEPTED' dev/toolchain/test_tls_reject.sh)
claim=$(grep -oE 'test_tls_reject\.sh`[^0-9]*[0-9]+ chains that must be refused, [0-9]+ positive controls' docs/SECURITY.md | head -1)
cneg=$(printf '%s' "$claim" | grep -oE '[0-9]+ chains' | grep -oE '[0-9]+')
cpos=$(printf '%s' "$claim" | grep -oE '[0-9]+ positive' | grep -oE '[0-9]+')
if [ -z "$cneg" ] || [ -z "$cpos" ]; then
  bad "SECURITY.md no longer states test_tls_reject's case counts" "the scrape found nothing"
elif [ "$cneg" != "$neg" ] || [ "$cpos" != "$pos" ]; then
  bad "SECURITY.md says $cneg refused / $cpos positive controls" "the suite has $neg / $pos"
else
  ok "test_tls_reject's case counts are the ones SECURITY.md states ($neg refused, $pos controls)"
fi

echo "test_doc_counts: $pass passed, $fail failed"
[ "$fail" = 0 ]
