#!/bin/sh
# test_tmgrammar.sh: the committed TextMate grammar must match what
# gen_tmgrammar.sh produces from compiler/word.w right now.
#
# The grammar is committed because an editor loads it from the tree, and
# nothing else builds or reads it, so it would go stale without anyone noticing.
# This regenerates it into a temp file and diffs.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
committed="$root/editors/vscode/word.tmLanguage.json"

[ -f "$committed" ] || { echo "test_tmgrammar: FAIL (no committed grammar)"; exit 1; }
sh "$here/gen_tmgrammar.sh" "$tmp/word.tmLanguage.json" >/dev/null
if ! cmp -s "$committed" "$tmp/word.tmLanguage.json"; then
  echo "test_tmgrammar: FAIL (editors/vscode/word.tmLanguage.json is stale)"
  echo "  The language's token set changed. Run: sh dev/toolchain/gen_tmgrammar.sh"
  diff "$committed" "$tmp/word.tmLanguage.json" | head -20
  exit 1
fi
echo "  ok: editors/vscode/word.tmLanguage.json matches the compiler's token set"

# It also has to be valid JSON, or the editor loads nothing and says nothing.
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open('$committed'))" \
    && echo "  ok: the grammar is valid JSON" \
    || { echo "test_tmgrammar: FAIL (grammar is not valid JSON)"; exit 1; }
  python3 -c "import json;d=json.load(open('$committed'));p=json.load(open('$root/editors/vscode/package.json'));\
assert d['scopeName']==p['contributes']['grammars'][0]['scopeName'], 'scopeName mismatch';\
assert '.w' in p['contributes']['languages'][0]['extensions'], '.w not registered'" \
    && echo "  ok: package.json points at this grammar and claims .w" \
    || { echo "test_tmgrammar: FAIL (package.json and grammar disagree)"; exit 1; }
fi

# Every builtin in builtin_arity must appear in the grammar, or an editor
# colours it as a plain identifier. This reads the grammar itself, so a
# generator that drops a name can't pass by matching its own output.
missing=""
names=$(sed -n '/^builtin_arity(name)/,/^    return 0 - 1/p' "$root/compiler/word.w" \
        | grep -oE 'name == "[a-z]+"' | sed 's/.*"\(.*\)".*/\1/' | sort -u)
# The compiler has changed how it spells this comparison before (streq() became
# ==), so an empty scrape fails here instead of letting the loop below pass
# without checking anything.
[ -n "$names" ] || { echo "test_tmgrammar: FAIL (scraped no builtins from builtin_arity)"; exit 1; }
for b in $names; do
  grep -q "\b$b\b" "$committed" || missing="$missing $b"
done
[ -z "$missing" ] || { echo "test_tmgrammar: FAIL (builtins missing from the grammar:$missing)"; exit 1; }
echo "  ok: every builtin in builtin_arity appears in the grammar"

echo "test_tmgrammar: PASS"
