#!/bin/sh
# test_fuzz_json.sh: fuzzing json.parse.
#
# `json.parse` runs on whatever a server sent, before a program has looked at
# any of it, which puts it with the X.509, TLS, DNS and HTTP decoders that
# test_fuzz.sh, test_fuzz_tls.sh and test_fuzz_net.sh cover.
#
# SPEC 12.3: malformed text (a syntax error, trailing junk, or nesting deeper
# than 1000) returns `none`. So for any bytes there's one acceptable outcome,
# "it returned", and three failures:
#
#   - a fault (exit 70): the parser trusted a length or an index from the input
#   - a hang: a parse loop the input controls
#   - a signal: worse than either
#
# For input that does parse, the round trip has to be stable: stringify(v) must
# parse again and render the same. That catches a renderer writing text its own
# parser won't read back, which is how `{"a":none}` was found.
set -e
LC_ALL=C; export LC_ALL
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; cd "$root"
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3 (mutation driver)"; exit 0; }
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 10"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/p"
cp "$here/fuzz/fuzz_json.w" "$tmp/p/app.w"
"$WORD" build "$tmp/p/app.w" -o "$tmp/probe" >"$tmp/err" 2>&1 || {
  echo "FAIL: could not build the probe:"; sed 's/^/  /' "$tmp/err"; exit 1; }

cases=0; bad=0
judge() { # judge <label> <file>
  out=$($TO "$tmp/probe" "$2" 2>&1); rc=$?
  cases=$((cases + 1))
  case "$rc" in
    0)   return 0 ;;
    124) echo "  FAIL: $1 -- parse hung (10s)"; bad=$((bad + 1)); return 1 ;;
    70)  # The driver prints the kind before it round-trips, so a fault after
         # that line came from the renderer and one before it from the parser.
         # Neither is allowed. stringify refuses `none` and a non-finite float
         # (SPEC 3.8, 12.3), and parse produces neither: a number past the
         # double's range makes the whole document none instead of an inf
         # inside it. This case used to let "not JSON values" faults through,
         # which hid parse("[1e400]") handing stringify an inf.
         echo "  FAIL: $1 -- FAULTED at exit 70: $(printf '%s' "$out" | tail -1)"
         bad=$((bad + 1)); return 1 ;;
    1)   echo "  FAIL: $1 -- $(printf '%s' "$out" | tail -1)"; bad=$((bad + 1))
         cp "$2" "$tmp/last_failure.json"; return 1 ;;
    *)   if [ "$rc" -ge 128 ]; then echo "  FAIL: $1 -- signal $((rc - 128))"
         else echo "  FAIL: $1 -- unexpected exit $rc"; fi
         bad=$((bad + 1)); return 1 ;;
  esac
}

# ---- seeds -----------------------------------------------------------------
# Documents that exercise each shape the parser has a branch for, including the
# ones the value model treats specially (SPEC 3.8: the three JSON words are
# singletons, and a round trip has to keep them).
python3 - "$tmp" <<'PY'
import sys, os, json
tmp = sys.argv[1]
os.makedirs(os.path.join(tmp, "seed"), exist_ok=True)
seeds = [
    '{"a":1,"b":"two","c":[1,2,3],"d":{"e":null},"f":true,"g":false}',
    '[1,2,3,4,5]', '"just a string"', '42', '-17', '3.14', '1e-9', 'true', 'false', 'null',
    '{}', '[]', '[[[[[1]]]]]', '{"k":{"k":{"k":{"k":1}}}}',
    '{"esc":"a\\nb\\tc\\"d\\\\e\\/f"}', '{"u":"\\u00e9\\u4e2d\\ud83d\\ude00"}',
    '{"big":12345678901234567890,"neg":-0.0,"exp":2.5E+3}',
    '{"dup":1,"dup":2}', '[' + ','.join(['0']*500) + ']',
    '{"nested":' + '['*200 + ']'*200 + '}',
    '  \\t\\n {"ws": 1}   \\n ',
]
for i, s in enumerate(seeds):
    open(os.path.join(tmp, "seed", "%03d.json" % i), "w").write(s)
PY
for f in "$tmp"/seed/*.json; do judge "seed $(basename "$f")" "$f" || true; done
echo "  ok: $cases seed documents"

# ---- truncation ------------------------------------------------------------
before=$cases
for f in "$tmp"/seed/*.json; do
  n=$(wc -c < "$f" | tr -d ' ')
  i=0
  while [ "$i" -lt "$n" ]; do
    head -c "$i" "$f" > "$tmp/m.json"
    judge "truncate $(basename "$f") @ $i" "$tmp/m.json" || true
    i=$((i + 1))
    [ "$i" -gt 120 ] && break
  done
done
echo "  ok: $((cases - before)) truncations"

# ---- byte corruption + structural abuse ------------------------------------
before=$cases
python3 - "$tmp" <<'PY'
import sys, os, random, glob
tmp = sys.argv[1]
random.seed(20260905)
os.makedirs(os.path.join(tmp, "mut"), exist_ok=True)
poke = list(b'{}[]",:\\0.eE-+ \t\n') + [0x00, 0xff, 0x80]
n = 0
for f in sorted(glob.glob(os.path.join(tmp, "seed", "*.json"))):
    b = open(f, "rb").read()
    if not b:
        continue
    for _ in range(60):
        c = bytearray(b)
        for _ in range(random.randrange(1, 4)):
            c[random.randrange(len(c))] = random.choice(poke)
        open(os.path.join(tmp, "mut", "%05d.json" % n), "wb").write(bytes(c)); n += 1
# Structural abuse the mutations will not reach on their own.
extra = [
    b'[' * 2000, b'{' * 2000, b'[' * 1200 + b']' * 1200,
    b'{"a":' * 1500 + b'1' + b'}' * 1500,
    b'"' + b'a' * 200000 + b'"', b'[' + b'1,' * 50000 + b'1]',
    b'\xff\xfe\x00\x01', b'', b' ', b'nul', b'tru', b'fals', b'-', b'.', b'1e', b'1e+',
    b'{"a"}', b'{"a":}', b'{,}', b'[,]', b'[1,]', b'{"a":1,}', b'"\\u"', b'"\\ud800"',
    b'"\\udfff\\udfff"', b'"unterminated', b'{"a":"unterminated}',
    # the boundaries SPEC 12.3 and RFC 8259 draw: exactly 1000 levels round-trips,
    # a number past the double range is none, and the grammar is RFC 8259's
    b'[' * 1000 + b'1' + b']' * 1000, b'{"a":' * 1000 + b'"v"' + b'}' * 1000,
    b'1e400', b'[1e400]', b'{"a":-1e400}', b'-1e999999999', b'1e-999999999',
    b'0.' + b'0' * 500 + b'1e500', b'1' + b'0' * 500 + b'e-450', b'[1.7976931348623157e308]',
    b'01', b'-01', b'1.', b'-.5', b'1.e5', b'"\\x"', b'"a\tb"', b'"\\uZZZZ"',
]
for e in extra:
    open(os.path.join(tmp, "mut", "%05d.json" % n), "wb").write(e); n += 1
PY
for f in "$tmp"/mut/*.json; do judge "mutant $(basename "$f")" "$f" || true; done
echo "  ok: $((cases - before)) mutations and structural cases"

echo "test_fuzz_json: $cases cases, $bad failures"
[ "$bad" = 0 ]
