#!/bin/sh
# test_gaps.sh: coverage the rest of the suite didn't have.
#
# It started from an audit that mapped every SPEC §9 builtin and every SPEC
# §10.2 run-time fault against the existing tests, which found three kinds of
# gap:
#
#   1. Builtins with no test anywhere: err() and ended(). ended() is what ends
#      the stdin loop of §13.9, and err() is how a program writes to fd 2, but
#      nothing checked that it goes to fd 2 and not to fd 1.
#   2. Run-time faults the SPEC promises and nothing asserted: divide or modulo
#      by zero, a shift out of range, an index out of bounds, a write to a
#      literal, a bad slice, a negative length, out() of a non-character, and
#      the kind faults decided at run time. Each must be a located message on
#      stderr and exit 70, never a signal.
#   3. A map key that isn't text. `m[5]`, `m[5] = 1` and `has(m, 5)` each died
#      on SIGSEGV: rt_map_hash dereferenced the tagged integer as a pointer, so
#      an integer passed for a region, which SPEC §3.6 says can't happen.
#
# Two later reports belong here too. An element count past 2^61 wrapped the
# allocator's size to a few bytes, and the zero fill then wrote over everything
# after it until the process died of SIGSEGV. And a path was handed to the OS
# with the low byte of each element, cut at 4094 bytes and at the first NUL, so
# the file opened wasn't always the file named.
#
# No `set -e`, since most cases here are meant to exit nonzero.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
# On Windows word.exe is a native program: a path written into a program's text
# has to be one Windows can open, and /tmp/x is \tmp\x on the current drive.
# hostpath is the identity everywhere else. win=1 marks the cases that ask
# Linux-only questions (strace, running an ELF), which skip there.
. "$here/hostpath.sh"; win=0
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in msys*|cygwin*|win32|MINGW*|MSYS*|CYGWIN*) win=1;; esac
WORD=${WORD:-"$root/word"}; tmp=$(hostpath "$(mktemp -d)"); trap 'rm -rf "$tmp"' EXIT
cd "$root"
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 20"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  OK   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1 -- $2"; }
p="$tmp/p.w"; exe="$tmp/p"

# Build+run; expect exit 0 and stdout exactly $2.
crun() { cat > "$p"; nm="$1"; want="$2"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then bad "$nm" "build failed: $("$WORD" build "$p" -o "$exe" 2>&1 | head -1)"; return; fi
  got=$($TO "$exe" 2>&1); rc=$?
  if [ "$got" = "$want" ] && [ "$rc" = 0 ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc want [$want] rc=0"; fi; }

# The program must be rejected at build time, with a located diagnostic
# containing $2 and nothing on stdout.
crej() { cat > "$p"; nm="$1"; sub="$2"
  sout=$("$WORD" build "$p" -o "$exe" 2>"$tmp/diag"); rc=$?
  got=$(cat "$tmp/diag")
  case "$got" in *"$sub"*) m=1;; *) m=0;; esac
  case "$got" in *"p.w:"*) loc=1;; *) loc=0;; esac
  if [ "$m" = 1 ] && [ "$rc" = 1 ] && [ "$loc" = 1 ] && [ -z "$sout" ]; then ok "$nm"
  else bad "$nm" "stderr=[$got] rc=$rc (want located [$sub], rc=1)"; fi; }

# Build OK, then run and expect a clean fault: stderr contains $2, exit 70, and
# the message is located as `<file>:<line>: `, the same shape a compile
# diagnostic uses (SPEC §10.1), so one editor rule jumps to either. A signal
# death (rc >= 128) fails.
cdie() { cat > "$p"; nm="$1"; sub="$2"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then bad "$nm" "build failed (expected a run-time fault)"; return; fi
  got=$($TO "$exe" 2>&1); rc=$?
  case "$got" in *"$sub"*) m=1;; *) m=0;; esac
  case "$got" in *"p.w:"*) loc=1;; *) loc=0;; esac
  if [ "$m" = 1 ] && [ "$rc" = 70 ] && [ "$loc" = 1 ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc want substr [$sub], rc=70, located=$loc"; fi; }

# Like cdie, but runs the program with the stack pinned at 1 MB. Whether a given
# nesting depth exhausts the stack depends on RLIMIT_STACK, which is 8 MB on a
# typical machine and unlimited on some CI runners, where the same program
# succeeds instead of tripping the guard. Either outcome is correct, since what
# matters is a diagnostic instead of a SIGSEGV, and pinning the limit gives the
# same result on every machine.
cdie_stack() { cat > "$p"; nm="$1"; sub="$2"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then bad "$nm" "build failed (expected a run-time fault)"; return; fi
  if ! ( ulimit -s 1024 ) 2>/dev/null; then ok "$nm (SKIP: cannot pin the stack limit)"; return; fi
  got=$( ( ulimit -s 1024; exec $TO "$exe" ) 2>&1 ); rc=$?
  case "$got" in *"$sub"*) m=1;; *) m=0;; esac
  case "$got" in *"p.w:"*) loc=1;; *) loc=0;; esac
  if [ "$m" = 1 ] && [ "$rc" = 70 ] && [ "$loc" = 1 ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc want substr [$sub], rc=70, located=$loc"; fi; }

# Like crun, with the stack pinned at 8 MB: the Linux default, and what a
# Windows PE reserves.
crun_stack8() { cat > "$p"; nm="$1"; want="$2"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then bad "$nm" "build failed: $("$WORD" build "$p" -o "$exe" 2>&1 | head -1)"; return; fi
  if ! ( ulimit -s 8192 ) 2>/dev/null; then ok "$nm (SKIP: cannot pin the stack limit)"; return; fi
  got=$( ( ulimit -s 8192; exec $TO "$exe" ) 2>&1 ); rc=$?
  if [ "$got" = "$want" ] && [ "$rc" = 0 ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc want [$want] rc=0"; fi; }

echo "== builtins with no previous coverage: ended() =="
# ended() is what makes the read-every-line loop of SPEC §13.9 terminate, and it
# exists because an empty line and end-of-input are both a zero-length region.
cat > "$p" <<'EOF'
n = 0
loop
    if ended()
        break
    line = in()
    n = n + 1
    out("got: " . line)
out("lines: " . n)
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$(printf 'alpha\n42\n\nbeta\n' | $TO "$exe" 2>&1)
  want="got: alpha
got: 42
got: 
got: beta
lines: 4"
  [ "$got" = "$want" ] && ok "ended(): the §13.9 stdin loop reads every line and stops" \
                       || bad "ended(): §13.9 stdin loop" "got [$(echo "$got" | tr '\n' '|')]"
  # An empty line isn't the end of input, so the loop above saw 4 lines, not 2.
  got=$(printf '' | $TO "$exe" 2>&1)
  [ "$got" = "lines: 0" ] && ok "ended(): empty stdin yields no lines" \
                          || bad "ended(): empty stdin" "got [$got]"
  # A final line with no trailing newline is still a line.
  got=$(printf 'x\ny' | $TO "$exe" 2>&1 | tail -1)
  [ "$got" = "lines: 2" ] && ok "ended(): a last line without a newline still counts" \
                          || bad "ended(): unterminated last line" "got [$got]"
else bad "ended(): builds" "build failed"; fi

# ended() before any in() must already know whether input is there (lookahead).
cat > "$p" <<'EOF'
out(ended())
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  a=$(printf '' | $TO "$exe" 2>&1); b=$(printf 'hello\n' | $TO "$exe" 2>&1)
  [ "$a" = true ] && [ "$b" = false ] && ok "ended(): true on empty input, false with input, before any in()" \
                               || bad "ended(): lookahead" "empty=[$a] nonempty=[$b]"
else bad "ended(): lookahead builds" "build failed"; fi

# in() answers a whole line however long it is. A line past 65,536 bytes used to
# come back in pieces, the rest arriving as the next line. This one is 200,000
# bytes of "abcdefghij" and a CR, so the buffer grows twice; the slices are the
# bytes either side of each boundary. arm64 runs it too when qemu is there.
cat > "$p" <<'EOF'
line = in()
out(len(line) . " " . copy(line, 65534, 65538) . " " . copy(line, 131070, 131074) . " " . copy(line, 199998))
line = in()
out(line)
out(ended())
EOF
awk 'BEGIN { s = "abcdefghij"; while (length(s) < 200000) s = s s; printf "%s\r\nbbb\n", substr(s, 1, 200000) }' > "$tmp/long.in"
want="200000 efgh abcd ij
bbb
true"
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$($TO "$exe" < "$tmp/long.in" 2>&1 | tr -d '\r')
  [ "$got" = "$want" ] && ok "in(): a 200,000-byte line is one line" \
                       || bad "in(): a long line" "got [$(echo "$got" | tr '\n' '|' | cut -c1-200)]"
else bad "in(): a long line builds" "build failed"; fi
QEMU=""
[ "$(uname -s)" = Linux ] && QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
if [ -n "$QEMU" ]; then
  if "$WORD" build -arm64 "$p" -o "$exe.a64" >/dev/null 2>&1; then
    got=$($TO "$QEMU" "$exe.a64" < "$tmp/long.in" 2>&1)
    [ "$got" = "$want" ] && ok "in(): a 200,000-byte line is one line on arm64" \
                         || bad "in(): a long line on arm64" "got [$(echo "$got" | tr '\n' '|' | cut -c1-200)]"
  else bad "in(): a long line builds for arm64" "build failed"; fi
fi

# in() scans what its buffer already holds, and the decoder behind in() and
# decode() takes ASCII eight bytes at a time. Every path through them has to
# give what the byte-at-a-time decoder gave, so the input mixes ASCII runs with
# 2-, 3- and 4-byte characters and with bytes that are not UTF-8 (an overlong
# C1 BB, F4 90 80 80 past U+10FFFF, a cut-off E2 82, a lone FF), at every
# alignment: CRLF endings, lines of 65,535, 65,536 and 65,537 bytes, one of
# 210,000, lines that are numbers, and no newline at the end. The two digests
# are the old decoder's.
cat > "$p" <<'EOF'
pieces = text(12)
pieces[0] = "a"
pieces[1] = "hello, world"
pieces[2] = "é"
pieces[3] = "ü€"
pieces[4] = "😀"
pieces[5] = "abcdefgh"
pieces[6] = "12345678901234567"
pieces[7] = " "
pieces[8] = "∑x"
pieces[9] = "ok"
pieces[10] = "tab\there"
pieces[11] = "nl\nx"
bad = bytes(6)
bad[0] = 192
bad[1] = 187
bad[2] = 244
bad[3] = 144
bad[4] = 128
bad[5] = 255
total = 0
chk = 0
i = 0
loop i < 400
    s = ""
    j = 0
    loop j < (i % 23)
        s = s . pieces[(i * 7 + j * 3) % 12]
        j = j + 1
    b = encode(s)
    if i % 5 == 0
        b = b . bad
    if i % 7 == 0
        b = bad . b
    d = decode(b)
    total = total + len(d)
    m = 0
    loop m < len(d)
        chk = (chk * 31 + d[m] + m) % 1000000007
        m = m + 1
    i = i + 1
out(total . " " . chk)
n = 0
loop
    if ended()
        break
    l = in()
    if kind(l) == "number"
        chk = (chk * 7 + l % 1000003) % 1000000007
    else
        n = n + len(l)
        q = 0
        loop q < len(l)
            chk = (chk * 131 + l[q]) % 1000000007
            q = q + 1
out(n . " " . chk)
EOF
cat > "$tmp/mixed.py" <<'EOF'
import random, sys
random.seed(5)
parts = [b"a", b"hello world ", "é".encode(), "ü€".encode(), "\U0001F600".encode(),
         b"abcdefghijklmnop", bytes([0xC1, 0xBB]), bytes([0xF4, 0x90, 0x80, 0x80]),
         bytes([0xE2, 0x82]), b"\t", bytes([0xFF])]
with open(sys.argv[1], "wb") as f:
    for i in range(3000):
        f.write(b"".join(random.choice(parts) for _ in range(random.randrange(0, 40))))
        f.write(b"\r\n" if i % 9 == 0 else b"\n")
        if i == 1000:
            f.write(b"x" * 150000 + "é".encode() * 30000 + b"\n")
        if i == 2000:
            f.write(b"-12345\n77\n4611686018427387903\n4611686018427387904\n\n\r\n")
        if i == 2500:
            f.write(b"y" * 65535 + b"\n" + b"z" * 65536 + b"\n" + b"w" * 65537 + b"\r\n")
    f.write(b"no newline at the end")
EOF
want="22163 604620087
606514 739737443"
if ! command -v python3 >/dev/null 2>&1; then echo "  SKIP in() and decode() over mixed input (no python3)"
elif "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  python3 "$tmp/mixed.py" "$tmp/mixed.in"
  got=$($TO "$exe" < "$tmp/mixed.in" 2>&1 | tr -d '\r')
  [ "$got" = "$want" ] && ok "in() and decode() over mixed and ill-formed UTF-8 answer as the old decoder did" \
                       || bad "in() and decode() over mixed input" "got [$(echo "$got" | tr '\n' '|')] want [$(echo "$want" | tr '\n' '|')]"
  if [ -n "$QEMU" ]; then
    if "$WORD" build -arm64 "$p" -o "$exe.a64" >/dev/null 2>&1; then
      got=$($TO "$QEMU" "$exe.a64" < "$tmp/mixed.in" 2>&1)
      [ "$got" = "$want" ] && ok "in() and decode() over mixed input on arm64" \
                           || bad "in() and decode() over mixed input on arm64" "got [$(echo "$got" | tr '\n' '|')]"
    else bad "in() and decode() builds for arm64" "build failed"; fi
  fi
else bad "in() and decode() over mixed input builds" "build failed"; fi

# copy(), `.` and the in-place append move words 32 bytes at a time below 256
# words and with rep movsq from there on (rt_wmove). Every length from 0 to 600,
# from an odd offset, crosses both edges and every tail length; the digest folds
# every element of every result and is the one the plain rep movsq gave.
crun "word copies of every length from 0 to 600 keep every element" "600 479964441" <<'EOF'
src = text(700)
i = 0
loop i < 700
    src[i] = (i * 7919) % 100003
    i = i + 1
h = 0
n = 0
acc = copy(src, 0, 1)
loop n <= 600
    c = copy(src, 3, 3 + n)
    j = c . copy(src, 1, 1 + (n % 37))
    acc = acc . c
    k = 0
    loop k < len(c)
        h = (h * 31 + c[k]) % 1000000007
        k = k + 1
    k = 0
    loop k < len(j)
        h = (h * 37 + j[k]) % 1000000007
        k = k + 1
    h = (h * 41 + len(acc) + acc[len(acc) - 1]) % 1000000007
    n = n + 1
out((n - 1) . " " . h)
EOF

echo "== builtins with no previous coverage: err() =="
# err() writes to fd 2 so a program can sit in a pipeline (SPEC §9.1). This
# checks which stream each line went to, not just that it was printed.
cat > "$p" <<'EOF'
err("diagnostic")
out("payload")
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  o=$($TO "$exe" 2>/dev/null); e=$($TO "$exe" 2>&1 >/dev/null)
  [ "$o" = "payload" ] && [ "$e" = "diagnostic" ] \
      && ok "err() writes to fd 2 and out() to fd 1, separately" \
      || bad "err() fd split" "stdout=[$o] stderr=[$e]"
else bad "err() builds" "build failed"; fi
# err() renders every kind the way out() does (SPEC §9.1), so each rendering is
# checked on fd 2 alone. A plain 2>&1 capture wouldn't show which stream it was.
cat > "$p" <<'EOF'
err(42)
err("text")
err({a: 1})
err(3.5)
err(array(2))
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  e=$($TO "$exe" 2>&1 >/dev/null | tr '\n' '|')
  [ "$e" = "42|text|{\"a\":1}|3.5|[0,0]|" ] \
      && ok "err() renders number, region, map, float and list like out()" \
      || bad "err() rendering" "stderr=[$e]"
else bad "err() rendering builds" "build failed"; fi

echo "== copy(): direct coverage of the three-argument form =="
crun "copy() takes n elements from index i" "bcd 3" <<'EOF'
s = "abcdef"
t = copy(s, 1, 4)
out(t . " " . len(t))
EOF
crun "copy() of length 0 is an empty region" "0" <<'EOF'
s = "abc"
out(len(copy(s, 1, 1)))
EOF
crun "copy() to the exact end is legal" "true" <<'EOF'
s = "abc"
out(copy(s, 0, 3) == "abc")
EOF
crun "copy() copies: writing the slice leaves the source" "abc xbc" <<'EOF'
s = "abc" . ""
t = copy(s, 0, 3)
t[0] = 'x'
out(s . " " . t)
EOF

echo "== runtime faults SPEC §10.2 promises (message + line + exit 70, never a signal) =="
cdie "divide by zero" "divide by zero" <<'EOF'
a = 10
b = 0
out(a / b)
EOF
cdie "modulo by zero" "divide by zero" <<'EOF'
a = 10
b = 0
out(a % b)
EOF
cdie "shift count of 64 is out of range" "shift out of range" <<'EOF'
a = 1
b = 64
out(a << b)
EOF
cdie "negative shift count is out of range" "shift out of range" <<'EOF'
a = 1
b = 0 - 1
out(a >> b)
EOF
# A count the compiler can see is checked the same way. x86-64 had a
# constant-count path that skipped the range check on the low end, so these two
# answered 0 and 1: the shift instruction masked its count to six bits, the
# masking SPEC 3.1 spends an instruction to avoid. arm64 faulted, so the two
# targets disagreed about a one-line program.
cdie "a WRITTEN negative shift count is out of range too" "shift out of range" <<'EOF'
out(1 << (0 - 1))
EOF
cdie "and one that masks to zero rather than to 63" "shift out of range" <<'EOF'
out(1 >> (0 - 64))
EOF
cdie "index past the end of a region" "index 3 out of bounds for a region of length 3" <<'EOF'
a = text(3)
i = 3
out(a[i])
EOF
cdie "negative index" "index -1 out of bounds for a region of length 3" <<'EOF'
a = text(3)
i = 0 - 1
out(a[i])
EOF
cdie "index store past the end" "index 5 out of bounds for a region of length 2" <<'EOF'
a = text(2)
i = 5
a[i] = 1
out(1)
EOF
cdie "write to a string literal" "write to a literal" <<'EOF'
s = "abc"
s[0] = 'z'
out(s)
EOF
cdie "slice range outside the region" "index out of bounds" <<'EOF'
s = "abc"
i = 1
out(len(copy(s, i, i + 5)))
EOF
cdie "text() with a negative length" "index out of bounds" <<'EOF'
n = 0 - 1
out(len(text(n)))
EOF
# out() decides between text and a list by looking at the elements: a region
# whose elements are all integers, at least one of them not a character you can
# see, prints as a list. One rule covers a control code, an out-of-range value
# and a lone surrogate, so which integers print as a list doesn't depend on how
# big they are.
crun "an out-of-range element prints as a list, not a fault" "[1114112]" <<'EOF'
a = text(1)
a[0] = 1114112
out(a)
EOF
crun "a lone surrogate prints as a list too" "[55296]" <<'EOF'
a = text(1)
a[0] = 55296
out(a)
EOF
crun "a zero-filled array is readable instead of invisible" "[0, 0, 0]" <<'EOF'
out(text(3))
EOF
crun "small numbers print as numbers, not control codes" "[1, 2, 3]" <<'EOF'
a = text(3)
a[0] = 1
a[1] = 2
a[2] = 3
out(a)
EOF
crun "text is still text" "abc" <<'EOF'
out("abc")
EOF
# An element that isn't an integer at all can't be shown as a number or as a
# character, so that one still faults.
cdie "out of a region element that is itself a region still faults" "not a character" <<'EOF'
a = text(1)
a[0] = "x"
out(a)
EOF
cdie "arithmetic on a region, decided at run time" "number expected" <<'EOF'
f(x)
    return x + 1
out(f("hi"))
EOF
cdie "len of a number, decided at run time" "region expected" <<'EOF'
f(x)
    return len(x)
out(f(5))
EOF

echo "== the 63-bit value boundary (SPEC §3.1) =="
crun "MAX is 2^62 - 1" "4611686018427387903" <<'EOF'
m = 2305843009213693951
m = m + m + 1
out(m)
EOF
crun "MIN is -2^62" "-4611686018427387904" <<'EOF'
m = 2305843009213693951
m = m + m + 1
out(0 - m - 1)
EOF
cdie "MAX + 1 traps rather than wrapping" "integer overflow" <<'EOF'
m = 2305843009213693951
m = m + m + 1
out(m + 1)
EOF
cdie "MIN / -1 traps (its true result overflows)" "integer overflow" <<'EOF'
m = 2305843009213693951
m = m + m + 1
mn = 0 - m - 1
d = 0 - 1
out(mn / d)
EOF
cdie "MIN % -1 traps too" "integer overflow" <<'EOF'
m = 2305843009213693951
m = m + m + 1
mn = 0 - m - 1
d = 0 - 1
out(mn % d)
EOF
cdie "unary minus of MIN traps" "integer overflow" <<'EOF'
m = 2305843009213693951
m = m + m + 1
mn = 0 - m - 1
out(0 - mn)
EOF
# A local whose every assignment is masked to 32 bits is kept raw and computed
# in 32-bit registers, where an add can't see an overflow. The sum overflows
# before the mask cuts it down, so it has to trap the same as anywhere else. It
# used to print 0, in a function and at the top level.
cdie "a masked sum into a 32-bit local still traps" "p.w:3: integer overflow" <<'EOF'
f(a, b)
    y = 0
    y = (a + b) & 4294967295
    return y
m = 2305843009213693951
m = m + m + 1
out(f(m, 1))
EOF
cdie "and at the top level" "p.w:4: integer overflow" <<'EOF'
m = 2305843009213693951
m = m + m + 1
y = 0
y = (m + 1 + 5) & 4294967295
out(y)
EOF
crun "a masked sum of 32-bit terms still wraps inside the mask" "4" <<'EOF'
f(a, b)
    y = 0
    y = (a + b) & 4294967295
    return y
out(f(4294967295, 5))
EOF

echo "== a map key must be text (SPEC §3.6/§3.7) =="
# rt_map_hash promoted the key and then read [key] as a length word. A number is
# tagged ...1, so the read dereferenced an odd address and the process died on
# SIGSEGV: an integer passing for a region, which §3.6 says can't happen. Where
# the key's kind is settled, the analyzer now rejects a read or a write first
# (SPEC 10.1). The lookup through a function is the same mistake written where
# the analyzer can't see it, which keeps rt_map_hash's own guard under test, and
# has() with a number key faults at run time.
crej "reading a map with a number key" "a map key must be text" <<'EOF'
m = {a: 1}
k = 5
out(m[k])
EOF
crej "reading a map with a literal number key" "a map key must be text" <<'EOF'
m = {a: 1}
out(m[5])
EOF
crej "writing a map with a number key" "a map key must be text" <<'EOF'
m = {}
k = 5
m[k] = 1
out(len(m))
EOF
cdie "a number key the analyzer cannot see still faults" "region expected" <<'EOF'
lookup(m, k)
    return m[k]

out(lookup({a: 1}, 5))
EOF
cdie "has() with a number key" "region expected" <<'EOF'
m = {a: 1}
k = 5
out(has(m, k))
EOF
crej "a float is not a text key either" "a map key must be text" <<'EOF'
m = {a: 1}
k = 1.5
out(m[k])
EOF
crun "and an ordinary text key still works after the check" "{\"a\":1,\"b\":2,\"c\":3}/true/c" <<'EOF'
m = {a: 1, b: 2}
m["c"] = 3
out(m . "/" . has(m, "b") . "/" . keys(m)[2])
EOF
# A region holding something that isn't a whole number isn't text either. It
# was accepted and hashed by its elements' addresses, so an equal key built
# separately never found it, and the map then couldn't be printed. Set, get
# and has each fault now, with the message out() gives such an element.
cdie "a key holding a region is not text" "not a character" <<'EOF'
x = array(1)
x[0] = "ab"
m = {}
m[x] = 1
out(len(m))
EOF
cdie "a key holding a float is not text" "not a character" <<'EOF'
f = array(1)
f[0] = 1.0
m = {a: 1}
out(has(m, f))
EOF
cdie "a key holding true is not text" "not a character" <<'EOF'
t = text(1)
t[0] = true
m = {a: 1}
out(m[t])
EOF
crun "a key of code points or of bytes still works" "1 2 true" <<'EOF'
t = text(2)
t[0] = 104
t[1] = 105
b = bytes(2)
b[0] = 104
b[1] = 106
m = {}
m[t] = 1
m[b] = 2
out(m["hi"] . " " . m["hj"] . " " . has(m, t))
EOF

echo "== content equality is bounded, not a segfault (SPEC §3.3 / §10.2) =="
# `==` recurses into nested regions and maps, all the way down, and nothing
# bounded it, so a structure a few hundred thousand levels deep blew the stack
# and the process died on SIGSEGV, which §10.2 rules out. rt_eq now has the
# same prologue guard every user function has, and reports what it caught: a
# structure with no end, deep or cyclic. It doesn't say `stack exhausted`,
# because the program below has no recursion in it, and that message sent a
# reader to the wrong half of it. json.parse caps depth at 1000, so only a
# program that builds such a structure itself gets here. The structures are
# 400,000 deep, past what an 8 MB stack holds, because `ulimit -s` can't shrink
# the stack a Windows PE reserves for itself.
cdie_stack "deeply nested == is a diagnostic, not a signal" "comparison nests too deeply" <<'EOF'
build(d)
    x = text(1)
    cur = x
    i = 0
    loop i < d
        n = text(1)
        cur[0] = n
        cur = n
        i = i + 1
    return x
a = build(400000)
b = build(400000)
out(a == b)
EOF
cdie_stack "deeply nested maps compare the same way" "comparison nests too deeply" <<'EOF'
build(d)
    x = {v: 0}
    cur = x
    i = 0
    loop i < d
        n = {v: 0}
        cur["v"] = n
        cur = n
        i = i + 1
    return x
a = build(400000)
b = build(400000)
out(a == b)
EOF
# Ordinary equality gives the same answers with the guard in.
crun "nesting a program actually writes still compares" "true true true" <<'EOF'
import json
build(d)
    x = text(1)
    cur = x
    i = 0
    loop i < d
        n = text(1)
        cur[0] = n
        cur = n
        i = i + 1
    return x
o = {a: 1, b: array(2)}
flat = text(2)
flat[0] = 1
flat[1] = "x"
other = text(2)
other[0] = 1
other[1] = "x"
out((build(2000) == build(2000)) . " " . (parse(stringify(o)) == o) . " " . (flat == other))
EOF

echo "== a program gets an 8 MB stack on every target (SPEC §10.2) =="
# A Windows PE reserved 1 MB, so recursion that finished on Linux's 8 MB default
# stopped with `stack exhausted` on Windows at about 40,000 levels. The reserve
# is 8 MB now. ulimit pins Linux at the same 8 MB and cannot change a PE's own
# reserve, so on Windows these check the one written into the image.
crun_stack8 "recursion 100,000 deep finishes" "100000" <<'EOF'
f(n)
    if n == 0
        return 0
    return f(n - 1) + 1
out(f(100000))
EOF
crun_stack8 "an acyclic structure 60,000 deep compares" "true" <<'EOF'
build(d)
    x = text(1)
    cur = x
    i = 0
    loop i < d
        n = text(1)
        cur[0] = n
        cur = n
        i = i + 1
    return x
out(build(60000) == build(60000))
EOF

echo "== a byte-backed key still hashes as the text it equals =="
crun "a key sliced out of a file matches the literal that spells it" "42 42" <<'EOF'
import fs
if write("wgapkey.txt", "hello") == 0
    err("cannot write")
    return 1
m = {}
m["hello"] = 42
d = read("wgapkey.txt")
out(m[d] . " " . m[copy(d, 0, 5)])
EOF
rm -f wgapkey.txt

echo "== a local's inferred kind must never turn a fault into garbage =="
# Codegen gives every local a static kind (infer_local_kinds), and a static kind
# lets it skip a run-time check. A guard used to skip it whenever the kind wasn't
# "unknown" (2), which was right only while 2 was the only answer an identifier
# could give. Once a local could be "region" or "integer", each case below
# skipped its check and read a region header as a number, or an integer as a
# pointer: SIGSEGV or garbage where SPEC §10.2 promises a located fault. A guard
# now skips the check only for a kind the operation accepts.
#
# The `z = 1.0` in these cases is left from when only a program with a float
# got the inference. Every function gets it now.
#
# Since SPEC 10.1 learned to answer for a local whose assignments agree, the
# direct spelling of each of these is a compile error and never reaches the
# guard it was written for. Both halves are kept: the rejection, because that's
# now the promise, and the same mistake behind a parameter, where no assignment
# in the body settles the kind and the emitted guard has to catch it.
crej "arithmetic on a region local" "must be a number, but got a region" <<'EOF'
z = 1.0
s = "ab"
out(z)
out(s + 1)
EOF
cdie "arithmetic on a region a caller passed" "number expected, got a region" <<'EOF'
f(s)
    z = 1.0
    out(z)
    return s + 1

out(f("ab"))
EOF
crej "unary minus on a region local" "must be a number, but got a region" <<'EOF'
z = 1.0
s = "ab"
out(z)
out(0 - s)
EOF
crej "bitwise not on a region local" "unary '~' needs a number, but got a region" <<'EOF'
z = 1.0
s = "ab"
out(z)
out(~s)
EOF
cdie "bitwise not on a region a caller passed" "number expected, got a region" <<'EOF'
f(s)
    z = 1.0
    out(z)
    return ~s

out(f("ab"))
EOF
crej "indexing an integer local" "cannot index a number" <<'EOF'
z = 1.0
n = 5
out(z)
out(n[0])
EOF
cdie "indexing an integer a caller passed" "region expected, got a number" <<'EOF'
f(n)
    z = 1.0
    out(z)
    return n[0]

out(f(5))
EOF
crej "index-storing into an integer local" "cannot index a number" <<'EOF'
z = 1.0
n = 5
out(z)
n[0] = 1
EOF
crej "len of an integer local" "'len' needs a region" <<'EOF'
z = 1.0
n = 5
out(z)
out(len(n))
EOF
cdie "len of an integer a caller passed" "region expected, got a number" <<'EOF'
f(n)
    z = 1.0
    out(z)
    return len(n)

out(f(5))
EOF
crej "len of a float local" "'len' needs a region" <<'EOF'
z = 1.0
out(len(z))
EOF
# `~` is integer-only (SPEC §3.3). It used to have only numcheck, which passes a
# float (tag 010), so `~3.5` inverted the pointer to its box and printed a
# plausible negative integer. This one predates the inference, and it was wrong
# for a literal too.
cdie "bitwise not on a float literal" "needs whole numbers" <<'EOF'
out(~3.5)
EOF
cdie "bitwise not on a float local" "needs whole numbers" <<'EOF'
z = 1.0
out(z)
out(~z)
EOF
# The same question for a parameter, whose kind comes from every call site in
# the program instead of the frame it lives in. An index on a parameter every
# caller passes an integer, and arithmetic on one every caller passes a region,
# must keep their checks and fault.
cdie "indexing a parameter every caller passes an integer" "region expected, got a number" <<'EOF'
at(p)
    return p[0]
out(at(5))
EOF
cdie "arithmetic on a parameter every caller passes a region" "number expected, got a region" <<'EOF'
inc(s)
    return s + 1
out(inc("ab"))
EOF
# Mixed call sites prove nothing, so every check stays and the fault is the
# ordinary one, where a dropped guard would give a wrong comparison.
cdie "ordering a parameter called with both a number and text" "cannot order-compare" <<'EOF'
small(a)
    if a < 3
        return 1
    return 0
out(small(2))
out(small("x"))
EOF
crun "a parameter proved integer compares correctly with the guard gone" "1 0" <<'EOF'
small(a)
    if a < 3
        return 1
    return 0
out(small(2) . " " . small(5))
EOF

# The kinds those operations accept still skip their checks and work.
crun "the accepted kinds still work, with the inference on" "9 3 4 1 -6 2.5" <<'EOF'
z = 1.0
a = text(3)
a[1] = 9
m = {}
m["k"] = 4
n = 5
out(a[1] . " " . len(a) . " " . m["k"] . " " . len(m) . " " . (0 - n - 1) . " " . (z + 1.5))
EOF

# ---------------------------------------------------------------------------
# Two things a utility written in word found, which nothing here tested.
echo ""
echo "== the byte/code-point seam, where a program actually meets it =="

# fs.read gives a byte-backed region, and `out` writes those bytes back
# unchanged, so a text file prints as itself. A slice of it used to come back
# word-backed, with each byte re-encoded as its own character: the whole file
# printed correctly and every part of it was mojibake. A grep written in word
# found it.
printf 'caf\303\251 \342\200\224 dash\n' > "$tmp/u8.txt"
crun "a slice of a file prints the same bytes the whole of it does" "café — dash
café — d" <<EOF
import fs
d = read("$tmp/u8.txt")
out(copy(d, 0, len(d) - 1))
out(copy(d, 0, 11))
EOF

# The slice is still a region of byte values: element 3 of "café" is the first
# byte of the 2-byte é, and len is the byte count.
crun "a byte-backed slice indexes as bytes, not characters" "11 195 15" <<EOF
import fs
d = read("$tmp/u8.txt")
s = copy(d, 0, 11)
out(len(s) . " " . s[3] . " " . len(d))
EOF

# --- joining two byte-backed regions stays byte-backed ---------------------
#
# `.` used to promote both operands to one word per element and then allocate a
# word-backed result, so joining two buffers read from disk cost 24x the bytes
# it was concatenating. A slice of a byte-backed region already stayed
# byte-backed (SPEC 3.4), and a join of two does now, for the same reason and
# with the same visible behaviour.
crun "a join of two files is byte-exact and indexes as bytes" "30 195 195 15" <<EOF
import fs
d = read("$tmp/u8.txt")
j = d . d
out(len(j) . " " . j[3] . " " . j[len(d) + 3] . " " . len(d))
EOF

# A byte-backed side joined to a word-backed one still promotes: the result has
# to hold code points, and the literal has some above 255.
crun "joining a file with a literal still gives code points" "7 233" <<EOF
import fs
d = read("$tmp/u8.txt")
j = copy(d, 0, 3) . "café"
out(len(j) . " " . j[6])
EOF

# The joined buffer takes byte stores, which the assembler's own output buffer
# relies on.
crun "a joined byte buffer takes byte stores" "3 7 255 0" <<'EOF'
a = bytes(2)
b = bytes(1)
c = a . b
c[0] = 7
c[1] = 511
out(len(c) . " " . c[0] . " " . c[1] . " " . c[2])
EOF

# The memory claim, made the way test_slice_scaling makes its: under a cap that
# the promoting join cannot fit. 20M + 20M bytes is 40 MB byte-backed and
# 320 MB (960 MB with both sides promoted) otherwise.
cat > "$tmp/bjoin.w" <<'EOF'
a = bytes(20000000)
a[7] = 200
b = bytes(20000000)
b[9] = 100
c = a . b
out(len(c) . " " . c[7] . " " . c[20000009])
EOF
if out=$( (ulimit -v 262144; "$WORD" run "$tmp/bjoin.w") 2>&1 ) && [ "$out" = "40000000 200 100" ]; then
  ok "a 40M-element join fits in 256 MB, so it is byte-backed"
else
  bad "a 40M-element join fits in 256 MB" "40000000 200 100, got: $out"
fi

# --- appending to a byte-backed region -------------------------------------
#
# `s = s . x` is `.`, so it owes the same answer, but it's a different function
# (rt_append, the in-place grow of SPEC 3.4), and that function promoted both
# operands every time. So the join above was byte-backed while the append that
# spells the same thing wasn't: a program that read a file and appended to it
# paid 8x the memory and 8x the copy bandwidth that `t = s . x` had already
# stopped paying.
#
# Every program here has to keep the accumulator unique, or the compiler lowers
# the statement to rt_join and the case tests nothing. `j = d` aliases d, and
# passing a name to a user-defined function marks it shared, so the accumulator
# is seeded with a builtin and compared with an inline loop.
crun "appending byte-backed to byte-backed is byte-exact" "30 195 195 15" <<EOF
import fs
d = read("$tmp/u8.txt")
j = copy(d, 0, len(d))
j = j . d
out(len(j) . " " . j[3] . " " . j[len(d) + 3] . " " . len(d))
EOF

# Mixed still promotes, as the join does: the other side may hold
# values above 255, so the result has to hold code points.
crun "appending a literal to a file still gives code points" "7 233" <<EOF
import fs
d = read("$tmp/u8.txt")
j = copy(d, 0, 3)
j = j . "café"
out(len(j) . " " . j[6])
EOF

# The three grow paths in one program, with every byte of the result checked
# against the same content built word-backed: in place (spare capacity),
# extending the arena (the region is the last block, so growing it is a bump),
# and a copy into a new buffer (something else was allocated after it).
crun "byte-backed append matches the word-backed answer on every grow path" "OK" <<'EOF'
bad = 0
n = 1
loop n < 300
    s = bytes(n)
    w = text(n)
    i = 0
    loop i < n
        s[i] = (3 + i * 7) % 251
        w[i] = (3 + i * 7) % 251
        i = i + 1
    k = 0
    loop k < 5
        p = bytes(n)
        q = text(n)
        i = 0
        loop i < n
            p[i] = (11 + k + i * 7) % 251
            q[i] = (11 + k + i * 7) % 251
            i = i + 1
        // a live allocation between s and its growth takes the bump extension
        // away and forces the copy-into-a-new-buffer path; the guard proves
        // that copy did not run past what it allocated
        guard = bytes(24)
        guard[0] = k
        s = s . p
        w = w . q
        if guard[0] != k
            bad = bad + 1
        k = k + 1
    if len(s) != len(w)
        bad = bad + 1
    i = 0
    loop i < len(s)
        if s[i] != w[i]
            bad = bad + 1
            i = len(s)
        i = i + 1
    n = n * 3
// mixed, byte-backed accumulator: promotes, so the result holds code points
b = bytes(3)
b[0] = 120
b[1] = 121
b[2] = 122
b = b . "café"
if len(b) != 7
    bad = bad + 1
if b[0] != 120
    bad = bad + 1
if b[6] != 233
    bad = bad + 1
// mixed the other way, word-backed accumulator and a byte-backed operand
c = bytes(2)
c[0] = 200
c[1] = 201
t = "hi"
t = t . c
if len(t) != 4
    bad = bad + 1
if t[0] != 104
    bad = bad + 1
if t[2] != 200
    bad = bad + 1
if t[3] != 201
    bad = bad + 1
// a number operand renders as text either way
d = bytes(1)
d[0] = 65
d = d . 12345
if len(d) != 6
    bad = bad + 1
if d[0] != 65
    bad = bad + 1
if d[1] != 49
    bad = bad + 1
if d[5] != 53
    bad = bad + 1
// an empty operand on either side
e = bytes(2)
e[0] = 7
e[1] = 8
e = e . bytes(0)
if len(e) != 2
    bad = bad + 1
if e[1] != 8
    bad = bad + 1
f = bytes(0)
g = bytes(2)
g[0] = 9
g[1] = 10
f = f . g
if len(f) != 2
    bad = bad + 1
if f[0] != 9
    bad = bad + 1
if f[1] != 10
    bad = bad + 1
if bad == 0
    out("OK")
else
    out(bad . " wrong")
EOF

# The memory claim, made the way the join above makes its. 32 MB built by
# appending 4 MB eight times is 32 MB byte-backed and 256 MB otherwise, and the
# doubling puts the promoting version's real floor above 750 MB, so a 300 MB cap
# separates the two with room to spare on either side.
cat > "$tmp/bapp.w" <<'EOF'
b = bytes(4194304)
s = bytes(0)
i = 0
loop i < 8
    s = s . b
    i = i + 1
out(len(s))
EOF
if out=$( (ulimit -v 307200; "$WORD" run "$tmp/bapp.w") 2>&1 ) && [ "$out" = "33554432" ]; then
  ok "a 32M-element append fits in 300 MB, so it stays byte-backed"
else
  bad "a 32M-element append fits in 300 MB" "33554432, got: $out"
fi

# --- the in-place append has to be invisible -------------------------------
#
# rt_append is emitted only for `s = s . x` on a provably unique local, and
# SPEC 3.4 says the optimisation is invisible to the program: it has to mean
# what `t = s . x` means. It didn't. `.` renders a map and a JSON array as JSON
# (SPEC 3.7), and rt_append tested for neither. It appended into the array's
# own storage, giving [1, 2, 120] where the join gives "[1,2]x", and it faulted
# on the map.
crun "appending to a JSON array renders it, as the join does" "[1,2]x [1,2]x" <<'EOF'
a = array(2)
a[0] = 1
a[1] = 2
b = a . "x"
a = a . "x"
out(b . " " . a)
EOF

crun "appending to a map renders it, as the join does" '{"a":1}x {"a":1}x' <<'EOF'
m = {a: 1}
b = m . "x"
m = m . "x"
out(b . " " . m)
EOF

crun "appending a map or an array renders the operand" '1{"a":1} 1[7]' <<'EOF'
m = {a: 1}
a = array(1)
a[0] = 7
s = "1"
s = s . m
t = "1"
t = t . a
out(s . " " . t)
EOF

# A slice of a file is what write() is handed when a program copies part of one,
# so the round trip has to stay byte-exact.
crun "writing a slice of a file back out is byte-exact" "true 11" <<EOF
import fs
d = read("$tmp/u8.txt")
s = copy(d, 0, 11)
ok = write("$tmp/u8b.txt", s)
back = read("$tmp/u8b.txt")
out(ok . " " . len(back))
EOF

echo ""
echo "== the kind test is about numbers =="

# SPEC §3.6 defines a number as "an integer OR a float". It was implemented as
# "not a region", so it answered 1 for a map, and the obvious way to walk a
# parsed JSON document of unknown shape (`if kind(x) == "number"` for a leaf)
# took the wrong branch on every object it met.
crun "the kind test says a map is not a number" "true true false false false" <<'EOF'
import json
m = {}
m["a"] = 1
out((kind(7) == "number") . " " . (kind(1.5) == "number") . " " . (kind("x") == "number") . " " . (kind(m) == "number") . " " . (kind(parse("{\"k\":1}")) == "number"))
EOF

# The shape that found it: a walk into a document whose shape isn't known in
# advance. The kind test told a number from everything else, and nothing told a
# map from text, so the walk below answered "other" for an object, an array and
# a string alike, and a generic JSON tool could find a numeric leaf and nothing
# else. kind() closed that gap, and this is the expectation that changed.
crun "a JSON walk can name every kind it meets" "map|array|number 1|text" <<'EOF'
import json
describe(v)
    if kind(v) == "number"
        return "number " . v
    return kind(v)
doc = parse("{\"user\":{\"name\":\"Aria\",\"tags\":[1,2,3]}}")
u = doc["user"]
t = u["tags"]
out(describe(u) . "|" . describe(t) . "|" . describe(t[0]) . "|" . describe(u["name"]))
EOF

# keys() and has() still fault on something that isn't a map, so kind() is the
# check you put in front of them.
cdie "keys() of text still faults, so kind() is how you check first" "map" <<'EOF'
count(v)
    return len(keys(v))
out(count("not a map"))
EOF

# A function whose body ends without `return` answers the integer 0, which is
# the word 1. All-zero bits spell "region" in the low three, so the raw 0 it
# used to answer was a null region: out() of it died on SIGSEGV, a kind test
# said it wasn't a number, and `f() + 0` died on SIGSEGV. It's the first thing a
# beginner writes, and the analyzer had assumed all along that this path
# returns an integer.
crun "a function that falls off the end returns the integer 0" "0 true 0 true" <<'EOF'
f()
    text(0)
v = f()
out(v . " " . (kind(v) == "number") . " " . (v + 0) . " " . (v == 0))
EOF
crun "a bare return statement is the same integer 0" "0 true" <<'EOF'
f()
    return
v = f()
out(v . " " . (kind(v) == "number"))
EOF
crun "so is falling past an if that did not return" "0 true" <<'EOF'
f(n)
    if n > 0
        return 1
v = f(0)
out(v . " " . (kind(v) == "number"))
EOF
crun "out() of a no-return function prints 0 instead of dying" "0" <<'EOF'
f()
    text(0)
out(f())
EOF

# The same through the contract wrapper, which is a second frame with its own
# epilogue. A guarded function carries its body's answer through a general
# register to hand to the :after hook, so it's the one path where a wrong
# "nothing" would have reached a user hook as a null region.
crun "a contract-guarded no-return function is the integer 0 too" "0 true 0" <<'EOF'
f(n)
    text(n)

f:before
    return true

f:after
    return true

v = f(3)
out(v . " " . (kind(v) == "number") . " " . (v + 0))
EOF

# --- what a container keeps ------------------------------------------------
#
# `s = s . x` overwrites s's buffer in place when the static uniqueness pass
# proves s is never aliased (SPEC §3.4). The pass marked the value side of a
# store (`a[i] = s` makes s shared) but not the key side, and not a `{}`
# literal's operands. rt_map_set keeps both, storing the word it's handed
# instead of a copy, so the map went on pointing at a buffer the next append
# rewrote. Nothing crashed, and `out(m)` printed a key the map could no longer
# find.
crun "a map key is not rewritten by a later append to the name that spelled it" "{\"abc\":1} abcx 1 none" <<'EOF'
m = {}
t = "" . "abc"
m[t] = 1
t = t . "x"
out(m . " " . t . " " . m["abc"] . " " . m["abcx"])
EOF
crun "a {} literal's value is not rewritten by a later append either" "{\"k\":\"abcd\"} abcde" <<'EOF'
t = "" . "abc"
t = t . "d"
m = {k: t}
t = t . "e"
out(m . " " . t)
EOF
crun "a nested store marks the subscripts at every level" "{\"ab\":{\"cd\":7}} abx cdy" <<'EOF'
m = {}
m["ab"] = {}
j = "" . "ab"
k = "" . "cd"
m[j][k] = 7
j = j . "x"
k = k . "y"
out(m . " " . j . " " . k)
EOF

# The rewind that gives a dead region back (SPEC §3.5) rests on the same proof,
# so the same shapes are the ones that would hand the same bytes out twice.
crun "a slice stored in an array survives the next slice into the same name" "abcd bcde cdef" <<'EOF'
s = "abcdefghij"
a = text(3)
i = 0
loop i < 3
    t = copy(s, i, i + 4)
    a[i] = t
    i = i + 1
out(a[0] . " " . a[1] . " " . a[2])
EOF
crun "a slice whose name is reassigned through itself still reads right" "cdefg" <<'EOF'
w = copy("abcdefghij", 0, 10)
w = copy(w, 2, 7)
out(w)
EOF

echo ""
# --- a function with many escaping names -----------------------------------
#
# The uniqueness pass kept its shared-name set in a fixed 64-entry list. A
# function with more names than that overflowed it, and the compiler died on the
# user's program with `word.w:569: index 65 out of bounds`, a line of its own
# source. It's a map now, so there's no limit to hit, and the pass is no longer
# quadratic in the size of the function.
python3 - > "$tmp/big_escape.w" <<'PYEOF'
lines = ["keep(x)", "    return x", "f()", "    a0 = text(2)"]
for i in range(1, 200):
    lines.append("    a%d = a%d" % (i, i - 1))
lines.append("    return keep(a199)")
lines.append("out(len(f()))")
print("\n".join(lines))
PYEOF
if "$WORD" build "$tmp/big_escape.w" -o "$tmp/big_escape.bin" 2>"$tmp/be.err" && [ "$("$tmp/big_escape.bin")" = "2" ]; then
  ok "a function with 200 escaping names compiles and runs"
else
  bad "a function with 200 escaping names compiles and runs" "$(tail -1 "$tmp/be.err")"
fi


# ---------------------------------------------------------------------------
# The builtins that take a region or a number used to check neither. Each
# dereferenced its argument as a pointer (or shifted it into a length) without
# looking at the tag, so a value of the wrong kind that the analyzer can't see,
# from in(), an array element or a caller, crashed the process with SIGSEGV,
# ran the arena out of memory or came back as a wrong answer. The analyzer
# already refused the static cases (len(5), sort(5)), and these are the ones it
# can't see. SPEC §10.2 wants a located message and exit 70, never a signal.
# Both backends had these bugs, and test_a64_lang checks the arm64 side.
echo "== builtins fault on a wrong-typed runtime value; they do not crash =="

# env() walked a number as a name pointer -> SIGSEGV.
cdie "env() of a number" "region expected, got a number" <<'EOF'
out(env(123))
EOF

# The shape that was reported: in() answers a number for numeric input, so this
# reaches env(number) at run time. It must fault, not die on a signal.
cat > "$p" <<'EOF'
name = in()
out(env(name))
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$(printf '123\n' | $TO "$exe" 2>&1); rc=$?
  case "$got" in *"region expected"*) m=1;; *) m=0;; esac
  case "$got" in *"p.w:"*) loc=1;; *) loc=0;; esac
  if [ "$m" = 1 ] && [ "$rc" = 70 ] && [ "$loc" = 1 ]; then ok "env(in()) with numeric input faults, not SIGSEGV"
  else bad "env(in()) with numeric input" "got [$got] rc=$rc (want located 'region expected', rc=70)"; fi
else bad "env(in()) with numeric input" "build failed"; fi

# A name is matched up to the entry's first =, never across it: with
# WORD_EQ=B=C set, env("WORD_EQ=B") answered "C" on both backends. test_lang.sh
# has the x86-64 half; this is the arm64 one, which has its own rt_env.
if [ -n "$QEMU" ]; then
  printf 'out(env("WORD_EQ"))\nout(env("WORD_EQ=B") == none)\nout(env("") == none)\n' > "$p"
  nm="env() of a name holding = or of \"\" is none on arm64"
  if "$WORD" build -arm64 "$p" -o "$exe.a64" >/dev/null 2>&1; then
    got=$(WORD_EQ=B=C $TO "$QEMU" "$exe.a64" 2>&1 | tr '\n' ' ')
    if [ "$got" = "B=C true true " ]; then ok "$nm"; else bad "$nm" "got [$got] want [B=C true true ]"; fi
  else bad "$nm" "build failed"; fi
fi

# round() of a non-number returned it unchanged -> round("x") answered "x".
cdie "round() of text" "number expected, got a region" <<'EOF'
out(round("x"))
EOF

# array(n)/text(n)/bytes(n) shifted a non-number into a length: array(true) built
# an 11-element region (22 >> 1), bytes(some_text) ran the arena out of memory.
cdie "array() of a boolean" "number expected, got true, false, null or none" <<'EOF'
out(len(array(true)))
EOF
cdie "text() of a boolean" "number expected, got true, false, null or none" <<'EOF'
out(len(text(true)))
EOF
cdie "bytes() of a runtime text" "number expected, got a region" <<'EOF'
a = array(1)
a[0] = "41"
out(len(bytes(a[0])))
EOF

# bytes("...") is decoded at compile time (SPEC §9), so a malformed hex literal is
# a compile error about the hex, not a run-time "number expected".
crej "bytes() of an odd-length hex literal" "even number of hex digits" <<'EOF'
out(len(bytes("4")))
EOF
crej "bytes() of a non-hex literal" "even number of hex digits" <<'EOF'
out(len(bytes("zz")))
EOF
# Zero hex digits is an even number of them, and it decodes to the empty region.
# It used to be refused for not being an even number of hex digits.
crun "bytes() of an empty hex literal is the empty region" "0" <<'EOF'
out(len(bytes("")))
EOF

# read/write/dir walked a number as a path pointer -> SIGSEGV.
cdie "read() of a number" "region expected, got a number" <<'EOF'
import fs
out(len(read(5)))
EOF
cdie "write() with a number path" "region expected, got a number" <<'EOF'
import fs
write(5, "data")
EOF
# write() checks its data before opening, so a bad argument faults instead of
# truncating the file first.
cdie "write() with number data" "region expected, got a number" <<'EOF'
import fs
write("word_gaps_write_target", 5)
EOF
cdie "dir() of a number" "region expected, got a number" <<'EOF'
import fs
out(dir(5))
EOF

# split/sort/find promoted a number as a region -> SIGSEGV. sort crashed on
# x86-64 where arm64 faulted, so the two backends disagreed as well.
cdie "split() of a number" "region expected, got a number" <<'EOF'
import txt
out(split(5, ","))
EOF
cdie "sort() of a runtime number" "region expected, got a number" <<'EOF'
a = array(1)
a[0] = 5
out(sort(a[0]))
EOF
cdie "find() of a runtime number" "region expected, got a number" <<'EOF'
a = array(1)
a[0] = 5
out(find(a[0], 5))
EOF

# And none of the checks is over-eager: the valid shapes still work.
crun "round() of a whole float still rounds" "3" <<'EOF'
out(round(2.7))
EOF
crun "bytes() of an even hex literal still decodes" "2" <<'EOF'
out(len(bytes("4142")))
EOF
crun "array()/text()/bytes() of a count still allocate" "3 3 3" <<'EOF'
out(len(array(3)) . " " . len(text(3)) . " " . len(bytes(3)))
EOF

echo ""
echo "== an allocation too large to exist is out of memory, not memory corruption =="
# 2^61 elements is 2^64 bytes, which wrapped to nothing. Each of these used to
# get a tiny block with an enormous length and die of SIGSEGV part way through
# filling it; the counts just below 2^61 wrapped the same way.
cdie "text() of 2^61 elements" "out of memory" <<'EOF'
n = 2305843009213693951 + 1
out(len(text(n)))
EOF
cdie "array() of 2^61 elements" "out of memory" <<'EOF'
n = 2305843009213693951 + 1
out(len(array(n)))
EOF
cdie "array() just under 2^61 elements, which wrapped too" "out of memory" <<'EOF'
n = 2305843009213693951 - 1
out(len(array(n)))
EOF
cdie "pad() to a width of 2^61" "out of memory" <<'EOF'
n = 2305843009213693951 + 1
out(len(pad("x", n, 32)))
EOF
cdie "bytes() of the largest integer" "out of memory" <<'EOF'
n = 2305843009213693951 * 2 + 1
out(len(bytes(n)))
EOF
# 40 TiB does not wrap, and used to be mapped 128 MiB at a time with MAP_FIXED
# until the arena reached whatever lay above it. Now it is one refused request.
cdie "bytes() of 40 TiB" "out of memory" <<'EOF'
out(len(bytes(40000000000000)))
EOF
crun "and a large allocation that fits still works" "7 9" <<'EOF'
b = bytes(314572800)
b[314572799] = 7
a = array(20000000)
a[19999999] = 9
out(b[314572799] . " " . a[19999999])
EOF
# A literal index into a region whose length the compiler knows is folded into
# the instruction as a 32-bit displacement. From 2^28 - 1 words (2^31 bytes) up
# it wrapped negative and the access landed about 2 GB below the region, so a
# read died of SIGSEGV and a store wrote into whatever was there. Each case
# needs a 2 GB region, so a machine without the memory skips them. Git Bash's
# /proc/meminfo has no MemAvailable, so on Windows MemFree stands in for it.
avail=$(awk '/^MemAvailable:/ {a = $2} /^MemFree:/ {f = $2} END {print int((a ? a : f) / 1024)}' /proc/meminfo 2>/dev/null)
if [ "${avail:-0}" -lt 4096 ]; then
  ok "a literal index past 2^31 bytes (SKIP: ${avail:-unknown} MB available)"
else
crun "a literal index 2^28 - 1 words into a region" "0 7" <<'EOF'
a = array(268435456)
x = a[268435455]
a[268435455] = 7
out(x . " " . a[268435455])
EOF
crun "a literal index 2^31 + 1 bytes into a region" "0 9" <<'EOF'
b = bytes(2147483650)
x = b[2147483649]
b[2147483649] = 9
out(x . " " . b[2147483649])
EOF
fi

echo ""
echo "== a path reaches the OS as written, or not at all =="
d="$tmp/paths"
mkdir -p "$d/sub"
crun "a NUL in a path fails instead of naming the part before it" "false none false" <<EOF
p = "$d/target" . char(0) . "_suffix"
out(write(p, "x") . " " . read(p) . " " . write("$d/other" . char(0), "y"))
EOF
if [ -e "$d/target" ] || [ -e "$d/other" ]; then bad "a NUL path created no file" "found $(ls "$d")"; else ok "a NUL path created no file"; fi

# 2,041 "./" and a long name: cut at 4094 this was "$d/././.../t", a real file.
crun "a path longer than the OS takes fails instead of being cut short" "false false none" <<EOF
q = "$d/"
i = 0
loop i < 2041
    q = q . "./"
    i = i + 1
q = q . "target_with_a_long_suffix"
b = bytes(len(q))
i = 0
loop i < len(q)
    b[i] = q[i]
    i = i + 1
out(write(q, "x") . " " . append(b, "x") . " " . dir(q))
EOF
if [ -n "$(ls "$d" | grep -v '^sub$')" ]; then bad "a cut-short path created no file" "found $(ls "$d")"; else ok "a cut-short path created no file"; fi

# U+012E and U+012F have '.' and '/' as their low bytes, so "sub/ĮĮįx" used to
# be "sub/../x": a traversal out of the directory the program checked.
crun "a code point past U+00FF is not its low byte" "true" <<EOF
out(write("$d/sub/" . char(302) . char(302) . char(303) . "x", "t"))
EOF
if [ -e "$d/x" ]; then bad "U+012E U+012F stayed inside the directory" "wrote $d/x"
elif [ -e "$d/sub/$(printf '\304\256\304\256\304\257x')" ]; then ok "U+012E U+012F stayed inside the directory, as UTF-8"
else bad "U+012E U+012F stayed inside the directory" "found $(ls "$d/sub" | od -c | head -2)"; fi

crun "text is written as UTF-8 and read back by the same name" "true hello" <<EOF
p = "$d/caf" . char(233)
w = write(p, "hello")
out(w . " " . read(p))
EOF
if [ -e "$d/$(printf 'caf\303\251')" ]; then ok "the file's name is the UTF-8 of the text"; else bad "the file's name is the UTF-8 of the text" "found $(ls "$d" | od -c | head -2)"; fi

crun "a byte-backed path is its bytes" "true bytes" <<EOF
write("$d/name.txt", "$d/frombytes")
p = read("$d/name.txt")
out(write(p, "b") . " " . kind(p))
EOF
if [ -e "$d/frombytes" ]; then ok "the byte path named the file it spelled"; else bad "the byte path named the file it spelled" "found $(ls "$d" | od -c | head -3)"; fi

cdie "a path element that is not a character is a fault" "not a character" <<EOF
p = text(2)
p[0] = 47
p[1] = 1.5
out(write(p, "x"))
EOF

echo ""
echo "== data reaches the file as written =="
# write() and append() write text as its UTF-8, the bytes out() writes for it,
# and a byte-backed region as the bytes it holds. They used to keep the low byte
# of each element, so U+00E9 went out as one byte and U+20AC as 0xAC.
dt="$tmp/data"
mkdir -p "$dt"
crun "write and append answer true for text" "true true" <<EOF
out(write("$dt/u8.txt", "caf" . char(233) . char(8364) . char(128512)) . " " . append("$dt/u8.txt", char(233)))
EOF
got=$(od -An -tx1 "$dt/u8.txt" 2>/dev/null | tr -d ' \n')
if [ "$got" = "636166c3a9e282acf09f9880c3a9" ]; then ok "the file holds the text's UTF-8, appended text included"
else bad "the file holds the text's UTF-8, appended text included" "got $got"; fi

crun "a number past 127 is a code point, and bytes stay bytes" "true true" <<EOF
a = array(2)
a[0] = 233
a[1] = 0
out(write("$dt/cp.txt", a) . " " . write("$dt/b.txt", bytes("e900ff")))
EOF
got=$(od -An -tx1 "$dt/cp.txt" 2>/dev/null | tr -d ' \n')/$(od -An -tx1 "$dt/b.txt" 2>/dev/null | tr -d ' \n')
if [ "$got" = "c3a900/e900ff" ]; then ok "233 is written as c3 a9, and bytes e9 00 ff as themselves"
else bad "233 is written as c3 a9, and bytes e9 00 ff as themselves" "got $got"; fi

# An element with no UTF-8 is a fault, checked before the file is opened, so the
# file is left as it was. test_kinds holds every kind of element to the message.
printf 'keep' > "$dt/keep.txt"
cdie "a negative element of data is not a character" "not a character" <<EOF
a = array(2)
a[0] = 104
a[1] = 0 - 1
out(write("$dt/keep.txt", a))
EOF
cdie "a surrogate in data is not a character" "not a character" <<EOF
a = array(1)
a[0] = 55296
out(append("$dt/keep.txt", a))
EOF
cdie "data past U+10FFFF is not a character" "not a character" <<EOF
a = array(3)
a[0] = 104
a[1] = 105
a[2] = 1114112
out(write("$dt/keep.txt", a))
EOF
if [ "$(cat "$dt/keep.txt")" = keep ]; then ok "a write that faults leaves the file as it was"
else bad "a write that faults leaves the file as it was" "now [$(cat "$dt/keep.txt" | od -c | head -2)]"; fi

# A surrogate (U+D800..U+DFFF) has no UTF-8 either, in a path or in encode(), and
# faults the same way. Both used to write it as the bytes ED A0 80.
cdie "a surrogate in a path is not a character" "not a character" <<EOF
out(write("$dt/s" . char(55296), "x"))
EOF
cdie "a surrogate in encode() is not a character" "not a character" <<'EOF'
out(len(encode("a" . char(56320))))
EOF

echo ""
echo "== out() and err() into a pipe whose reader has gone =="
# Every platform ends the program with status 141: Linux and macOS by SIGPIPE,
# Windows by exiting with the same number. Windows used to go on writing into
# nothing, for ever when the program was a loop like these.
cat > "$p" <<'EOF'
loop true
    out("y")
EOF
nm="out() into a pipe whose reader has gone ends the program with 141"
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  rm -f "$tmp/pipe.rc"
  { rc=0; $TO "$exe" || rc=$?; echo "$rc" > "$tmp/pipe.rc"; } | head -n 1 > /dev/null
  rc=$(cat "$tmp/pipe.rc" 2>/dev/null || echo none)
  if [ "$rc" = 141 ]; then ok "$nm"; else bad "$nm" "status [$rc], want 141"; fi
else bad "$nm" "build failed"; fi
cat > "$p" <<'EOF'
loop true
    err("y")
EOF
nm="err() into a pipe whose reader has gone ends the program with 141"
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  rm -f "$tmp/pipe.rc"
  { rc=0; $TO "$exe" 2>&1 >/dev/null || rc=$?; echo "$rc" > "$tmp/pipe.rc"; } | head -n 1 > /dev/null
  rc=$(cat "$tmp/pipe.rc" 2>/dev/null || echo none)
  if [ "$rc" = 141 ]; then ok "$nm"; else bad "$nm" "status [$rc], want 141"; fi
else bad "$nm" "build failed"; fi

echo ""
echo "== out() and err() when a write fails =="
# A failed write used to end the flush and drop the rest without a word, so out()
# into a full disk printed nothing, said nothing and exited with the program's own
# status. It is a located fault now, at the line of the first out() whose output
# was lost, which can be well before the statement whose flush found out. A
# standard output opened read-only refuses every write, on Linux (EBADF) and on
# Windows (WriteFile's access denied) alike.
: > "$tmp/ro.txt"
# wfail <name> <fd> <want output> <want status>: run $exe with that descriptor
# opened read-only, and stdout and stderr of the rest captured together.
wfail() { nm="$1"; fd="$2"; want="$3"; wrc="$4"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then bad "$nm" "build failed"; return; fi
  if [ "$fd" = 1 ]; then got=$($TO "$exe" 2>&1 1<"$tmp/ro.txt"); rc=$?
  else got=$($TO "$exe" 2<"$tmp/ro.txt"); rc=$?; fi
  if [ "$got" = "$want" ] && [ "$rc" = "$wrc" ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc want [$want] rc=$wrc"; fi; }
cat > "$p" <<'EOF'
out("lost")
x = 1
out("also lost " . x)
return 3
EOF
wfail "out() into a standard output that refuses writes is a located fault" 1 \
  "p.w:1: could not write standard output" 70
# err() writing is the thing that failed, so its message has nowhere to go, and
# the exit status 70 is the only sign. What out() had staged was written first.
cat > "$p" <<'EOF'
out("kept")
err("lost")
out("never")
EOF
wfail "err() into a standard error that refuses writes ends the program with 70" 2 "kept" 70
# The fault's own flush of what out() staged fails too, and the fault is still
# the one reported.
cat > "$p" <<'EOF'
out("first")
a = 10
b = len(args()) - 1
out(a / b)
EOF
wfail "a fault while standard output refuses writes still reports itself" 1 \
  "p.w:4: divide by zero" 70
# read() writes what out() staged before it can block, and that write failing is
# reported at the out(), not at the read().
cat > "$p" <<'EOF'
out("a")
x = 5
y = read("no such file here")
out("b " . x)
EOF
wfail "a flush that fails before read() is reported at the out() it lost" 1 \
  "p.w:1: could not write standard output" 70

if [ "$win" = 0 ] && [ -c /dev/full ]; then
  # A full disk: the 64 KiB buffer fills inside the loop's out().
  cat > "$p" <<'EOF'
i = 0
loop i < 100000
    out("line " . i)
    i = i + 1
EOF
  nm="out() into a full disk (/dev/full) is a located fault"
  if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
    got=$($TO "$exe" 2>&1 >/dev/full); rc=$?
    if [ "$got" = "p.w:3: could not write standard output" ] && [ "$rc" = 70 ]; then ok "$nm"
    else bad "$nm" "got [$got] rc=$rc"; fi
  else bad "$nm" "build failed"; fi
fi

# A descriptor another process left non-blocking (a pipe from Node, say) answers
# EAGAIN when it is full or empty. out() and err() wait for room and in() waits
# for input. They used to take it as a failure: 97% of a 2.3 MB output was lost
# with the program's normal status, and ended() said true before the first line
# had arrived. The parent here makes its end O_NONBLOCK, so the program's end is
# too, and reads or writes nothing for half a second. And when whoever started
# the program ignored SIGPIPE, a write into a pipe with no reader fails with
# EPIPE instead of ending it: that still ends it with 141, the status SIGPIPE
# gives.
if [ "$win" = 0 ] && command -v python3 >/dev/null 2>&1; then
  cat > "$tmp/nb.py" <<'PY'
import os, subprocess, time, fcntl, sys
mode, prog = sys.argv[1], sys.argv[2:]
r, w = os.pipe()
if mode in ("out", "err"):
    fcntl.fcntl(w, fcntl.F_SETFL, fcntl.fcntl(w, fcntl.F_GETFL) | os.O_NONBLOCK)
    if mode == "out":
        p = subprocess.Popen(prog, stdout=w, stderr=subprocess.PIPE)
    else:
        p = subprocess.Popen(prog, stderr=w, stdout=subprocess.PIPE)
    os.close(w)
    time.sleep(0.5)
    data = b''
    while True:
        chunk = os.read(r, 1 << 20)
        if not chunk:
            break
        data += chunk
    rc = p.wait()
    other = (p.stderr if mode == "out" else p.stdout).read().decode().strip()
    print("bytes", len(data), "lines", data.count(b'\n'), "rc", rc, other)
elif mode == "in":
    fcntl.fcntl(r, fcntl.F_SETFL, fcntl.fcntl(r, fcntl.F_GETFL) | os.O_NONBLOCK)
    p = subprocess.Popen(prog, stdin=r, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    os.close(r)
    time.sleep(0.5)
    try:
        os.write(w, b"first\nsecond\n42\n")
    except BrokenPipeError:
        pass
    os.close(w)
    out = p.communicate()[0].decode()
    print(out.replace("\n", "|") + "rc " + str(p.returncode))
else:
    # restore_signals=False keeps the SIGPIPE Python ignores.
    os.close(r)
    p = subprocess.Popen(prog, stdout=w, stderr=subprocess.DEVNULL, restore_signals=False)
    os.close(w)
    print("rc", p.wait())
PY
  printf 'i = 0\nloop i < 200000\n    out("line " . i)\n    i = i + 1\nerr("finished")\nreturn 5\n' > "$tmp/nbo.w"
  printf 'i = 0\nloop i < 200000\n    err("line " . i)\n    i = i + 1\nout("finished")\nreturn 5\n' > "$tmp/nbe.w"
  cat > "$tmp/nbi.w" <<'EOF'
out("ended " . ended())
x = in()
out("first " . x)
n = 0
loop
    if ended()
        break
    y = in()
    n = n + 1
out("more " . n)
EOF
  nbwant="bytes 2288890 lines 200000 rc 5 finished"
  for arch in x86-64 arm64; do
    fl=""; run=""
    if [ "$arch" = arm64 ]; then [ -n "$QEMU" ] || continue; fl="-arm64"; run="$QEMU"; fi
    built=1
    for m in o e i; do
      "$WORD" build $fl "$tmp/nb$m.w" -o "$tmp/nb$m" >/dev/null 2>&1 || built=0
    done
    if [ "$built" = 0 ]; then bad "non-blocking descriptors on $arch" "build failed"; continue; fi
    got=$($TO python3 "$tmp/nb.py" out $run "$tmp/nbo" 2>&1)
    if [ "$got" = "$nbwant" ]; then ok "out() into a non-blocking pipe loses nothing ($arch)"
    else bad "out() into a non-blocking pipe ($arch)" "got [$got] want [$nbwant]"; fi
    got=$($TO python3 "$tmp/nb.py" err $run "$tmp/nbe" 2>&1)
    if [ "$got" = "$nbwant" ]; then ok "err() into a non-blocking pipe loses nothing ($arch)"
    else bad "err() into a non-blocking pipe ($arch)" "got [$got] want [$nbwant]"; fi
    got=$($TO python3 "$tmp/nb.py" in $run "$tmp/nbi" 2>&1)
    want="ended false|first first|more 2|rc 0"
    if [ "$got" = "$want" ]; then ok "in() and ended() wait for a non-blocking stdin ($arch)"
    else bad "in() from a non-blocking stdin ($arch)" "got [$got] want [$want]"; fi
    got=$($TO python3 "$tmp/nb.py" pipe $run "$tmp/nbo" 2>&1)
    if [ "$got" = "rc 141" ]; then ok "out() into a gone reader with SIGPIPE ignored ends with 141 ($arch)"
    else bad "out() with SIGPIPE ignored ($arch)" "got [$got] want [rc 141]"; fi
  done
fi

echo ""
echo "== small stacks, and faults before the first statement =="
# Under a stack limit of 128 KB or less, the 128 KB kept back for the fault
# message left nothing, and every program stopped at once with `stack exhausted`
# in the top level's prologue, reported at line 0, which no file has. What is
# kept back is a quarter of a stack that small now. A fault before any statement
# has stored a line (here the arena that `ulimit -v` will not let it map) is
# reported at line 1. `ulimit -s` cannot shrink a Windows PE's stack.
if [ "$win" = 0 ]; then
  cat > "$p" <<'EOF'
deep(n)
    if n == 0
        return 0
    return 1 + deep(n - 1)

out("deep " . deep(100))
EOF
  if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
    for kb in 128 64; do
      nm="a program runs under a $kb KB stack limit"
      if ! ( ulimit -s $kb ) 2>/dev/null; then ok "$nm (SKIP: cannot pin the stack limit)"; continue; fi
      got=$( ( ulimit -s $kb; exec $TO "$exe" ) 2>&1 ); rc=$?
      if [ "$got" = "deep 100" ] && [ "$rc" = 0 ]; then ok "$nm"; else bad "$nm" "got [$got] rc=$rc"; fi
      if [ -n "$QEMU" ] && "$WORD" build -arm64 "$p" -o "$exe.a64" >/dev/null 2>&1; then
        got=$( ( ulimit -s $kb; exec $TO "$QEMU" "$exe.a64" ) 2>&1 ); rc=$?
        if [ "$got" = "deep 100" ] && [ "$rc" = 0 ]; then ok "$nm on arm64"; else bad "$nm on arm64" "got [$got] rc=$rc"; fi
      fi
    done
    # A frame bigger than the stack. The guard compared the stack pointer with
    # the limit before the frame was taken, so a frame bigger than what's kept
    # back below the limit (a quarter of a 128 KB stack) ran past the end of
    # the stack: SIGSEGV on x86-64, and on arm64, which checked after taking
    # the frame, rt_fail's first store faulted where the frame had moved sp. A
    # frame of a page or more is checked where it will end now. qemu gets a
    # guest stack of exactly the limit, so nothing past it is mapped.
    awk 'BEGIN{ n=25500; print "f(x)"; print "    s = 0"; print "    if x > 5"
      for(i=0;i<n;i++) printf "        a%d = %d\n", i, i
      for(c=0;c<n/500;c++){ printf "        s = s"; for(i=c*500;i<(c+1)*500;i++) printf " + a%d", i; print "" }
      print "    out(\"hi\")"; print "    return s"; print ""; print "out(f(1))" }' > "$tmp/huge.w"
    if "$WORD" build "$tmp/huge.w" -o "$exe.huge" >/dev/null 2>&1; then
      nm="a 200 KB frame under a 128 KB stack is stack exhausted, not a crash"
      if ( ulimit -s 128 ) 2>/dev/null; then
        got=$( ( ulimit -s 128; exec $TO "$exe.huge" ) 2>&1 ); rc=$?
        case "$got" in *"huge.w:"*": stack exhausted"*) m=1;; *) m=0;; esac
        if [ "$m" = 1 ] && [ "$rc" = 70 ]; then ok "$nm"; else bad "$nm" "got [$got] rc=$rc"; fi
        got=$( ( ulimit -s 8192; exec $TO "$exe.huge" ) 2>&1 ); rc=$?
        if [ "$got" = "hi
0" ] && [ "$rc" = 0 ]; then ok "and it runs under an 8 MB stack"; else bad "a 200 KB frame under 8 MB" "got [$got] rc=$rc"; fi
        if [ -n "$QEMU" ] && "$WORD" build -arm64 "$tmp/huge.w" -o "$exe.huge64" >/dev/null 2>&1; then
          got=$( ( ulimit -s 128; exec $TO "$QEMU" -s 131072 "$exe.huge64" ) 2>&1 ); rc=$?
          case "$got" in *"huge.w:"*": stack exhausted"*) m=1;; *) m=0;; esac
          if [ "$m" = 1 ] && [ "$rc" = 70 ]; then ok "$nm on arm64"; else bad "$nm on arm64" "got [$got] rc=$rc"; fi
          got=$( ( ulimit -s 8192; exec $TO "$QEMU" "$exe.huge64" ) 2>&1 ); rc=$?
          if [ "$got" = "hi
0" ] && [ "$rc" = 0 ]; then ok "and it runs under an 8 MB stack on arm64"; else bad "a 200 KB frame under 8 MB on arm64" "got [$got] rc=$rc"; fi
        fi
      else ok "$nm (SKIP: cannot pin the stack limit)"; fi
    else bad "a 200 KB frame" "build failed"; fi
    nm="a fault before the first statement is at line 1, never line 0"
    got=$( ( ulimit -v 20000; exec "$exe" ) 2>&1 ); rc=$?
    case "$got" in
      "p.w:1: could not map region space")
        if [ "$rc" = 70 ]; then ok "$nm"; else bad "$nm" "rc=$rc"; fi ;;
      *"could not map"*) bad "$nm" "got [$got] rc=$rc" ;;
      *) ok "$nm (SKIP: ulimit -v did not stop the arena here: [$got])" ;;
    esac
  else bad "small stacks" "build failed"; fi
fi

if [ "$win" = 1 ]; then
echo ""
echo "== Windows: files open elsewhere, hidden files, failed writes, listings =="
wd="$tmp/win"
mkdir -p "$wd"
# read() shared only reading, and write() and append() shared nothing, so a file
# another program had open for writing (a log, say) could not be read, appended
# to or replaced, and each looked like a missing file. Here the shell holds it.
printf 'hello log\n' > "$wd/log.txt"
cat > "$p" <<EOF
r = read("$wd/log.txt")
n = 0 - 1
if r != none
    n = len(r)
a = append("$wd/log.txt", "z")
w = write("$wd/log.txt", "new")
out(n . " " . a . " " . w . " " . read("$wd/log.txt"))
EOF
nm="a file another program has open for writing can be read, appended to and replaced"
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  exec 3>>"$wd/log.txt"
  got=$($TO "$exe" 2>&1); rc=$?
  exec 3>&-
  if [ "$got" = "10 true true new" ] && [ "$rc" = 0 ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc want [10 true true new]"; fi
else bad "$nm" "build failed"; fi

# CREATE_ALWAYS refuses to replace a hidden or system file, so write() answered
# false where append() worked. The file keeps its attributes, as a Linux file
# keeps its mode.
printf 'old\n' > "$wd/h.txt"
attrib +h "$(cygpath -w "$wd/h.txt")" >/dev/null 2>&1
crun "write() replaces a hidden file" "true new" <<EOF
out(write("$wd/h.txt", "new") . " " . read("$wd/h.txt"))
EOF
if attrib "$(cygpath -w "$wd/h.txt")" 2>/dev/null | cut -c1-20 | grep -q H; then ok "and the file is still hidden"
else bad "and the file is still hidden" "attrib: [$(attrib "$(cygpath -w "$wd/h.txt")" 2>&1)]"; fi
attrib -h "$(cygpath -w "$wd/h.txt")" >/dev/null 2>&1

# WriteFile's answer was thrown away and the length asked for handed back, so a
# write that failed answered true. A named pipe whose server takes the
# connection and closes it without reading makes the write fail every time.
if command -v python3 >/dev/null 2>&1; then
  rm -f "$wd/pipename"
  python3 - "$wd/pipename" >/dev/null 2>&1 <<'PY' &
import _winapi, os, sys
name = r'\\.\pipe\word_gaps_' + str(os.getpid())
# PIPE_ACCESS_INBOUND is 1; byte mode and blocking waits are 0.
h = _winapi.CreateNamedPipe(name, 1, 0, 1, 65536, 65536, 0, _winapi.NULL)
with open(sys.argv[1] + '.tmp', 'w') as f:
    f.write(name)
os.replace(sys.argv[1] + '.tmp', sys.argv[1])
try:
    _winapi.ConnectNamedPipe(h, 0)
except OSError:
    pass
_winapi.CloseHandle(h)
PY
  srv=$!
  n=0; while [ ! -e "$wd/pipename" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  crun "a write that fails part way answers false" "false" <<EOF
s = "x"
i = 0
loop i < 22
    s = s . s
    i = i + 1
out(write(read("$wd/pipename"), s))
EOF
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
else ok "a write that fails part way answers false (SKIP: no python3 for the pipe server)"; fi

# dir() searches here, and three answers differed from Linux: dir("") listed the
# root of the current drive where Linux says none, dir("/") said none where
# Linux lists /, and a drive root lists no . and .. of its own. They are handed
# out ahead of its first entry now, as every other directory has them.
crun "dir of the empty path is none, as on Linux" "none" <<EOF
out(kind(dir("")))
EOF
drv=$(printf '%s' "$tmp" | cut -c1-2)
crun "dir of / and of $drv/ list the drive's root, . and .. first" ".|..|.|.." <<EOF
a = split(dir("/"), "\n")
b = split(dir("$drv/"), "\n")
out(a[0] . "|" . a[1] . "|" . b[0] . "|" . b[1])
EOF

# A bare drive, C: say, is that drive's current directory to Windows, and to
# read() and write(), which hand a path over as written. dir("C:") listed the
# root of C: instead. C:/ and C:\ are still the root.
mkdir -p "$wd/cwd"; : > "$wd/cwd/drv-marker"
cat > "$p" <<'EOF'
d = args()[1]
m = encode("drv-marker")
out((dir(d) == dir(".")) . " " . (find(dir(d . "/"), m) == none) . " " . (dir(d . "/") == dir(d . "\\")))
EOF
nm="dir of a bare drive lists that drive's current directory"
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$(cd "$wd/cwd" && $TO "$exe" "$(pwd -W | cut -c1-2)" 2>&1); rc=$?
  if [ "$got" = "true true true" ] && [ "$rc" = 0 ]; then ok "$nm"; else bad "$nm" "got [$got] rc=$rc"; fi
else bad "$nm" "build failed"; fi

# cmd.exe keeps each drive's current directory in the environment as a hidden
# =C:=C:\dir entry, and env() matched a name across its first =: env("")
# answered "C:=C:\dir" and env("=C:") answered "C:\dir". No variable is named ""
# or has an = in its name, so both are none, as env("A=B") is on Linux.
mkdir -p "$wd/cwd"
cat > "$p" <<'EOF'
out((env("") == none) . " " . (env("=" . args()[1]) == none) . " " . (env("PATH") != none))
EOF
nm="env() of \"\" and of a hidden =C: entry is none"
if "$WORD" build "$p" -o "$exe.exe" >/dev/null 2>&1; then
  d=$(cd "$wd/cwd" && pwd -W | cut -c1-2)
  got=$(cmd //c "cd /d $(cygpath -w "$wd/cwd") && $(cygpath -w "$exe.exe") $d" 2>&1 | tr -d '\r')
  if [ "$got" = "true true true" ]; then ok "$nm"; else bad "$nm" "got [$got]"; fi
else bad "$nm" "build failed"; fi

# The A search handed names back through a 260-byte buffer, so a name longer than
# 259 bytes of UTF-8 never appeared in a listing, though word could write it and
# read it back: 90 CJK characters are 270 bytes.
mkdir -p "$wd/long"
crun "dir lists a name longer than 259 bytes of UTF-8" "true true" <<EOF
nm = ""
i = 0
loop i < 90
    nm = nm . char(26085)
    i = i + 1
w = write("$wd/long/" . nm, "x")
out(w . " " . (find(dir("$wd/long"), encode(nm)) != none))
EOF
# The shell's own listing stops at 255 bytes too, so rm -rf cannot remove it.
cmd //c rmdir //s //q "$(cygpath -w "$wd/long")" >/dev/null 2>&1

# The listing grows through the shim's getdents records as it does on Linux:
# 4,500 names of 247 bytes are over a megabyte, where dir() used to stop.
mkdir -p "$wd/big"
z=$(printf '%240s' '' | tr ' ' z)
i=10000
while [ "$i" -lt 14500 ]; do : > "$wd/big/n${i}_$z"; i=$((i + 1)); done
want="$(ls -a "$wd/big" | wc -l | tr -d ' ') $(ls -a "$wd/big" | wc -c | tr -d ' ')"
crun "dir lists every entry of a listing over 1 MB" "$want" <<EOF
d = dir("$wd/big")
n = 0
i = 0
loop i < len(d)
    if d[i] == 10
        n = n + 1
    i = i + 1
out(n . " " . len(d))
EOF
fi

echo "test_gaps: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
