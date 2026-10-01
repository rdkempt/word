#!/bin/sh
# test_opt_differential.sh: the optimizer, checked against a second compiler
# instead of against expected answers.
#
# SPEC 3.4 and 3.5 say the uniqueness pass, the in-place append, the dead-store
# rewind, the hoisted loop length, the elided bounds check and the rest have no
# meaning attached: a program can't tell which of them fired. The hand-written
# suites check them one at a time. This one checks how they interact (an alias
# made through a call, an alias that only exists inside a nested container, a
# map key that is also a loop subject, a u32 local that overflows, a float
# accumulator inside a call the inliner wants), which is hard to write by hand
# because you'd have to guess which pair matters.
#
# It builds a second compiler with the optimizer's gates pinned to their
# conservative answers (deopt_compiler.py), generates programs that put those
# shapes next to each other (gen_opt_programs.py), compiles each with both, and
# requires the same output and exit status. There's no expected answer to
# write, so there can be hundreds of programs.
#
# Two things are checked first, because the comparisons mean nothing without
# them:
#
#   1. the patched compiler really is deoptimized: it must emit different
#      assembly from the release compiler for a program that uses those
#      optimizations. Otherwise every case would pass trivially.
#   2. the patched compiler is still correct: test_guarantees.sh and
#      test_builtins.sh pass with it. Otherwise a difference would measure the
#      patch and not the optimizer.
#
# No `set -e`: a failing case is counted, not fatal.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; cd "$root"
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "test_opt_differential: SKIP (no python3)"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 20"

# How many generated programs. The default keeps CI inside a minute; raise it
# for a soak (OPT_DIFF_N=5000 sh dev/toolchain/test_opt_differential.sh).
N=${OPT_DIFF_N:-200}

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1 -- $2"; }

# ---- the second compiler --------------------------------------------------
if ! python3 "$here/deopt_compiler.py" "$root/compiler/word.w" "$tmp/deopt.w" > "$tmp/patchlog" 2>&1; then
  echo "FAIL: could not patch the compiler's optimiser gates"; cat "$tmp/patchlog"; exit 1
fi
cat "$tmp/patchlog" | sed 's/^/  /'
if ! "$WORD" build "$tmp/deopt.w" -o "$tmp/wdeopt" > "$tmp/berr" 2>&1; then
  echo "FAIL: the deoptimised compiler does not build"; head -3 "$tmp/berr"; exit 1
fi
chmod +x "$tmp/wdeopt"
ok "a compiler with the optimiser's gates pinned builds"

# ---- 1. it is really deoptimised ------------------------------------------
# This program uses the optimizations the patch turns off: an append to a
# unique local, a loop whose guard checks the subscript, a length that doesn't
# change in the loop, an accessor the inliner takes, an integer that stays
# inside 32 bits, and a temporary passed to a call.
cat > "$tmp/probe.w" <<'EOF'
first(r)
    return r[0]

s = "" . "a"
i = 0
loop i < 200
    s = s . "b"
    i = i + 1
a = array(8)
j = 0
loop j < len(a)
    a[j] = j * 7
    j = j + 1
n = 1
k = 0
loop k < 50
    n = (n * 131) % 4294967296
    k = k + 1
out(len(s) . " " . first(a) . " " . a[7] . " " . n . " " . len(s . "tail"))
EOF
"$WORD"       build -asm "$tmp/probe.w" > "$tmp/rel.s"   2>/dev/null
"$tmp/wdeopt" build -asm "$tmp/probe.w" > "$tmp/deopt.s" 2>/dev/null
if cmp -s "$tmp/rel.s" "$tmp/deopt.s"; then
  bad "the patched compiler emits different code" \
      "identical assembly: the differential would be comparing the release compiler with itself"
else
  ok "the patched compiler emits different code ($(diff "$tmp/rel.s" "$tmp/deopt.s" | grep -c '^[<>]') lines differ)"
fi

# ...and it must give the same answer.
r=$("$WORD" run "$tmp/probe.w" 2>&1)
d=$("$tmp/wdeopt" run "$tmp/probe.w" 2>&1)
if [ "$r" = "$d" ]; then ok "and the same answer for it [$r]"
else bad "the probe disagrees" "release [$r] deopt [$d]"; fi

# ---- 2. it is still a correct compiler ------------------------------------
for suite in test_guarantees test_builtins; do
  if WORD="$tmp/wdeopt" sh "$here/$suite.sh" > "$tmp/s.log" 2>&1; then
    ok "$suite passes with the optimiser off ($(tail -1 "$tmp/s.log"))"
  else
    bad "$suite with the optimiser off" "$(grep -m3 'FAIL' "$tmp/s.log" | tr '\n' ' ')"
  fi
done

# ---- 3. the differential --------------------------------------------------
# A case is one generated program, built by both compilers. stdout, stderr and
# the exit status must all match. Both builds get the same path, so a fault's
# located message has to match too.
QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
adiff=0; aran=0

seed=1
while [ "$seed" -le "$N" ]; do
  python3 "$here/gen_opt_programs.py" "$seed" "$tmp/p.w"
  e1=$("$WORD"       build "$tmp/p.w" -o "$tmp/pr" 2>&1)
  e2=$("$tmp/wdeopt" build "$tmp/p.w" -o "$tmp/pd" 2>&1)
  if [ -n "$e1" ] || [ -n "$e2" ]; then
    bad "seed $seed" "a generated program did not compile: [$e1] [$e2]"
    cp "$tmp/p.w" "$tmp/failed-$seed.w"
    seed=$((seed+1)); continue
  fi
  o1=$($TO "$tmp/pr" 2>&1 </dev/null); r1=$?
  o2=$($TO "$tmp/pd" 2>&1 </dev/null); r2=$?
  if [ "$o1" != "$o2" ] || [ "$r1" != "$r2" ]; then
    fail=$((fail+1))
    echo "  FAIL seed $seed -- the optimiser changed the answer (rc $r1 vs $r2)"
    echo "    release: $(printf '%s' "$o1" | tr '\n' '|' | cut -c1-160)"
    echo "    plain:   $(printf '%s' "$o2" | tr '\n' '|' | cut -c1-160)"
    cp "$tmp/p.w" "/tmp/opt-diff-$seed.w" 2>/dev/null || true
  else
    pass=$((pass+1))
  fi

  # The arm64 backend shares the uniqueness pass and the u32 locals, so when
  # qemu is there, every fifth program is also built for arm64 by both
  # compilers, and the two runs must agree.
  if [ -n "$QEMU" ] && [ $((seed % 5)) = 0 ]; then
    if "$WORD" build -arm64 "$tmp/p.w" -o "$tmp/pa" >/dev/null 2>&1 &&
       "$tmp/wdeopt" build -arm64 "$tmp/p.w" -o "$tmp/pb" >/dev/null 2>&1; then
      chmod +x "$tmp/pa" "$tmp/pb"
      a1=$($TO $QEMU "$tmp/pa" 2>&1 </dev/null); q1=$?
      a2=$($TO $QEMU "$tmp/pb" 2>&1 </dev/null); q2=$?
      aran=$((aran+1))
      if [ "$a1" != "$a2" ] || [ "$q1" != "$q2" ]; then
        adiff=$((adiff+1))
        echo "  FAIL seed $seed (arm64) -- rc $q1 vs $q2"
        echo "    release: $(printf '%s' "$a1" | tr '\n' '|' | cut -c1-160)"
        echo "    plain:   $(printf '%s' "$a2" | tr '\n' '|' | cut -c1-160)"
      fi
    fi
  fi
  seed=$((seed+1))
done

# ---- 4. the rotate idiom and the funnel shift, against the arithmetic ------
# `(x << L) | (x >> (32 - L))` is a 32-bit rotation only when something keeps
# the low 32 bits and x fits in 32 bits (the rotate idiom in compiler/word.w).
# With no mask it used to be taken anyway in a program with no float in it,
# where `(x << 8) | (x >> 24)` with x = 4278190080 printed 255 on both targets
# instead of 1095216660735. This program has no float, so every rotate and
# funnel shape the compiler knows is in play, and python works out what the
# arithmetic says. The operands and answers have bits above bit 31, masked and
# not, over several shift pairs, at the top level, through a parameter, and
# into locals the u32 pass keeps raw. The release compiler is checked on both
# targets, and the patched one too, since both have to say what python says.
python3 - "$tmp/rot.w" "$tmp/rot.want" <<'PY'
import sys
vals = [4278190080, 4294967295, 2147483648, 305419896, 1, 0, 1099511627781,
        72057594037927935, 2305843009213693951, -2, -4278190080]
pairs = [(8, 24), (1, 31), (31, 1), (16, 16), (7, 25), (13, 19), (25, 7)]
M = 4294967295
def shl(x, n):
    # word's << keeps 63 bits and drops what's shifted past them (SPEC 3.1)
    r = (x << n) & ((1 << 63) - 1)
    return r - (1 << 63) if r >= (1 << 62) else r
def rot(x, L):
    return shl(x, L) | (x >> (32 - L))
def fun(a, b, n):
    return (a >> n) | shl(b & ((1 << n) - 1), 32 - n)
def lit(v):
    return str(v) if v >= 0 else "0 - %d" % -v
src, want = [], []
for L, R in pairs:
    # A two-line body, so the call isn't inlined and x stays a parameter.
    src += ["fr%d(x)" % L,
            "    r = (x << %d) | (x >> %d)" % (L, R),
            "    m = ((x >> %d) | (x << %d)) & 4294967295" % (R, L),
            "    f = (x >> %d) | ((x & %d) << %d)" % (L, (1 << L) - 1, R),
            "    return r . \" \" . m . \" \" . f", ""]
for i, v in enumerate(vals):
    src.append("x%d = %s" % (i, lit(v)))
src.append("u = 0")
for i, v in enumerate(vals):
    b = vals[(i + 3) % len(vals)]
    j = (i + 3) % len(vals)
    for L, R in pairs:
        x = "x%d" % i
        src.append("out((%s << %d) | (%s >> %d))" % (x, L, x, R)); want.append(rot(v, L))
        src.append("out((%s >> %d) | (%s << %d))" % (x, R, x, L)); want.append(rot(v, L))
        src.append("out(((%s << %d) | (%s >> %d)) & 4294967295)" % (x, L, x, R)); want.append(rot(v, L) & M)
        src.append("out(4294967295 & ((%s >> %d) | (%s << %d)))" % (x, R, x, L)); want.append(rot(v, L) & M)
        # u only ever holds a masked value, so it's a raw u32 local.
        src.append("u = ((%s << %d) | (%s >> %d)) & 4294967295" % (x, L, x, R))
        src.append("out(u)"); want.append(rot(v, L) & M)
        src.append("u = (((%s >> %d) | (%s << %d)) ^ ((%s >> 3) | (%s << 29)) ^ (%s >> 10)) & 4294967295"
                   % (x, R, x, L, x, x, x))
        src.append("out(u)"); want.append((rot(v, L) ^ rot(v, 29) ^ (v >> 10)) & M)
        src.append("u = ((((%s << %d) | (%s >> %d)) & 4294967295) + u) & 4294967295" % (x, L, x, R))
        src.append("out(u)"); want.append(((rot(v, L) & M) + ((rot(v, L) ^ rot(v, 29) ^ (v >> 10)) & M)) & M)
        src.append("out((%s >> %d) | ((x%d & %d) << %d))" % (x, L, j, (1 << L) - 1, R)); want.append(fun(v, b, L))
        src.append("out(((%s >> %d) | ((x%d & %d) << %d)) & 4294967295)" % (x, L, j, (1 << L) - 1, R)); want.append(fun(v, b, L) & M)
        src.append("out(fr%d(%s))" % (L, x))
        want.append("%d %d %d" % (rot(v, L), rot(v, L) & M, fun(v, v, L)))
open(sys.argv[1], "w", newline="\n").write("\n".join(src) + "\n")
open(sys.argv[2], "w", newline="\n").write("\n".join(str(w) for w in want) + "\n")
PY
rotcase() { # <label> <how to run the binary...>
  label=$1; shift
  "$@" > "$tmp/rot.got" 2>&1
  if cmp -s "$tmp/rot.want" "$tmp/rot.got"; then ok "the rotate and funnel shapes say what the arithmetic says ($label, $(wc -l < "$tmp/rot.want") values)"
  else bad "the rotate and funnel shapes ($label)" "$(diff "$tmp/rot.want" "$tmp/rot.got" | head -4 | tr '\n' ' ')"; fi
}
if "$WORD" build "$tmp/rot.w" -o "$tmp/rotx" > "$tmp/rerr" 2>&1; then rotcase "x86-64" "$tmp/rotx"
else bad "the rotate program builds" "$(head -2 "$tmp/rerr")"; fi
if "$tmp/wdeopt" build "$tmp/rot.w" -o "$tmp/rotd" > "$tmp/rerr" 2>&1; then rotcase "x86-64, optimiser off" "$tmp/rotd"
else bad "the rotate program builds with the optimiser off" "$(head -2 "$tmp/rerr")"; fi
if [ -n "$QEMU" ]; then
  if "$WORD" build -arm64 "$tmp/rot.w" -o "$tmp/rota" > "$tmp/rerr" 2>&1; then rotcase "arm64" $QEMU "$tmp/rota"
  else bad "the rotate program builds for arm64" "$(head -2 "$tmp/rerr")"; fi
else
  echo "  (no qemu-aarch64: the rotate program ran on x86-64 only)"
fi

fail=$((fail + adiff))
echo "test_opt_differential: $N generated programs, $pass checks passed, $fail failed"
[ "$aran" = 0 ] || echo "  (of those, $aran were also run on arm64 under qemu)"
[ "$fail" = 0 ]
