#!/bin/sh
# test_langserver.sh: the language server. Its generated table must match the
# compiler, its scanner must agree with the compiler about what a function is,
# and it must answer over the wire.
#
# The server runs `word build` for diagnostics and `word format` for
# formatting, so for those this only checks that the answer arrives and points
# at the right line. The compiler's own suites check the answers. Everything
# else here is what the server does on its own.
set -e
# `comm` below needs both lists sorted the same way, so fix the locale.
LC_ALL=C; export LC_ALL
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$root"

wordbin="$root/word"
[ -x "$wordbin" ] || { echo "test_langserver: SKIP (no ./word built)"; exit 0; }
if ! command -v node >/dev/null 2>&1; then
  echo "test_langserver: SKIP (no node; the server is a Node program)"
  exit 0
fi

# ---------------------------------------------------------------- staleness
# Like the TextMate grammar, the committed table is generated (from
# compiler/word.w and SPEC.md), so a stale one fails here instead of leaving
# the editor with an older language.
committed="$root/editors/vscode/langdata.json"
[ -f "$committed" ] || { echo "test_langserver: FAIL (no committed langdata.json)"; exit 1; }
sh "$here/gen_lspdata.sh" "$tmp/langdata.json" >/dev/null
if ! cmp -s "$committed" "$tmp/langdata.json"; then
  echo "test_langserver: FAIL (editors/vscode/langdata.json is stale)"
  echo "  The builtin or module tables changed. Run: sh dev/toolchain/gen_lspdata.sh"
  diff "$committed" "$tmp/langdata.json" | head -20
  exit 1
fi
echo "  ok: editors/vscode/langdata.json matches the compiler's tables"

node -e "JSON.parse(require('fs').readFileSync('$committed','utf8'))" \
  || { echo "test_langserver: FAIL (langdata.json is not valid JSON)"; exit 1; }
echo "  ok: langdata.json is valid JSON"

# len, keys and has have rows in the map table of SPEC 3.7 as well as in 9. The
# hover comes from 9, which documents them: the generator took the first row,
# and those hovers showed 3.7's map-only lines. Each hover here has to start the
# way its row in section 9 does.
for nm in len keys has; do
  want=$(awk -F'|' -v n="$nm" '/^## [0-9]+\./ { sec = $0 }
    sec ~ /^## 9\./ && index($0, "| `" n "(") == 1 { d = $3; sub(/^ */, "", d); print substr(d, 1, 12); exit }' "$root/SPEC.md")
  got=$(node -e "const d = JSON.parse(require('fs').readFileSync('$committed','utf8')); process.stdout.write(d.builtins['$nm'].doc.slice(0, 12))")
  [ -n "$want" ] && [ "$got" = "$want" ] \
    || { echo "test_langserver: FAIL ($nm hovers with [$got...], SPEC 9's row starts [$want...])"; exit 1; }
done
echo "  ok: len, keys and has hover with their SPEC 9 rows"

# ------------------------------------------------- the compiler and the SPEC
# The generator takes the names from compiler/word.w and their descriptions
# from SPEC.md's tables, so the two can disagree. A builtin the compiler has
# and the SPEC doesn't (or the reverse) is a documentation bug.
awk '
  /^builtin_arity\(name\)/ { on = 1; next }
  on && /^    return 0 - 1/ { on = 0 }
  on && /if name == "/ { match($0, /"[a-z_]+"/); print substr($0, RSTART+1, RLENGTH-2) }
' compiler/word.w | sort -u > "$tmp/c_builtins"
awk '
  /^add_module_funcs\(an, modname\)/ { on = 1; next }
  on && /^arity_chk/ { on = 0 }
  on && /modname == "/ { match($0, /"[a-z_]+"/); mod = substr($0, RSTART+1, RLENGTH-2); next }
  on && /mf_add\([a-z_]+, "/ { if (mod != "sys") { match($0, /"[a-z_]+"/); print substr($0, RSTART+1, RLENGTH-2) } }
' compiler/word.w | sort -u > "$tmp/c_modfuncs"
cat "$tmp/c_builtins" "$tmp/c_modfuncs" | sort -u > "$tmp/c_all"

# SPEC 9 (builtins) and SPEC 12 (modules) are the two sections with a
# `| `name(args)` | effect |` table.
awk '
  /^## 9\./  { s = 1 } /^## 10\./ { s = 0 }
  /^## 12\./ { s = 1 } /^## 13\./ { s = 0 }
  s && /^\| *`[a-z_]+\(/ { match($0, /`[a-z_]+\(/); n = substr($0, RSTART+1, RLENGTH-2); print n }
' SPEC.md | sort -u > "$tmp/s_all"

undocumented=$(comm -23 "$tmp/c_all" "$tmp/s_all" | tr '\n' ' ')
phantom=$(comm -13 "$tmp/c_all" "$tmp/s_all" | tr '\n' ' ')
[ -z "$undocumented" ] || { echo "test_langserver: FAIL (the compiler has names SPEC 9/12 do not document: $undocumented)"; exit 1; }
[ -z "$phantom" ]      || { echo "test_langserver: FAIL (SPEC 9/12 document names the compiler does not have: $phantom)"; exit 1; }
echo "  ok: every builtin and module function is in both the compiler and the SPEC ($(wc -l < "$tmp/c_all" | tr -d ' ') names)"

# ------------------------------------------------------------------ the wire
echo "  --- protocol ---"
node "$here/lsp_probe.js" "$wordbin" || { echo "test_langserver: FAIL (see above)"; exit 1; }

# ---------------------------------------------------------------- the outline
echo "  --- outline vs the compiler's own labels ---"
node "$here/test_outline.js" "$wordbin" || { echo "test_langserver: FAIL (see above)"; exit 1; }

echo "test_langserver: PASS"
