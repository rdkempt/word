#!/bin/sh
# test_fuzz_frontend.sh: fuzzing the compiler's own front end.
#
# The other fuzz targets here take bytes a server sent. This one takes the
# input every user of the language hands over first: a source file. A
# malformed `.w` goes straight into the lexer, the parser and the analyzer, and
# SPEC 10.1 says what they do with it:
#
#   A rejected program is reported as one diagnostic in the form
#   file:line:col: message, the build writes no executable, and exits non-zero.
#   A malformed parse is reported the same way, at the token that's wrong. The
#   compiler never falls through to an internal fault with a line number from
#   its own source.
#
# So for any input there are two acceptable outcomes: it compiled, or it was
# refused with a located diagnostic. Anything else is a bug:
#
#   - a signal (the compiler crashed on user input)
#   - a hang (a parse loop whose bound the input controls)
#   - exit 70, word's run-time fault code. The compiler is a word program, so
#     this means the compiler itself faulted, say an index out of bounds in the
#     parser, reported against compiler/word.w instead of the user's file.
#   - a diagnostic with no file:line:col, which shows an internal stage's
#     wording to someone who made a typo
#
# The last one has happened: `wasm: undefined symbol: rt_to_double` reached a
# user who passed a map to a function doing arithmetic, and that's the kind of
# thing this suite is meant to find.
#
# Mutations are applied to real seeds (every example and every net library
# module), because a random byte string is rejected by the lexer at the first
# character and tests nothing. Truncation finds the parser reading past the end
# of input, byte corruption finds a token boundary it didn't expect, and line
# surgery (duplicating, dropping and re-indenting lines) reaches the indent
# stack, which is the part of this lexer with real state.
set -e
LC_ALL=C; export LC_ALL
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; cd "$root"
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3 (mutation driver)"; exit 0; }
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 10"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/p"

# One case: build $tmp/p/m.w and judge the outcome. Prints nothing when the
# outcome is acceptable, so the log stays readable at thousands of cases.
judge() { # judge <label>
  out=$($TO "$WORD" build "$tmp/p/m.w" -o "$tmp/p/m" 2>&1); rc=$?
  case "$rc" in
    0) return 0 ;;                       # it compiled: fine
    1) : ;;                              # refused: check HOW below
    124) echo "  FAIL: $1 -- the compiler hung (10s)"; return 1 ;;
    70) echo "  FAIL: $1 -- the compiler itself faulted (exit 70): $(printf '%s' "$out" | head -1)"; return 1 ;;
    *)  if [ "$rc" -ge 128 ]; then
          echo "  FAIL: $1 -- the compiler died on signal $((rc - 128)): $(printf '%s' "$out" | head -1)"
        else
          echo "  FAIL: $1 -- unexpected exit $rc: $(printf '%s' "$out" | head -1)"
        fi
        return 1 ;;
  esac
  # Refused. SPEC 10.1: one located diagnostic, and nothing on stdout.
  first=$(printf '%s' "$out" | head -1)
  case "$first" in
    *.w:[0-9]*:[0-9]*:*) return 0 ;;
  esac
  # A few refusals aren't about a place in the file, so they have no location:
  # an unreadable path, a usage message, or `word: refusing` to write output.
  case "$first" in
    "cannot read "*|"word: refusing"*|"usage: "*) return 0 ;;
  esac
  echo "  FAIL: $1 -- refused without a located diagnostic: $first"
  return 1
}

# The net library is text in compiler/word.w's NETLIB region, not files on
# disk, so each module is written to a temp directory. They're large seeds with
# long lines, deep nesting and every token, next to the examples.
netdir="$tmp/netlib"; mkdir -p "$netdir"
for m in $(python3 "$root/dev/toolchain/netlib_cat.py" --list); do
  python3 "$root/dev/toolchain/netlib_cat.py" "$m" > "$netdir/$m.w"
done
seeds=""
for f in examples/*/*.w "$netdir"/*.w; do
  [ -f "$f" ] && seeds="$seeds $f"
done
[ -n "$seeds" ] || { echo "FAIL: no seed sources found"; exit 1; }

cases=0; bad=0

# ---- 1. truncation ---------------------------------------------------------
# Every prefix at a coarse stride. A parser that reads one token past the end of
# input shows up here, and so does an indent stack left mid-block at EOF.
for f in $seeds; do
  n=$(wc -c < "$f" | tr -d ' ')
  step=$(( n / 24 )); [ "$step" -lt 1 ] && step=1
  i=0
  while [ "$i" -lt "$n" ]; do
    head -c "$i" "$f" > "$tmp/p/m.w"
    cases=$((cases + 1))
    judge "truncate $f @ $i" || bad=$((bad + 1))
    i=$((i + step))
  done
done
echo "  ok: $cases truncations of $(printf '%s' "$seeds" | wc -w | tr -d ' ') sources"

# ---- 2. byte corruption ----------------------------------------------------
# Bytes chosen for what they mean to this lexer: a quote and a backslash (string
# state), a brace and a bracket (the newline rule inside unmatched brackets), a
# tab (an indent error by SPEC 2.2), a NUL and a high byte (non-ASCII outside a
# literal is an error, and has to be a located one), plus a parenthesis, a dot
# and a single quote.
before=$cases
python3 - "$tmp" $seeds <<'PY'
import sys, os, random
tmp, seeds = sys.argv[1], sys.argv[2:]
random.seed(20260905)
poke = [0x22, 0x5c, 0x7b, 0x5d, 0x09, 0x00, 0xff, 0x28, 0x2e, 0x27]
out = []
for f in seeds:
    b = open(f, "rb").read()
    if not b:
        continue
    for _ in range(40):
        i = random.randrange(len(b))
        v = random.choice(poke)
        c = bytearray(b); c[i] = v
        out.append((f, i, v, bytes(c)))
os.makedirs(os.path.join(tmp, "corrupt"), exist_ok=True)
with open(os.path.join(tmp, "corrupt.idx"), "w") as idx:
    for n, (f, i, v, data) in enumerate(out):
        open(os.path.join(tmp, "corrupt", "%05d.w" % n), "wb").write(data)
        idx.write("%05d\t%s\t%d\t0x%02x\n" % (n, f, i, v))
PY
while IFS="$(printf '\t')" read -r n f off val; do
  cp "$tmp/corrupt/$n.w" "$tmp/p/m.w"
  cases=$((cases + 1))
  judge "corrupt $f byte $off -> $val" || bad=$((bad + 1))
done < "$tmp/corrupt.idx"
echo "  ok: $((cases - before)) single-byte corruptions"

# ---- 3. line surgery -------------------------------------------------------
# The indent stack is the stateful part of this lexer (SPEC 2.2: a block is an
# indent, and returning to an indentation matching no open block is an error).
# Dropping, duplicating and re-indenting lines is how to reach it.
before=$cases
python3 - "$tmp" $seeds <<'PY'
import sys, os, random
tmp, seeds = sys.argv[1], sys.argv[2:]
random.seed(9051)
os.makedirs(os.path.join(tmp, "lines"), exist_ok=True)
n = 0
with open(os.path.join(tmp, "lines.idx"), "w") as idx:
    for f in seeds:
        L = open(f, "rb").read().split(b"\n")
        if len(L) < 4:
            continue
        for _ in range(30):
            m = list(L)
            what = random.choice(("drop", "dup", "indent", "dedent", "swap"))
            i = random.randrange(len(m))
            if what == "drop":
                del m[i]
            elif what == "dup":
                m.insert(i, m[i])
            elif what == "indent":
                m[i] = b"    " + m[i]
            elif what == "dedent":
                m[i] = m[i].lstrip()
            else:
                j = random.randrange(len(m)); m[i], m[j] = m[j], m[i]
            open(os.path.join(tmp, "lines", "%05d.w" % n), "wb").write(b"\n".join(m))
            idx.write("%05d\t%s\t%s\t%d\n" % (n, f, what, i))
            n += 1
PY
while IFS="$(printf '\t')" read -r n f what ln; do
  cp "$tmp/lines/$n.w" "$tmp/p/m.w"
  cases=$((cases + 1))
  judge "$what line $ln of $f" || bad=$((bad + 1))
done < "$tmp/lines.idx"
echo "  ok: $((cases - before)) line mutations"

echo "test_fuzz_frontend: $cases cases, $bad failures"
[ "$bad" = 0 ]
