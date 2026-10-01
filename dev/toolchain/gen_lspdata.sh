#!/bin/sh
# gen_lspdata.sh: generate editors/vscode/langdata.json, the table the language
# server answers hover and completion from.
#
# The same arrangement as gen_tmgrammar.sh, for the same reason: a hand-written
# list of builtins goes stale the first time the language gains one, and an
# editor is the last place anyone would notice. So the set of names and their
# arities are read out of compiler/word.w (`builtin_arity`, `is_module_name`
# and `add_module_funcs` are the compiler's own definitions), and the prose is
# read out of SPEC.md's builtin tables, where it's already written for a reader.
#
# Because both halves are scraped, they can disagree, and test_langserver.sh
# fails when they do: a builtin the compiler knows and the SPEC doesn't (or the
# reverse) is a documentation bug, and this catches it.
set -e
# The output is committed and diffed, so it has to be byte-identical on every
# machine that runs this. `sort` collates by locale, and a name with an
# underscore sorts differently under en_US than under C, which would make the
# staleness check fail on one person's laptop and nowhere else.
LC_ALL=C; export LC_ALL
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
out="${1:-$root/editors/vscode/langdata.json}"
src="$root/compiler/word.w"
spec="$root/SPEC.md"

[ -f "$src" ]  || { echo "gen_lspdata: no compiler/word.w"; exit 1; }
[ -f "$spec" ] || { echo "gen_lspdata: no SPEC.md"; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# --- the compiler's tables --------------------------------------------------
# builtin_arity: `if name == "x"` followed by `return n`. -1 means "not a
# builtin", which is the function's own sentinel and never a name.
awk '
  /^builtin_arity\(name\)/ { on = 1; next }
  on && /^    return 0 - 1/  { on = 0 }
  on && /if name == "/       { match($0, /"[a-z_]+"/); nm = substr($0, RSTART+1, RLENGTH-2); next }
  on && /^ *return [0-9]+/   { if (nm != "") { print nm "\t" $2; nm = "" } }
' "$src" | sort -u > "$tmp/builtins"

awk '
  /^is_module_name\(modname\)/ { on = 1; next }
  on && /^    return false$/   { on = 0 }
  on && /if modname == "/      { match($0, /"[a-z_]+"/); print substr($0, RSTART+1, RLENGTH-2) }
' "$src" | sort -u > "$tmp/modules"

# add_module_funcs: `if/else if modname == "m"` opens a module, mf_add adds one
# (whatever its first parameter is called).
awk '
  /^add_module_funcs\(an, modname\)/ { on = 1; next }
  on && /^arity_chk/                 { on = 0 }
  on && /modname == "/  { match($0, /"[a-z_]+"/); mod = substr($0, RSTART+1, RLENGTH-2); next }
  on && /mf_add\([a-z_]+, "/ { match($0, /"[a-z_]+"/); nm = substr($0, RSTART+1, RLENGTH-2);
                          n = $0; sub(/.*, /, "", n); sub(/\).*/, "", n);
                          print mod "\t" nm "\t" n }
' "$src" > "$tmp/modfuncs"

# The four singletons are reserved words in the lexer (token 51), not names.
awk '
  /emit\(st, 51,/ { match($0, /text == "[a-z]+"/) }
  /else if text == "[a-z]+"$/ { match($0, /"[a-z]+"/); cand = substr($0, RSTART+1, RLENGTH-2); next }
  /emit\(st, 51, [0-9]/ { if (cand != "") print cand; cand = "" }
' "$src" | sort -u > "$tmp/singletons"

# kind() answers only these eight names, and comparing it with any other is a
# compile error, so completion inside a kind test offers this list and no more.
awk '
  /^is_kind_name\(nm\)/ { on = 1; next }
  on && /^    return false$/ { on = 0 }
  on && /if nm == "/     { match($0, /"[a-z]+"/); print substr($0, RSTART+1, RLENGTH-2) }
' "$src" | sort -u > "$tmp/kindnames"

for f in builtins modules modfuncs singletons kindnames; do
  [ -s "$tmp/$f" ] || { echo "gen_lspdata: scraped no $f from compiler/word.w"; exit 1; }
done

# --- the SPEC's prose -------------------------------------------------------
# Every `| `sig(args)` | text |` row of a builtin or module table, with the
# number of the top-level section it is in. The first sentence is what a hover
# shows; the signature carries the real parameter names, which arity alone
# cannot. A name can have more than one row: len, keys and has are in the map
# table of 3.7 as well as in 9, so the lookup below prefers the section that
# documents the name (9 for a builtin, 12 for a module function). It took the
# first row, and those three hovers showed 3.7's short map-only lines.
awk -F'|' '
  /^## [0-9]+\./ { sec = $0; sub(/^## /, "", sec); sub(/\..*/, "", sec) }
  /^\| *`[a-z_]+\(/ {
    sig = $2; gsub(/^ *`/, "", sig); gsub(/` *$/, "", sig);
    d = $3; for (i = 4; i <= NF; i++) d = d "|" $i;
    gsub(/^ */, "", d); gsub(/ *$/, "", d);
    nm = sig; sub(/\(.*/, "", nm);
    # First sentence: up to the first ". " outside a `code span`, or the end.
    # No abbreviations appear here, but a period inside a span does: the
    # description of char contains `s . 72`, and cutting there would end the
    # hover in the middle of the span.
    s = d; tick = 0; cut = 0;
    for (i = 1; i < length(s); i++) {
      c = substr(s, i, 1);
      if (c == "`") { tick = 1 - tick }
      else if (tick == 0 && c == "." && substr(s, i + 1, 1) == " ") { cut = i; break }
    }
    if (cut > 0) s = substr(s, 1, cut);
    gsub(/\\\|/, "|", s); gsub(/\\/, "", s);
    print nm "\t" sig "\t" s "\t" sec
  }
' "$spec" > "$tmp/spec"

[ -s "$tmp/spec" ] || { echo "gen_lspdata: scraped no signatures from SPEC.md"; exit 1; }

# --- emit -------------------------------------------------------------------
# JSON by hand, because this repo has no dependencies and this isn't worth
# adding one for. Everything scraped is [a-z_(), ] plus prose, so the only
# escaping the prose needs is backslash and quote.
jstr() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# spec_col <name> <section> <column>: that column of the name's row in the
# section, or of its first row anywhere when the section has none.
spec_col() { awk -F"$(printf '\t')" -v n="$1" -v s="$2" -v c="$3" '
  $1 == n && first == "" { first = $c }
  $1 == n && $4 == s { print $c; done = 1; exit }
  END { if (!done) print first }' "$tmp/spec"; }

# A name the SPEC tables don't carry (only sys's functions, which SPEC 12.5
# describes in prose) still needs something to show on hover, so build a
# signature from the arity the compiler gave.
sigfor() { awk -v n="$1" -v a="$2" 'BEGIN {
  p = "abcdefghijklmnopqrstuvwxyz";
  s = n "("; for (i = 0; i < a; i++) s = s (i ? ", " : "") substr(p, i + 1, 1); print s ")" }'; }

{
  printf '{\n'
  printf '  "_generated": "by dev/toolchain/gen_lspdata.sh from compiler/word.w and SPEC.md; do not edit by hand",\n'
  printf '  "keywords": ["if", "else", "loop", "return", "break"],\n'
  printf '  "contextual": ["before", "after", "result", "import", "in"],\n'

  printf '  "singletons": ['
  sep=""; while read -r s; do printf '%s"%s"' "$sep" "$s"; sep=", "; done < "$tmp/singletons"
  printf '],\n'

  printf '  "kindNames": ['
  sep=""; while read -r s; do printf '%s"%s"' "$sep" "$s"; sep=", "; done < "$tmp/kindnames"
  printf '],\n'

  printf '  "modules": ['
  sep=""; while read -r s; do printf '%s"%s"' "$sep" "$s"; sep=", "; done < "$tmp/modules"
  printf '],\n'

  printf '  "builtins": {\n'
  sep=""
  while IFS="$(printf '\t')" read -r nm ar; do
    sig=$(spec_col "$nm" 9 2)
    doc=$(spec_col "$nm" 9 3)
    [ -n "$sig" ] || sig=$(sigfor "$nm" "$ar")
    printf '%s    "%s": { "arity": %s, "signature": "%s", "doc": "%s" }' \
      "$sep" "$nm" "$ar" "$(jstr "$sig")" "$(jstr "$doc")"
    sep=$(printf ',\n')
  done < "$tmp/builtins"
  printf '\n  },\n'

  printf '  "moduleFuncs": {\n'
  msep=""
  while read -r mod; do
    printf '%s    "%s": {\n' "$msep" "$mod"
    fsep=""
    awk -F"$(printf '\t')" -v m="$mod" '$1 == m { print $2 "\t" $3 }' "$tmp/modfuncs" \
    | while IFS="$(printf '\t')" read -r nm ar; do
        sig=$(spec_col "$nm" 12 2)
        doc=$(spec_col "$nm" 12 3)
        # sys is described in prose, not a table (SPEC 12.5).
        [ -n "$sig" ] || sig=$(sigfor "$nm" "$ar")
        [ -n "$doc" ] || doc="Internal toolchain glue (SPEC 12.5), with no stability promise."
        printf '%s      "%s": { "arity": %s, "module": "%s", "signature": "%s", "doc": "%s" }' \
          "$fsep" "$nm" "$ar" "$mod" "$(jstr "$sig")" "$(jstr "$doc")"
        fsep=$(printf ',\n')
      done
    printf '\n    }'
    msep=$(printf ',\n')
  done < "$tmp/modules"
  printf '\n  }\n'
  printf '}\n'
} > "$out"

echo "wrote $out"
echo "  builtins     : $(wc -l < "$tmp/builtins" | tr -d ' ')"
echo "  modules      : $(tr '\n' ' ' < "$tmp/modules")"
echo "  module funcs : $(wc -l < "$tmp/modfuncs" | tr -d ' ')"
