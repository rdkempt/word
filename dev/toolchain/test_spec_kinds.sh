#!/bin/sh
# test_spec_kinds.sh: the SPEC and the compiler must agree about what kinds
# exist, and every kind the SPEC names must be one a program can get.
#
# When the four singletons (SPEC 3.8) went into the compiler, the SPEC went on
# describing the old model: kind() with five answers instead of eight, and a
# failed parse tested with `if data == 0`. Three checks:
#   1. the names the compiler answers are the names SPEC 9 documents
#   2. the reserved singleton words are the ones SPEC 3.8 and the grammar list
#   3. every documented kind is reachable: a program built with word gets that
#      answer from kind()
set -e
LC_ALL=C; export LC_ALL
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; cd "$root"
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1 -- $2"; }

# ---- 1. the kind names -----------------------------------------------------
# is_kind_name is the compiler's own list of kinds. The generator turns
# `kind(x) == "<name>"` into a tag test, and a name this function rejects is a
# compile error.
sed -n '/^is_kind_name(nm)/,/^    return false$/p' compiler/word.w \
  | grep -oE 'nm == "[a-z]+"' | sed 's/.*"\(.*\)".*/\1/' | sort -u > "$tmp/compiler"

# SPEC 9's kind() row. Every kind it names appears as `"name"` somewhere in it.
grep -F '| `kind(x)` |' SPEC.md \
  | grep -oE '`"[a-z]+"`' | tr -d '`"' | sort -u > "$tmp/spec"

[ -s "$tmp/compiler" ] || { echo "FAIL: scraped no kinds from is_kind_name"; exit 1; }
[ -s "$tmp/spec" ]     || { echo "FAIL: scraped no kinds from SPEC 9's kind() row"; exit 1; }

missing=$(comm -23 "$tmp/compiler" "$tmp/spec" | tr '\n' ' ')
extra=$(comm -13 "$tmp/compiler" "$tmp/spec" | tr '\n' ' ')
[ -z "$missing" ] || bad "kinds the compiler answers but SPEC 9 does not document" "$missing"
[ -z "$extra" ]   || bad "kinds SPEC 9 documents but the compiler does not answer" "$extra"
[ -n "$missing$extra" ] || ok "the compiler and SPEC 9 name the same $(wc -l < "$tmp/compiler" | tr -d ' ') kinds"

# ---- 2. the singleton words ------------------------------------------------
# The lexer's reserved words (token 51) against the grammar production and the
# 3.8 table.
grep -B1 'emit(st, 51,' compiler/word.w | grep -oE 'text == "[a-z]+"' \
  | sed 's/.*"\(.*\)".*/\1/' | sort -u > "$tmp/c_sing"
grep -E '^singleton +=' SPEC.md | grep -oE '"[a-z]+"' | tr -d '"' | sort -u > "$tmp/s_sing"

[ -s "$tmp/c_sing" ] || { echo "FAIL: scraped no singletons from the lexer"; exit 1; }
[ -s "$tmp/s_sing" ] || { echo "FAIL: scraped no singletons from the grammar"; exit 1; }
if cmp -s "$tmp/c_sing" "$tmp/s_sing"; then
  ok "the lexer's reserved words and the grammar agree ($(tr '\n' ' ' < "$tmp/c_sing"))"
else
  bad "the lexer and the grammar disagree about the singletons" \
      "lexer [$(tr '\n' ' ' < "$tmp/c_sing")] grammar [$(tr '\n' ' ' < "$tmp/s_sing")]"
fi
# And each must have a row in the 3.8 table, which is where a reader looks.
for w in $(cat "$tmp/c_sing"); do
  grep -q "^| \`$w\` |" SPEC.md || bad "SPEC 3.8 has no table row for '$w'" "the section that documents it"
done

# ---- 3. every documented kind is reachable ---------------------------------
# Build a program that gets one value of each kind and prints what kind() says,
# so the answer comes from the compiled program and not from either document.
mkdir -p "$tmp/p"
cat > "$tmp/p/app.w" <<'EOF'
out(kind(1))
out(kind("ab"))
out(kind(bytes(2)))
out(kind(array(2)))
out(kind({}))
out(kind(true))
out(kind(null))
out(kind(number("wat")))
EOF
if "$WORD" build "$tmp/p/app.w" -o "$tmp/p/app" >/dev/null 2>&1; then
  "$tmp/p/app" 2>/dev/null | sort -u > "$tmp/reached"
  unreached=$(comm -23 "$tmp/spec" "$tmp/reached" | tr '\n' ' ')
  [ -z "$unreached" ] && ok "every documented kind is one a program can actually get" \
                      || bad "documented but unreachable" "$unreached"
else
  bad "the reachability program did not build" "$("$WORD" build "$tmp/p/app.w" -o "$tmp/p/app" 2>&1 | head -1)"
fi

echo "test_spec_kinds: $pass passed, $fail failed"
[ "$fail" = 0 ]
