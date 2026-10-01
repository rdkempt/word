#!/bin/sh
# gen_tmgrammar.sh: generate editors/vscode/word.tmLanguage.json from the
# compiler's own names, so the highlighting can't drift from the language.
#
# The builtin names, the module names and the module functions are read out of
# compiler/word.w instead of typed here: `builtin_arity` is the one place that
# knows every always-live callable name. The five keywords and the contextual
# words are written into the grammar below. test_tmgrammar.sh runs this again
# and fails if the committed file is stale.
set -e
# The grammar is committed and diffed by test_tmgrammar.sh, so the `sort` below
# has to collate the same way everywhere: a name with an underscore sorts one
# way under en_US and another under C.
LC_ALL=C; export LC_ALL
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
out="${1:-$root/editors/vscode/word.tmLanguage.json}"
src="$root/compiler/word.w"

# Builtins: every name builtin_arity answers for. That function is the compiler's
# definition of "always-live callable name", so this list is SPEC §9's.
builtins=$(sed -n '/^builtin_arity(name)/,/^    return 0 - 1/p' "$src" \
           | grep -oE 'name == "[a-z_]+"' | sed 's/.*"\(.*\)".*/\1/' | sort -u | tr '\n' '|' | sed 's/|$//')
# Module functions: the names add_module_funcs registers (no import needed).
modfuncs=$(sed -n '/^add_module_funcs(an, modname)/,/^arity_chk/p' "$src" \
           | grep -oE 'mf_add\([a-z_]+, "[a-z_]+"' | sed 's/.*"\(.*\)".*/\1/' | sort -u | tr '\n' '|' | sed 's/|$//')
modules=$(sed -n '/^is_module_name(modname)/,/^    return 0/p' "$src" \
           | grep -oE 'modname == "[a-z_]+"' | sed 's/.*"\(.*\)".*/\1/' | sort -u | tr '\n' '|' | sed 's/|$//')

[ -n "$builtins" ] || { echo "gen_tmgrammar: could not read the builtin list"; exit 1; }
[ -n "$modfuncs" ] || { echo "gen_tmgrammar: could not read the module functions"; exit 1; }
[ -n "$modules" ]  || { echo "gen_tmgrammar: could not read the module names"; exit 1; }

cat > "$out" <<EOF
{
  "\$schema": "https://raw.githubusercontent.com/martinring/tmlanguage/master/tmlanguage.json",
  "name": "word",
  "scopeName": "source.word",
  "fileTypes": ["w"],
  "_generated": "by dev/toolchain/gen_tmgrammar.sh from compiler/word.w; do not edit by hand",
  "patterns": [
    { "include": "#comment" },
    { "include": "#string" },
    { "include": "#char" },
    { "include": "#import" },
    { "include": "#contract" },
    { "include": "#keyword" },
    { "include": "#builtin" },
    { "include": "#module-func" },
    { "include": "#function-def" },
    { "include": "#number" },
    { "include": "#operator" }
  ],
  "repository": {
    "comment": {
      "name": "comment.line.double-slash.word",
      "match": "//.*\$"
    },
    "string": {
      "name": "string.quoted.double.word",
      "begin": "\\"",
      "end": "\\"",
      "patterns": [
        { "name": "constant.character.escape.word", "match": "\\\\\\\\[ntr0\\\\\\\\'\\"]" },
        { "name": "invalid.illegal.unknown-escape.word", "match": "\\\\\\\\[^ntr0\\\\\\\\'\\"]" }
      ]
    },
    "char": {
      "name": "string.quoted.single.word",
      "match": "'(\\\\\\\\[ntr0\\\\\\\\'\\"]|[^'])'"
    },
    "import": {
      "match": "^\\\\s*(import)\\\\s+($modules)\\\\b",
      "captures": {
        "1": { "name": "keyword.control.import.word" },
        "2": { "name": "support.class.module.word" }
      }
    },
    "contract": {
      "match": "\\\\b([A-Za-z_][A-Za-z0-9_]*)(:)(before|after)\\\\b",
      "captures": {
        "1": { "name": "entity.name.function.word" },
        "2": { "name": "punctuation.separator.word" },
        "3": { "name": "keyword.other.contract.word" }
      }
    },
    "keyword": {
      "name": "keyword.control.word",
      "match": "\\\\b(if|else|loop|return|break)\\\\b"
    },
    "builtin": {
      "name": "support.function.builtin.word",
      "match": "\\\\b($builtins)\\\\b(?=\\\\s*\\\\()"
    },
    "module-func": {
      "name": "support.function.module.word",
      "match": "\\\\b($modfuncs)\\\\b(?=\\\\s*\\\\()"
    },
    "function-def": {
      "match": "^([A-Za-z_][A-Za-z0-9_]*)\\\\s*(?=\\\\()",
      "captures": { "1": { "name": "entity.name.function.word" } }
    },
    "number": {
      "name": "constant.numeric.word",
      "match": "\\\\b[0-9][0-9_]*(\\\\.[0-9][0-9_]*)?\\\\b"
    },
    "operator": {
      "name": "keyword.operator.word",
      "match": "==|!=|<=|>=|&&|\\\\|\\\\||<<|>>|[-+*/%.<>!~&|^=]"
    }
  }
}
EOF
echo "wrote $out"
echo "  keywords : if else loop return break  (+ contextual: before after result import in)"
echo "  builtins : $builtins"
echo "  modules  : $modules"
