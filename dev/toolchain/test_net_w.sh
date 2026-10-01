#!/bin/sh
# test_net_w.sh: the `net` library is word source, compiled into the program
# that uses it, so a net program builds for every target. (The old net was
# 12,303 lines of hand-written x86-64, and `word build -arm64` refused a
# program that called get().)
#
# It checks that a net program builds for x86-64 and arm64 and carries the
# library, and that a program that never uses the network carries none of it.
# Then how the bundled library behaves: it builds from a directory holding only
# the binary, a fault inside it reports the program's own line, and a
# program's own functions win over the library's.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd); cd "$root"
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1 -- $2"; fail=$((fail+1)); }

printf 'b = get("https://example.com/")\nout(len(b))\n' > "$tmp/net.w"
printf 'out(1)\n' > "$tmp/plain.w"

# 1/2: it builds for both targets from the one source.
"$WORD" build "$tmp/net.w" -o "$tmp/net.x86" >"$tmp/e" 2>&1 \
  && ok "a net program builds for x86-64" \
  || bad "x86-64 net build" "$(head -1 "$tmp/e")"
"$WORD" build -arm64 "$tmp/net.w" -o "$tmp/net.a64" >"$tmp/e" 2>&1 \
  && ok "a net program builds for arm64 (this is the whole point)" \
  || bad "arm64 net build" "$(head -1 "$tmp/e")"

# 3: what it carries is the word library, as ordinary compiled functions.
"$WORD" build -asm "$tmp/net.w" > "$tmp/net.s" 2>/dev/null
if grep -q '^fn_net_fetch:' "$tmp/net.s" && grep -q '^fn_tls13_client_hello:' "$tmp/net.s" \
   && grep -q '^fn_dns_resolve:' "$tmp/net.s"; then
  ok "it carries the bundled word net library"
else bad "bundling" "the net program does not carry the word library"; fi

# 4: and a program that never reaches the network carries none of it.
"$WORD" build -asm "$tmp/plain.w" > "$tmp/plain.s" 2>/dev/null
if ! grep -q 'net_fetch\|tls13_\|dns_resolve' "$tmp/plain.s"; then
  ok "a program that never calls net carries none of the library"
else bad "gating" "the net library leaked into a program that does not use it"; fi

# 5: the prescan reads code, not comments or strings. word.w mentions get() in
# comments, and taking those for calls made the compiler bundle the library
# into itself.
printf '// get(x) in a comment\ns = "post(y) in a string"\nout(len(s))\n' > "$tmp/cmt.w"
"$WORD" build -asm "$tmp/cmt.w" > "$tmp/cmt.s" 2>/dev/null
if ! grep -q 'net_fetch\|tls13_' "$tmp/cmt.s"; then
  ok "a net verb in a comment or a string does not bundle the library"
else bad "prescan" "a comment or string was taken for a call"; fi

# 6: the unused-function check does not fire on the bundled library, but still
# fires on the programmer's own code.
printf 'unused_here()\n    return 1\nb = get("https://example.com/")\nout(len(b))\n' > "$tmp/uf.w"
if "$WORD" build "$tmp/uf.w" -o "$tmp/uf" >"$tmp/e" 2>&1; then
  bad "unused check" "an unused function in the program was not reported"
else
  grep -q "function 'unused_here' is defined but never used" "$tmp/e" \
    && ok "the unused check still applies to the program, not to the library" \
    || bad "unused check" "wrong error: $(head -1 "$tmp/e")"
fi

# 7: the binary carries the library, so a directory with nothing else in it can
# build a program that speaks HTTPS.
#
# `net` is word source compiled into the calling program, so the compiler needs
# that source. It used to be files on disk (runtime/crypto/*.w) read relative
# to the working directory. Now it lives in a region of compiler/word.w, which
# the compiler lifts out while building itself (netlib_embed), so the text is
# in the binary and nothing has to be found at build time.
#
# The directory below holds the binary and one .w file, and nothing else, so
# this fails if the library is ever read from disk again.
bare=$(mktemp -d)
cp "$WORD" "$bare/word"
printf 'b = get("https://example.com/")\nout(len(b))\n' > "$bare/net.w"
if ( cd "$bare" && ./word build net.w -o here >"$bare/e" 2>&1 ) && [ -x "$bare/here" ]; then
  ok "a net program builds where only the binary and the source exist"
else
  bad "bare-directory build" "$(head -3 "$bare/e")"
fi

# And for every target, since the library is word source so that one source
# builds them all.
for t in -win -arm64 -mac; do
  if ( cd "$bare" && ./word build $t net.w -o "here$t" >"$bare/e" 2>&1 ) && [ -s "$bare/here$t" ]; then
    ok "and cross-compiles there for $t"
  else
    bad "bare-directory build $t" "$(head -3 "$bare/e")"
  fi
done
rm -rf "$bare"

# 8: a fault inside the bundled library reports the program's own line.
#
# The library is compiled in after the program's last line, so its lines
# aren't lines of any file the program has: this fault used to say `lf.w:5548`
# for a four-line lf.w (SPEC 10.2). None of the library's statements stores a
# line, so a fault inside it reports the program's statement that called the
# verb, on both targets.
#
# The url is an array, so the call's region check lets it through, and its
# first element is text, which the library's URL parser compares with a number.
# In the second program the call is inside the program's own function, and
# that's the line reported.
QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
libfault() { # libfault <name> <want> ; program on stdin
  cat > "$tmp/lf.w"
  if ! "$WORD" build "$tmp/lf.w" -o "$tmp/lf" >"$tmp/e" 2>&1; then
    bad "$1" "x86-64 build: $(head -1 "$tmp/e")"; return; fi
  got=$("$tmp/lf" 2>&1 </dev/null) && rc=0 || rc=$?
  if [ "$rc/$got" != "70/$2" ]; then bad "$1" "x86-64 exit $rc [$got], want exit 70 [$2]"; return; fi
  if [ -n "$QEMU" ]; then
    if ! "$WORD" build -arm64 "$tmp/lf.w" -o "$tmp/lfa" >"$tmp/e" 2>&1; then
      bad "$1" "arm64 build: $(head -1 "$tmp/e")"; return; fi
    got=$($QEMU "$tmp/lfa" 2>&1 </dev/null) && rc=0 || rc=$?
    if [ "$rc/$got" != "70/$2" ]; then bad "$1" "arm64 exit $rc [$got], want exit 70 [$2]"; return; fi
  fi
  ok "$1"
}
libfault "a fault inside the library names the line that called the verb" \
  'lf.w:3: cannot order-compare a number and text' <<'EOF'
u = array(8)
u[0] = "h"
b = get(u)
out(len(b))
EOF
libfault "and inside the program's own function, the line there" \
  'lf.w:2: cannot order-compare a number and text' <<'EOF'
fetch(u)
    r = get(u)
    return r
u = array(8)
u[0] = "h"
out(len(fetch(u)))
EOF

# 9: a program that defines its own verb and calls only that carries none of
# the library. Its own `get` is what runs (SPEC 12). It used to carry the whole
# library anyway, about 385 KB of it.
printf 'get(u)\n    return "my get"\nout(get("x"))\n' > "$tmp/own.w"
"$WORD" build -asm "$tmp/own.w" > "$tmp/own.s" 2>/dev/null
if ! grep -q 'net_fetch\|tls13_' "$tmp/own.s"; then
  ok "a program that defines its own get carries none of the library"
else bad "own verb" "the library was bundled for a program whose get is its own"; fi
"$WORD" build "$tmp/own.w" -o "$tmp/own" >"$tmp/e" 2>&1 || true
if [ "$("$tmp/own" 2>&1)" = "my get" ]; then ok "and its own get is what runs"
else bad "own verb" "$(head -1 "$tmp/e")"; fi

# 10: the library is compiled into the program and names are global, so a
# program function with the same name as one of the library's (sha256,
# http_parse_url, ...) used to be a duplicate definition, reported in a file
# the programmer doesn't have. Now the program's function wins, and the library
# keeps calling its own. "not a url" has spaces in it, so each get stops in the
# library's URL parser, before any name lookup or socket.
clash() { # clash <name> <want stdout> ; the program is in $tmp/clash.w
  for tgt in x86 arm64; do
    flag=; runner=
    if [ "$tgt" = arm64 ]; then
      [ -n "$QEMU" ] || continue
      flag=-arm64; runner=$QEMU
    fi
    if "$WORD" build $flag "$tmp/clash.w" -o "$tmp/clash.$tgt" >"$tmp/e" 2>&1; then
      got=$($runner "$tmp/clash.$tgt" 2>/dev/null || true)
      if [ "$got" = "$2" ]; then ok "$tgt: $1"
      else bad "$tgt: $1" "printed [$got], want [$2]"; fi
    else bad "$tgt: $1" "build failed: $(head -1 "$tmp/e")"; fi
  done
}
printf 'sha256(x)\n    return "mine " . x\nb = get("not a url")\nout(kind(b))\nout(sha256("abc"))\n' > "$tmp/clash.w"
clash "a program's own sha256 wins over the library's" "$(printf 'none\nmine abc')"
printf 'http_parse_url(u)\n    out("mine")\n    return 0\nb = get("not a url")\nout(kind(b))\nhttp_parse_url("x")\n' > "$tmp/clash.w"
clash "the library keeps calling its own http_parse_url" "$(printf 'none\nmine')"
printf 'net_fetch(a)\n    return "mine"\nb = get("not a url")\nout(kind(b))\nout(net_fetch(1))\n' > "$tmp/clash.w"
clash "a verb still reaches the library's net_fetch when the program has one" "$(printf 'none\nmine')"

echo ""
echo "test_net_w: $pass passed, $fail failed"
[ "$fail" = 0 ]
