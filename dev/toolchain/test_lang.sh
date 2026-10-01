#!/bin/sh
# test_lang.sh: the language and CLI conformance suite. It runs every `word`
# subcommand (build, run, asm, verify, version, bootstrap and format, plus the
# no-argument and unknown-command paths) and every contract path (:before and
# :after, shared, recursive, inside a hook) for both success and failure, and
# checks that a rejected program gets a source-located diagnostic it can act on
# instead of an internal compiler fault. It guards contracts and the
# error-reporting rule (file:line:col: message, and never a line of the
# compiler's own source).
#
# No `set -e`, since most cases here are meant to make `word` exit nonzero and
# the exit code is what they check.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
# On Windows word.exe is a native program: a path written into a program's text
# has to be one Windows can open, and /tmp/x is \tmp\x on the current drive.
# hostpath is the identity everywhere else. win=1 marks the cases that ask
# Linux-only questions (strace, running an ELF), which skip there.
. "$here/hostpath.sh"; win=0
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in msys*|cygwin*|win32|MINGW*|MSYS*|CYGWIN*) win=1;; esac
WORD=${WORD:-"$root/word"}; tmp=$(hostpath "$(mktemp -d)"); trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"
cd "$root"                      # verify/bootstrap read compiler/word.w relatively
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 20"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  OK   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1 -- $2"; }
p="$tmp/p.w"; exe="$tmp/p"

# is_elf <file>: the file starts with the ELF magic.
is_elf() { [ "$(head -c4 "$1" | od -An -c | tr -d ' \n')" = "177ELF" ]; }
# An ELF does not run on Windows, so there the cases that build one check that
# it is an ELF and say they skipped running it.
elfnote=""; [ "$win" = 1 ] && elfnote=" (SKIP running it: an ELF does not run on Windows)"

# Build $p; the build must succeed (exit 0). The program is on stdin.
cbuild() { cat > "$p"
  if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then ok "$1"
  else bad "$1" "build failed: $("$WORD" build "$p" -o "$exe" 2>&1)"; fi; }

# Build+run $p; expect exit 0 and stdout exactly $2. Program from stdin.
crun() { cat > "$p"; nm="$1"; want="$2"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then bad "$nm" "build failed"; return; fi
  got=$($TO "$exe" 2>&1); rc=$?
  if [ "$got" = "$want" ] && [ "$rc" = 0 ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc want [$want] rc=0"; fi; }

# Build+run $p; expect the process to exit with code $2 (e.g. `return N`).
cexit() { cat > "$p"; nm="$1"; erc="$2"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then bad "$nm" "build failed"; return; fi
  $TO "$exe" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "$erc" ]; then ok "$nm"; else bad "$nm" "exit=$rc want $erc"; fi; }

# Build OK, then run and expect it to die, with $2 on stderr and exit code $3.
cdie() { cat > "$p"; nm="$1"; sub="$2"; erc="$3"
  if ! "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then bad "$nm" "build failed (expected build to succeed, fault at run)"; return; fi
  got=$($TO "$exe" 2>&1); rc=$?
  case "$got" in *"$sub"*) m=1;; *) m=0;; esac
  if [ "$m" = 1 ] && [ "$rc" = "$erc" ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc want substr [$sub] rc=$erc"; fi; }

# Expect a compile error: build fails (exit 1), the diagnostic contains $2, it's
# source-located (a "<file>.w:" prefix, not an internal compiler line), and it
# goes to stderr with stdout left empty. The program is on stdin.
#
# The stream matters. A diagnostic on stdout is swallowed by
# `word build app.w > out` and invisible to `2> errors.log`, and it would mix
# into the assembly that `build -asm` writes to stdout. This helper used to
# capture with 2>&1, which is why nothing noticed diagnostics were on the wrong
# stream, so every case below checks the split as well as the text.
cerr() { cat > "$p"; nm="$1"; sub="$2"
  sout=$("$WORD" build "$p" -o "$exe" 2>"$tmp/diag"); rc=$?
  got=$(cat "$tmp/diag")
  case "$got" in *"$sub"*) m=1;; *) m=0;; esac
  case "$got" in *"p.w:"*) loc=1;; *) loc=0;; esac
  if [ "$m" = 1 ] && [ "$rc" = 1 ] && [ "$loc" = 1 ] && [ -z "$sout" ]; then ok "$nm"
  else bad "$nm" "stderr=[$got] stdout=[$sout] rc=$rc (want substr [$sub] on stderr, rc=1, located=$loc, empty stdout)"; fi; }

# Raw CLI check: run `word $4...`, expect output substring $2 and exit code $3.
cli() { nm="$1"; sub="$2"; erc="$3"; shift 3
  got=$("$WORD" "$@" 2>&1); rc=$?
  case "$got" in *"$sub"*) m=1;; *) m=0;; esac
  if [ "$m" = 1 ] && [ "$rc" = "$erc" ]; then ok "$nm"
  else bad "$nm" "rc=$rc want $erc; out=[$got]"; fi; }

# cerr on both targets: the arm64 build has to fail too, with the same text. A
# parse or analysis error comes before either code generator runs, so the two
# have nothing to disagree on. The cases that use this are ones where they did:
# x86-64 dropped a statement and arm64 refused the program with no location.
cerr_both() { cat > "$p"; nm="$1"; sub="$2"
  sout=$("$WORD" build "$p" -o "$exe" 2>"$tmp/diag"); rc=$?
  got=$(cat "$tmp/diag")
  "$WORD" build -arm64 "$p" -o "$exe.a64" >/dev/null 2>"$tmp/diag.a64"; rca=$?
  gota=$(cat "$tmp/diag.a64")
  case "$got" in *"$sub"*) m=1;; *) m=0;; esac
  case "$got" in *"p.w:"*) loc=1;; *) loc=0;; esac
  if [ "$m" = 1 ] && [ "$rc" = 1 ] && [ "$loc" = 1 ] && [ -z "$sout" ] && [ "$rca" = 1 ] && [ "$gota" = "$got" ]; then ok "$nm"
  else bad "$nm" "x86-64 stderr=[$got] rc=$rc, arm64 stderr=[$gota] rc=$rca (want substr [$sub] on stderr, rc=1, the same on both)"; fi; }

echo "== commands: build =="
cbuild "build: valid program" <<'EOF'
out("hi")
EOF
cerr  "build: rejects a bad program with a located error" "undefined variable 'zzz'" <<'EOF'
out(zzz)
EOF
cli   "build: missing file -> cannot read, exit 1" "cannot read" 1 build "$tmp/does-not-exist.w"
cli   "build: no source arg -> usage, exit 1"      "usage: word build" 1 build
# net on the Windows target: -win now cross-compiles a net program to a PE (the
# ws2_32 + Crypt32 socket/trust-store support links in). Assert the build
# succeeds and emits a PE (MZ magic); the import-table check is in test_win_pe.
printf 'import net\nbody = get("http://example.com")\nout(len(body))\n' > "$tmp/net.w"
if "$WORD" build -win "$tmp/net.w" -o "$tmp/net.exe" >/dev/null 2>&1 && [ "$(head -c2 "$tmp/net.exe" 2>/dev/null)" = "MZ" ]; then
  ok "build: -win cross-compiles a net program to a PE"
else
  bad "build: -win cross-compiles a net program to a PE" "build -win failed or output is not a PE"
fi

# The other half of the -win/-linux pair had no test at all. On a Linux host
# -linux is the default, so the useful checks are that it's accepted, that it
# really selects the Linux target instead of being ignored, and that it doesn't
# pick up the .exe naming -win adds.
printf 'out("linux target")\n' > "$tmp/lt.w"
if "$WORD" build -linux "$tmp/lt.w" -o "$tmp/lt" >/dev/null 2>&1 \
   && is_elf "$tmp/lt" \
   && { [ "$win" = 1 ] || [ "$($TO "$tmp/lt")" = "linux target" ]; }; then
  ok "build: -linux emits an ELF that runs$elfnote"
else
  bad "build: -linux emits an ELF that runs" "not an ELF, or it did not run"
fi

# -linux is the host default here, so the two must agree byte for byte. That
# catches -linux selecting something else without a word. On Windows the host
# default is -win. The outputs have different names, which a PE's bytes do not
# depend on.
if [ "$win" = 1 ]; then
  if "$WORD" build -win "$tmp/lt.w" -o "$tmp/lt_win.exe" >/dev/null 2>&1 \
     && "$WORD" build "$tmp/lt.w" -o "$tmp/lt_def.exe" >/dev/null 2>&1 \
     && cmp -s "$tmp/lt_win.exe" "$tmp/lt_def.exe"; then
    ok "build: -win is byte-identical to the host default on Windows"
  else
    bad "build: -win == host default" "the two builds differ"
  fi
elif "$WORD" build "$tmp/lt.w" -o "$tmp/lt_def" >/dev/null 2>&1 && cmp -s "$tmp/lt" "$tmp/lt_def"; then
  ok "build: -linux is byte-identical to the host default on Linux"
else
  bad "build: -linux == host default" "the two builds differ"
fi

# The OS boundary is the syscall shim (SPEC §14): the Linux target issues raw
# syscalls, the Windows one routes them through w_syscall. Diffing the emitted
# assembly proves the flag reaches codegen instead of only naming the output.
lin_shim=$("$WORD" build -linux -asm "$tmp/lt.w" 2>/dev/null | grep -c "call w_syscall" || true)
win_shim=$("$WORD" build -win   -asm "$tmp/lt.w" 2>/dev/null | grep -c "call w_syscall" || true)
if [ "$lin_shim" = 0 ] && [ "$win_shim" -gt 0 ]; then
  ok "build: -linux emits raw syscalls, -win routes them through w_syscall"
else
  bad "build: -linux vs -win syscall shim" "linux=$lin_shim win=$win_shim (want 0 and >0)"
fi

# A defaulted output name gets .exe for the Windows target and not for Linux.
( cd "$tmp" && rm -f lt lt.exe
  "$WORD" build -linux lt.w >/dev/null 2>&1
  [ -f lt ] && [ ! -f lt.exe ] ) \
  && ok "build: -linux with no -o does not add .exe" \
  || bad "build: -linux default output name" "expected lt, not lt.exe"

# A build never writes over a file the program is built from. A source with no
# extension to drop derives an output name that is its own, and -o can name a
# source by any spelling; each used to exit 0 with the executable where the
# source had been. -linux because a -win output gains .exe and misses it.
ow="$tmp/ow"; mkdir -p "$ow/f"
printf 'out("x")\n' > "$ow/noext"; printf 'out("h")\n' > "$ow/.hidden"; printf 'out("s")\n' > "$ow/same.w"
printf 'out(h())\n' > "$ow/f/app.w"; printf 'h()\n    return 5\n' > "$ow/f/util.w"
printf '.intel_syntax noprefix\n.global _start\n.text\n_start:\n    mov rax, 60\n    xor rdi, rdi\n    syscall\n' > "$ow/a.s"
owcase() { # name, the file that must be left as it was, then word's arguments (run in $ow)
  nm="$1"; keep="$2"; shift 2
  cp "$keep" "$tmp/ow.keep"
  got=$(cd "$ow" && "$WORD" "$@" 2>&1); rc=$?
  if [ "$rc" = 1 ] && printf '%s' "$got" | grep -q 'would overwrite the' && cmp -s "$keep" "$tmp/ow.keep"; then ok "$nm"
  else bad "$nm" "rc=$rc [$got]"; fi; }
owcase "build: a source with no extension is not its own output" "$ow/noext" build -linux noext
owcase "build: a dotfile source is not its own output" "$ow/.hidden" build -linux .hidden
owcase "build: -o naming the source is refused" "$ow/same.w" build same.w -o same.w
owcase "build: -o naming the source by another spelling is refused" "$ow/same.w" build ./same.w -o "$ow/same.w"
owcase "build: -o naming a sibling of a folder program is refused" "$ow/f/util.w" build f/app.w -o f/util.w
owcase "asm: the output naming an input is refused" "$ow/a.s" asm -linux a.s a.s
if (cd "$ow" && "$WORD" build -linux noext -o noext.bin >/dev/null 2>&1) && is_elf "$ow/noext.bin"; then
  ok "build: a source with no extension builds with -o"
else bad "build: a source with no extension builds with -o" "no ELF at noext.bin"; fi

# build's flags go anywhere, and what it does not know is a usage error. A
# target flag after the file name was dropped (the host was built), -asm
# ignored -o, extra words were ignored, and an unknown flag or a leading -o was
# read as the source ("cannot read -x").
ba="$tmp/ba"; mkdir -p "$ba"; printf 'out("hi")\n' > "$ba/hi.w"
xt=-win; xm=MZ; [ "$win" = 1 ] && { xt=-linux; xm=$(printf '\177ELF'); }
rm -f "$ba/after.out"
if "$WORD" build "$ba/hi.w" $xt -o "$ba/after.out" >/dev/null 2>&1 && [ "$(head -c${#xm} "$ba/after.out")" = "$xm" ]; then
  ok "build: a target flag after the source is honoured ($xt)"
else bad "build: a target flag after the source" "no $xt output"; fi
if "$WORD" build -o "$ba/first.out" -linux "$ba/hi.w" >/dev/null 2>&1 && is_elf "$ba/first.out"; then
  ok "build: -o before the source"
else bad "build: -o before the source" "no output"; fi
sout=$("$WORD" build -asm "$ba/hi.w" -o "$ba/hi.s" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ -z "$sout" ] && grep -q '_start' "$ba/hi.s" 2>/dev/null; then
  ok "build: -asm writes the assembly to -o, not stdout"
else bad "build: -asm with -o" "rc=$rc stdout=$(printf '%s' "$sout" | head -c 80)"; fi
bu() { # name, expected message, then build's arguments; exit 1, the usage line, no output file
  nm="$1"; want="$2"; shift 2
  rm -f "$ba/u.out"
  got=$("$WORD" build "$@" 2>&1); rc=$?
  if [ "$rc" = 1 ] && printf '%s' "$got" | grep -qF -e "$want" && printf '%s' "$got" | grep -q 'usage: word build' && [ ! -f "$ba/u.out" ]; then ok "$nm"
  else bad "$nm" "rc=$rc [$got]"; fi; }
bu "build: an extra word is a usage error"   "one source at a time, but got $ba/hi.w and extra" "$ba/hi.w" extra -o "$ba/u.out"
bu "build: an unknown flag is a usage error" "unknown flag -x" -x "$ba/hi.w" -o "$ba/u.out"
bu "build: -o with no name is a usage error" "-o needs a file name" "$ba/hi.w" -o
bu "build: two targets are a usage error"    "-win and -linux name two targets" -win -linux "$ba/hi.w" -o "$ba/u.out"
bu "build: -o twice is a usage error"        "-o given twice" "$ba/hi.w" -o "$ba/u.out" -o "$ba/u.out"

# An output that already exists gets the mode a new one would (0755 less the
# umask). The file was opened in place and kept its mode, so building over a
# 0600 file exited 0 and left a binary that could not run. Windows has no mode.
if [ "$win" = 0 ]; then
  for f in -linux -arm64; do
    rm -f "$ba/m$f"; touch "$ba/m$f"; chmod 600 "$ba/m$f"
    if "$WORD" build $f "$ba/hi.w" -o "$ba/m$f" >/dev/null 2>&1 && [ "$(ls -l "$ba/m$f" | cut -c1-10)" = "-rwxr-xr-x" ]; then
      ok "build: over a mode 600 file gives it 755 ($f)"
    else bad "build: over a mode 600 file ($f)" "$(ls -l "$ba/m$f")"; fi
  done
  [ "$("$ba/m-linux" 2>&1)" = hi ] && ok "build: ...and it runs" || bad "build: over a mode 600 file, it runs" "it did not"
  rm -f "$ba/mu"; touch "$ba/mu"; chmod 644 "$ba/mu"
  if (umask 077; "$WORD" build "$ba/hi.w" -o "$ba/mu" >/dev/null 2>&1) && [ "$(ls -l "$ba/mu" | cut -c1-10)" = "-rwx------" ]; then
    ok "build: over an existing file, the umask applies (077 gives 700)"
  else bad "build: over an existing file, the umask" "$(ls -l "$ba/mu")"; fi
fi

echo "== diagnostics go to stderr, output goes to stdout =="
# SPEC §9.1 gives programs err() so they can sit in a pipeline, and the compiler
# owes its callers the same split. These check it end to end.
printf 'out(nope)\n' > "$tmp/d.w"
if [ -z "$("$WORD" build "$tmp/d.w" -o "$tmp/d" 2>/dev/null)" ] \
   && [ -n "$("$WORD" build "$tmp/d.w" -o "$tmp/d" 2>&1 >/dev/null)" ]; then
  ok "diagnostics: a compile error is on stderr and nothing is on stdout"
else
  bad "diagnostics: compile error stream" "the error is not on stderr, or stdout was not empty"
fi

# usage and unknown-command are errors too, not output.
if [ -z "$("$WORD" build 2>/dev/null)" ] && [ -z "$("$WORD" nosuchcmd 2>/dev/null)" ] \
   && [ -n "$("$WORD" nosuchcmd 2>&1 >/dev/null)" ]; then
  ok "diagnostics: usage and unknown-command go to stderr"
else
  bad "diagnostics: usage stream" "usage/unknown-command still reaching stdout"
fi

# This is where the split matters most: `build -asm` writes assembly to stdout,
# so a diagnostic there would corrupt the file being redirected.
printf 'out("ok")\n' > "$tmp/g.w"
"$WORD" build -asm "$tmp/g.w" > "$tmp/g.s" 2>/dev/null
if [ -s "$tmp/g.s" ] && head -1 "$tmp/g.s" | grep -qv "\.w:"; then
  ok "diagnostics: build -asm keeps stdout clean for the assembly"
else
  bad "diagnostics: -asm stdout" "the assembly dump is empty or starts with a diagnostic"
fi

# word verify's success line is output, not a diagnostic, and stays on stdout.
if "$WORD" verify 2>/dev/null | grep -q "^word verify: OK"; then
  ok "diagnostics: word verify's success line stays on stdout"
else
  bad "diagnostics: verify success stream" "the OK line is not on stdout"
fi

echo "== source robustness =="
# A blank line inside a block must never be read as indent-0 code that dedents
# out of the enclosing block, whatever whitespace an editor or git leaves on it.
# The bug showed up as "expected a definition or statement at the top level" on
# a valid file. Each case has a blank line between the two statements of f's
# body, and they differ only in that blank line's bytes.
ws_ok() { # name : the blank line's bytes (may include \r, \t, spaces)
  printf 'f(x)\r\n    if x > 0\r\n        return 1\r\n%s\r\n    return 0\r\n\r\nout(f(7))\r\n' "$2" | tr -d '\r' > "$p"
  # (that built the LF variant; now also make a true CRLF variant)
  printf 'f(x)\r\n    if x > 0\r\n        return 1\r\n%s\r\n    return 0\r\n\r\nout(f(7))\r\n' "$2" > "$p.crlf"
  a=""; b=""
  "$WORD" build "$p" -o "$exe" >/dev/null 2>&1 && a=$($TO "$exe" 2>&1)
  "$WORD" build "$p.crlf" -o "$exe" >/dev/null 2>&1 && b=$($TO "$exe" 2>&1)
  if [ "$a" = "1" ] && [ "$b" = "1" ]; then ok "$1"; else bad "$1" "LF=[$a] CRLF=[$b]"; fi
}
ws_ok "blank line: empty"                 ""
ws_ok "blank line: trailing spaces"       "    "
ws_ok "blank line: a tab"                 "$(printf '\t')"
ws_ok "blank line: spaces then a tab"     "$(printf '  \t')"

echo "== indentation and stray bytes (SPEC 2.1, 2.2) =="
# Each of these used to compile. A tab in the indentation counted for nothing,
# so the line joined whatever block its spaces put it in. A dedent to a width no
# block had joined the next block out. A byte the lexer had no token for was
# skipped, so `café` read as `caf` and a pair of smart quotes left the name
# inside them. Each message has to point at the line and column that caused it.
printf 'x = 5\nif x > 10\n    out("big")\n\tout("inside?")\nout("end")\n' > "$tmp/ind.w"
cerr "a tab-indented line inside a block is an error" "p.w:4:1: indent with spaces, not tabs" < "$tmp/ind.w"
printf 'x = 1\nif x == 1\n\tout(1)\n' > "$tmp/ind.w"
cerr "a tab-indented block is an error" "p.w:3:1: indent with spaces, not tabs" < "$tmp/ind.w"
printf 'x = 1\nif x == 1\n  \tout(1)\n' > "$tmp/ind.w"
cerr "spaces then a tab is an error, at the tab" "p.w:3:3: indent with spaces, not tabs" < "$tmp/ind.w"
printf 'f(x)\n\treturn x\nout(f(1))\n' > "$tmp/ind.w"
cerr "a tab-indented function body is an error" "p.w:2:1: indent with spaces, not tabs" < "$tmp/ind.w"
# A tab between tokens, before a comment on a line of its own, or at the start
# of a line inside unmatched brackets is not indentation, and stays legal.
printf 'x = 1\t+ 2\nif x == 3\n    out(x)\t// ok\n\t// a comment line\n    out(1)\n' > "$tmp/ind.w"
crun "a tab between tokens or before a comment is fine" "$(printf '3\n1')" < "$tmp/ind.w"
printf 'x = add(1,\n\t2)\nout(x)\nadd(a, b)\n    return a + b\n' > "$tmp/ind.w"
crun "a tab at the start of a continuation line is fine" "3" < "$tmp/ind.w"
cerr "a dedent between two open blocks is an error" "p.w:4:7: inconsistent dedentation" <<'EOF'
f(x)
    if x
        out(1)
      out(2)
    return 0
f(true)
EOF
cerr "a dedent under a loop to no open block is an error" "p.w:4:3: inconsistent dedentation" <<'EOF'
i = 0
loop i < 2
    i = i + 1
  out(i)
EOF
cerr "a dedent out of a function body to no open block is an error" "p.w:4:5: inconsistent dedentation" <<'EOF'
f(x)
        if x == 5
            return 1
    return 2
out(f(1))
EOF
cerr "a deeper indent at the top level is 'unexpected indent'" "p.w:2:5: unexpected indent" <<'EOF'
x = 1
    y = 2
out(x + y)
EOF
cerr "a deeper indent inside a body is 'unexpected indent'" "p.w:3:9: unexpected indent" <<'EOF'
f()
    x = 1
        y = 2
    return x + y
out(f())
EOF
cerr "a non-ASCII letter in a name is an error" "p.w:1:4: a non-ASCII character is allowed only inside a string, a character literal or a comment" <<'EOF'
café = 1
out(caf)
EOF
cerr "smart quotes are an error, not a name" "p.w:2:5: a non-ASCII character" <<'EOF'
hi = "x"
out(“hi”)
EOF
cerr "a ';' is an error" "p.w:1:6: there is no ';' in word, a newline ends a statement" <<'EOF'
x = 1;
out(x)
EOF
cerr "a '\\' outside a literal is an error" "p.w:1:9: '\\' is not a line continuation" <<'EOF'
x = 1 + \
2
out(x)
EOF
cerr "a stray ASCII character is an error" "p.w:1:1: unexpected character '\$'" <<'EOF'
$x = 1
out(x)
EOF
printf 'x = 1\001\nout(x)\n' > "$tmp/ind.w"
cerr "a control byte is an error" "p.w:1:6: unexpected control character (byte 1)" < "$tmp/ind.w"
printf '\357\273\277out(1)\n' > "$tmp/ind.w"
cerr "a byte order mark is an error that says what it is" "p.w:1:1: this file starts with a UTF-8 byte order mark" < "$tmp/ind.w"
crun "non-ASCII inside literals and comments is fine" "$(printf 'café\n233')" <<'EOF'
out("café") // café
out('é')
EOF

echo "== commands: run =="
crun  "run: prints output"          "42" <<'EOF'
out(42)
EOF
cexit "run: top-level 'return n' sets exit status (n & 255)" 7 <<'EOF'
return 7
EOF
cexit "run: 'return 300' is masked to 44" 44 <<'EOF'
return 300
EOF
# The status is `n & 255` of a whole number (SPEC 8.1). Anything else used to
# exit with the low byte of its representation: text 8, true 11, and a float's
# status differed between x86-64 and arm64. A kind the compiler can see is a
# compile error, and one it cannot faults the way `n & 255` does.
cerr  "run: a top-level return of text is an error" "p.w:1:8: a top-level 'return' sets the exit status, so it needs a whole number, but got a region" <<'EOF'
return "x"
EOF
cerr  "run: a top-level return of true is an error" "p.w:1:8: a top-level 'return' sets the exit status, so it needs a whole number, but got a true/false/null/none value" <<'EOF'
return true
EOF
cerr  "run: a top-level return of a float is an error" "p.w:1:8: a top-level 'return' sets the exit status, so it needs a whole number, but got a float" <<'EOF'
return 3.0
EOF
cerr  "run: a top-level return of a map is an error" "p.w:1:8: a top-level 'return' sets the exit status, so it needs a whole number, but got a map" <<'EOF'
return {a: 1}
EOF
cdie  "run: a top-level return of a float it cannot see faults" "p.w:1: operator needs whole numbers" 70 <<'EOF'
return number("2.5")
EOF
cdie  "run: a top-level return of text from a call faults" "p.w:3: number expected, got a region" 70 <<'EOF'
f(a)
    return a
return f("x")
EOF
cexit "run: a negative top-level return is masked to 255" 255 <<'EOF'
return 0 - 1
EOF
cli   "run: no source arg -> usage, exit 1" "usage: word run" 1 run
# run takes the same target flags as build, and one that does not name this
# host is refused in words. An unknown flag was read as the source ("cannot
# read -x"), and -arm64 was not a flag at all, even on an arm64 host (that half
# is in test_selfhost_a64.sh, which has an arm64 word to ask).
printf 'out("ran")\n' > "$tmp/rf.w"
cli   "run: an unknown flag is a usage error" "word run: unknown flag -x" 1 run -x "$tmp/rf.w"
if [ "$win" = 1 ]; then
  cli "run: -linux on Windows is refused, not built" "-linux builds for linux x86-64, and this host is windows x86-64" 1 run -linux "$tmp/rf.w"
  cli "run: -win names this host" "ran" 0 run -win "$tmp/rf.w"
  cli "run: -arm64 on an x86-64 host is refused, not read as a file" "-arm64 builds for linux arm64" 1 run -arm64 "$tmp/rf.w"
elif [ "$(uname -m)" = x86_64 ]; then
  cli "run: -win on Linux is refused, not built" "-win builds for windows x86-64, and this host is linux x86-64" 1 run -win "$tmp/rf.w"
  cli "run: -linux names this host" "ran" 0 run -linux "$tmp/rf.w"
  cli "run: -arm64 on an x86-64 host is refused, not read as a file" "-arm64 builds for linux arm64" 1 run -arm64 "$tmp/rf.w"
fi
cli   "run: a flag after the source is the program's" "ran" 0 run "$tmp/rf.w" -x

# A stale toolchain fails on the first program that uses newer syntax, and the
# parse error points at your file instead of the compiler. `word version`
# rebuilds for the host target and compares, so you can tell, and it has to be
# right about a binary that's in step as well as one that isn't.
vout=$("$WORD" version 2>&1); vrc=$?
case "$vout" in
  *"in step"*"yes"*) [ "$vrc" = 0 ] && ok "version: reports in step, exit 0" \
      || bad "version in step" "exit $vrc, want 0" ;;
  *) bad "version: reports in step" "got [$vout]" ;;
esac
case "$vout" in
  *"host target"*linux*) ok "version: names the host target it builds for" ;;
  *) bad "version: names the host target" "got [$vout]" ;;
esac
case "$vout" in
  *"this binary"*fingerprint*) ok "version: fingerprints the running binary" ;;
  *) bad "version: fingerprints the binary" "got [$vout]" ;;
esac
# Out of step: an edit to a copy of the source that changes the generated code
# is enough. A comment-only edit isn't stale, because "in step" means
# "rebuilding reproduces this binary", not "the text is identical".
vdir="$tmp/vstale"; mkdir -p "$vdir/compiler"
sed 's/err("cannot read " . src_path)/err("cannot open " . src_path)/' "$root/compiler/word.w" > "$vdir/compiler/word.w"
# The step check compiles that source. Compiling the compiler takes the net
# library from word.w's own NETLIB region (netlib_embed), so the one-file copy
# already carries it and nothing needs to sit beside it.
sout=$(cd "$vdir" && $TO "$WORD" version 2>&1); src2=$?
case "$sout" in
  *"OUT OF STEP"*) [ "$src2" = 1 ] && ok "version: reports OUT OF STEP, exit 1" \
      || bad "version out of step" "exit $src2, want 1" ;;
  *) bad "version: reports out of step" "got [$sout]" ;;
esac
case "$sout" in
  *"Rebuild:"*bootstrap*) ok "version: says how to fix a stale binary" ;;
  *) bad "version: says how to fix it" "got [$sout]" ;;
esac
# A comment-only change isn't called stale.
cdir="$tmp/vcomment"; mkdir -p "$cdir/compiler"
{ cat "$root/compiler/word.w"; echo ""; echo "// a comment changes no code"; } > "$cdir/compiler/word.w"
cout=$(cd "$cdir" && $TO "$WORD" version 2>&1)
case "$cout" in
  *"in step"*yes*) ok "version: a comment-only edit is not stale" ;;
  *) bad "version: comment-only edit called stale" "got [$cout]" ;;
esac
cli   "version: listed in the usage line" "version" 1 badcommand

# The host is what the binary was built for (sys.os()). It used to be the OS
# environment variable, so a word.exe started without it built ELFs and ran
# them as /tmp/..., and a Linux word with OS=Windows_NT built PEs and wrote
# word-run-N.exe into the current directory.
hd="$tmp/host"; mkdir -p "$hd/t"; printf 'out("ran")\n' > "$hd/hh.w"
if [ "$win" = 1 ]; then
  hv=$(env -u OS "$WORD" version 2>&1 | grep 'host target'); hw=windows
  (cd "$hd" && env -u OS "$WORD" build hh.w >/dev/null 2>&1)
  # ls, not test -e: MSYS answers for hh.exe when asked about hh.
  [ "$(head -c2 "$hd/hh.exe" 2>/dev/null)" = MZ ] && ! ls "$hd" | grep -qx hh; hb=$?
  hr=$(cd "$hd" && env -u OS TEMP="$hd/t" "$WORD" run hh.w 2>&1)
else
  hv=$(env OS=Windows_NT "$WORD" version 2>&1 | grep 'host target'); hw=linux
  (cd "$hd" && env OS=Windows_NT "$WORD" build hh.w >/dev/null 2>&1)
  is_elf "$hd/hh" && [ ! -e "$hd/hh.exe" ]; hb=$?
  hr=$(cd "$hd" && env OS=Windows_NT TMPDIR="$hd/t" "$WORD" run hh.w 2>&1)
fi
case "$hv" in *"host target      $hw"*) ok "version: the host is the binary's, whatever OS says" ;;
  *) bad "version: the host is the binary's" "got [$hv] want $hw" ;; esac
[ "$hb" = 0 ] && ok "build: the default target is the binary's, whatever OS says" \
  || bad "build: the default target is the binary's" "$(ls "$hd")"
if [ "$hr" = ran ] && ! ls "$hd" | grep -q '^word-run-'; then ok "run: runs on this host, whatever OS says"
else bad "run: runs on this host, whatever OS says" "out=[$hr] dir=[$(ls "$hd" | tr '\n' ' ')]"; fi

# version fingerprints the running image. It read argv[0], so a word.exe found
# through PATH, run from a checkout holding another word.exe, judged that other
# file (a false OUT OF STEP), and typed as `word` it read nothing and gave no
# verdict with exit 0. cmd.exe, because it hands argv[0] over as typed.
vp="$tmp/vpath"; mkdir -p "$vp/bin" "$vp/co/compiler"
cp compiler/word.w "$vp/co/compiler/"
if [ "$win" = 1 ]; then
  cp "$WORD" "$vp/bin/word.exe"
  "$WORD" build "$tmp/lt.w" -o "$vp/co/word.exe" >/dev/null 2>&1
  vb=$(cygpath -w "$vp/bin")
  # cmd.exe looks in the current directory before PATH unless
  # NoDefaultCurrentDirectoryInExePath is set, and then it would run the
  # checkout's word.exe instead of the one this test puts on PATH.
  for how in word.exe word; do
    got=$(cd "$vp/co" && cmd //c "set NoDefaultCurrentDirectoryInExePath=1&& set PATH=$vb;%PATH%&& $how version" 2>&1); rc=$?
    case "$got" in *"in step          yes"*) [ "$rc" = 0 ] && ok "version: through PATH as $how, judges itself" \
        || bad "version: through PATH as $how" "exit $rc" ;;
      *) bad "version: through PATH as $how, judges itself" "rc=$rc [$got]" ;; esac
  done
else
  cp "$WORD" "$vp/bin/word"
  "$WORD" build "$tmp/lt.w" -o "$vp/co/word" >/dev/null 2>&1
  got=$(cd "$vp/co" && PATH="$vp/bin:$PATH" word version 2>&1); rc=$?
  case "$got" in *"in step          yes"*) [ "$rc" = 0 ] && ok "version: through PATH, judges itself" \
      || bad "version: through PATH" "exit $rc" ;;
    *) bad "version: through PATH, judges itself" "rc=$rc [$got]" ;; esac
  # A binary it cannot read gets no verdict, and that is not a pass. Needs a
  # user the mode applies to; root reads the file anyway.
  cp "$WORD" "$vp/xo"; chmod 111 "$vp/xo"
  if [ -r "$vp/xo" ]; then ok "version: an unreadable binary (SKIP: this user reads a mode 111 file)"
  else
    got=$(cd "$vp/co" && "$vp/xo" version 2>&1); rc=$?
    case "$got" in *"in step          unknown"*) [ "$rc" = 1 ] && ok "version: a binary that cannot read itself says unknown, exit 1" \
        || bad "version: cannot read itself" "exit $rc" ;;
      *) bad "version: a binary that cannot read itself says unknown" "rc=$rc [$got]" ;; esac
  fi
fi

# A literal's region header must give it no spare capacity: `.quad flags, n, n`,
# with capacity equal to length. The inline append (`s = s . "lit"` where the
# subkind pass proved s word-backed) relies on it. It skips asking whether the
# target is a literal, because a literal fails the capacity test and goes out
# of line to rt_append, which allocates. With spare capacity in a literal, that
# append would write into the read-only pool, for every program at once, so the
# header shape is checked here.
printf 'a = "xy"\na = a . "z"\nout(a)\n' > "$tmp/lith.w"
if "$WORD" build -asm "$tmp/lith.w" > "$tmp/lith.s" 2>/dev/null; then
  bad=$(awk '/^    \.quad [0-9]+, [0-9]+, [0-9]+/ { n=split($0, f, ","); cap=f[2]+0; ln=f[3]+0; if (cap != ln) c++ } END { print c+0 }' "$tmp/lith.s")
  tot=$(grep -c '^    \.quad [0-9]*, [0-9]*, [0-9]*' "$tmp/lith.s")
  if [ "$bad" = 0 ] && [ "$tot" -gt 0 ]; then
    ok "every literal header has capacity == length ($tot literals)"
  else bad "literal capacity" "$bad of $tot literal headers carry spare capacity"; fi
else bad "literal capacity" "build -asm failed"; fi
# The behaviour on top of it: `s = "xy"` leaves s holding the literal, so
# `s = s . "z"` is an in-place append whose target is a literal, and it has to
# come back with a fresh region while the pool entry still reads "xy". The
# header check above matters more, because a write past a literal's length
# corrupts whatever the pool put next, and this comparison wouldn't see it.
printf 's = "xy"\ns = s . "z"\nout(s . " " . "xy")\n' > "$tmp/lita.w"
if "$WORD" build "$tmp/lita.w" -o "$tmp/lita" >/dev/null 2>&1; then
  got=$("$tmp/lita" 2>&1)
  [ "$got" = "xyz xy" ] && ok "an in-place append to a literal target still reads back right" \
                        || bad "literal append" "got [$got] want [xyz xy]"
else bad "literal append" "build failed"; fi

# A `loop <cond>` whose body can't change the condition and can't leave the
# loop runs forever. That's the forgotten `i = i + 1`, and it fails as a hang,
# with no output, no diagnostic and no location. The compiler can prove it
# because word has no references (a callee can't reach a caller's local), so
# these must be rejected. The ones after them must not be, or the check would
# be worse than the bug.
cerr "loop that never changes its counter is rejected" "cannot end" <<'EOF'
i = 0
loop i < 10
    out(i)
EOF
cerr "a break in a NESTED loop does not save the outer one" "cannot end" <<'EOF'
i = 0
loop i < 10
    loop true
        break
EOF
cbuild "the counter is incremented: fine" <<'EOF'
i = 0
loop i < 10
    i = i + 1
EOF
cbuild "incremented inside an if: fine" <<'EOF'
i = 0
loop i < 10
    if i >= 0
        i = i + 1
EOF
cbuild "loop true is the forever-loop: fine" <<'EOF'
loop true
    break
EOF
cbuild "break ends it: fine" <<'EOF'
i = 0
loop i < 10
    break
EOF
cbuild "return ends it: fine" <<'EOF'
f()
    i = 0
    loop i < 10
        return 7
out(f())
EOF
cbuild "a condition that calls something is left alone" <<'EOF'
more(n)
    return 0
loop more(1)
    out(1)
EOF
cbuild "an index target a[0] = ... counts as changing a" <<'EOF'
a = text(3)
loop a[0] < 5
    a[0] = a[0] + 1
EOF
cbuild "an assignment inside a nested loop counts" <<'EOF'
i = 0
loop i < 10
    loop true
        i = i + 1
        break
EOF

# out() stages into a 64 KB buffer instead of making one write syscall per code
# point. The output is the same either way, and a timing would pass on a fast
# machine, so the check counts the syscalls.
if [ "$win" = 1 ]; then
  # Git for Windows has an strace, but it traces Cygwin calls, not WriteFile.
  ok "out() write batching (SKIP: strace counts Linux syscalls, and this is Windows)"
elif command -v strace >/dev/null 2>&1; then
  printf 's = "x"\ni = 0\nloop i < 14\n    s = s . s\n    i = i + 1\nout(s)\n' > "$p"
  if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
    n=$(strace -c -e trace=write "$exe" 2>&1 >/dev/null | awk '/write/ {print $(NF-1)}' | head -1)
    # 16384 code points: fewer than 100 writes, not one per character.
    if [ -n "$n" ] && [ "$n" -lt 100 ] 2>/dev/null; then
      ok "out() batches its writes ($n syscalls for 16384 characters)"
    else bad "out() write batching" "$n syscalls for 16384 characters: back to one per code point?"; fi
  fi
else
  ok "out() write batching (SKIP: no strace)"
fi

# `word run` builds a temporary binary and execve's it. That path used to be a
# fixed "/tmp/word-run.bin", one file shared by every user of the machine and by
# every concurrent run, so two runs raced, and on a protected_regular kernel a
# second user couldn't write the first one's file at all (CI failed that way).
# It must honour $TMPDIR, and two runs must not pick the same name.
rd="$tmp/rundir"; mkdir -p "$rd"
printf 'out("ran")\n' > "$tmp/r.w"
rm -f /tmp/word-run.bin
tv=TMPDIR; [ "$win" = 1 ] && tv=TEMP      # on Windows it is %TEMP%, then %TMP%
got=$(env "$tv=$rd" $TO "$WORD" run "$tmp/r.w" 2>&1)
env "$tv=$rd" $TO "$WORD" run "$tmp/r.w" >/dev/null 2>&1
n=$(ls "$rd" | wc -l)
if [ "$got" = ran ] && [ "$n" = 2 ]; then ok "run: builds under \$$tv, a fresh name each time"
else bad "run: builds under \$$tv, a fresh name each time" "out=[$got] files=$n want [ran] 2"; fi
if [ -e /tmp/word-run.bin ]; then bad "run: no fixed shared path in /tmp" "/tmp/word-run.bin exists"
else ok "run: writes no fixed shared path in /tmp"; fi

# in() strips a trailing CR, so a Windows CRLF line ("7\r\n") reads as the number 7,
# not the text "7\r". Without the strip, the kind test fails and the program prints -1.
# Runs on Linux (feeding CRLF straight to stdin); guards the fix that made Windows
# console input work.
printf 'x = in()\nif kind(x) == "number"\n    out(x)\nif kind(x) != "number"\n    out(0 - 1)\n' > "$p"
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$(printf '7\r\n' | $TO "$exe" 2>&1)
  if [ "$got" = "7" ]; then ok "input: a CRLF line reads as a clean value (in() strips the CR)"
  else bad "input: CRLF line" "got [$got], want 7 (CR not stripped?)"; fi
else bad "input: CRLF line" "build failed"; fi

# bytes(n): a byte-backed region a program can build, 1 byte per element
# instead of 8, the same subkind fs.read returns. It must behave like any other
# region (len, index, store, join, ==, slice) and start zeroed.
crun  "bytes: len, zero-init, store, index"   "5|0|0|65|255|0" <<'EOF'
b = bytes(5)
z = b[0]
out(len(b) . "|" . z . "|" . b[3] . "|" . 65 . "|" . 255 . "|" . b[1])
EOF
crun  "bytes: stores read back at both ends"  "65|255|0" <<'EOF'
b = bytes(5)
b[0] = 65
b[4] = 255
out(b[0] . "|" . b[4] . "|" . b[2])
EOF
crun  "bytes: join, ==, slice interop"        "65000255|true|2" <<'EOF'
b = bytes(5)
b[0] = 65
b[4] = 255
s = ""
i = 0
loop i < len(b)
    s = s . b[i]
    i = i + 1
out(s . "|" . (b == b) . "|" . len(copy(b, 0, 2)))
EOF
cdie  "bytes: negative length is a bounds fault" "index out of bounds" 70 <<'EOF'
b = bytes(0 - 1)
out(len(b))
EOF

# The assembler's section buffers grow on demand instead of having a fixed
# capacity. This program's literals push .rodata far past the initial buffer
# size, which used to be a hard ceiling that could only be raised by hand. It
# has to build and run.
python3 - "$p" <<'PYGEN' 2>/dev/null || awk 'BEGIN{for(i=0;i<4000;i++)printf "out(\"literal-padding-string-%08d\")\n", i}' > "$p"
import sys
with open(sys.argv[1],"w") as f:
    for i in range(4000):
        f.write('out("literal-padding-string-%08d")\n' % i)
PYGEN
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1 && [ "$($TO "$exe" | wc -l)" = "4000" ]; then
  ok "buffers: .rodata grows past the initial capacity (no fixed ceiling)"
else
  bad "buffers: .rodata growth" "a literal-heavy program failed to build or run"
fi

# Branch fusion: an `if` or `loop` condition that is a comparison branches on the
# flags, with the region and float path emitted out of line past the function's
# ret. Every operator must still give the right answer in both statement forms,
# and a comparison of mixed kinds found at run time must still fault instead of
# taking a branch.
crun  "conditions: all six operators in if"  "TFTFTFTFTFTF" <<'EOF'
r = ""
b(c)
    if c
        return "T"
    return "F"
r = b(3 < 5) . b(5 < 3) . b(3 <= 3) . b(4 <= 3) . b(5 > 3) . b(3 > 5)
r = r . b(3 >= 3) . b(2 >= 3) . b(3 == 3) . b(3 == 4) . b(3 != 4) . b(3 != 3)
out(r)
EOF
crun  "conditions: regions and floats"       "TFTF" <<'EOF'
b(c)
    if c
        return "T"
    return "F"
out(b("abc" < "abd") . b("abd" < "abc") . b(1.5 < 2.5) . b(2.5 < 1.5))
EOF
crun  "conditions: loop forms terminate"     "5|5|4|2" <<'EOF'
i = 0
n = 0
loop i < 5
    n = n + 1
    i = i + 1
j = 10
m = 0
loop j > 5
    m = m + 1
    j = j - 1
k = 0
c = 0
loop k <= 3
    c = c + 1
    k = k + 1
w = "aaa"
z = 0
loop w != "aaaaa"
    w = w . "a"
    z = z + 1
out(n . "|" . m . "|" . c . "|" . z)
EOF
cdie  "conditions: mixed kinds still fault"  "cannot order-compare" 70 <<'EOF'
pick(t)
    if t == 0
        return 1
    return "x"
a = pick(0)
b = pick(1)
if a < b
    out("no")
EOF

echo "== loop x in y: for-each over a region (SPEC 7.2) =="
# elements of an array, in order, summed
crun  "for-each sums an array"        "18" <<'EOF'
xs = text(3)
xs[0] = 5
xs[1] = 6
xs[2] = 7
s = 0
loop v in xs
    s = s + v
out(s)
EOF
# a string yields code points (text is code points, SPEC 3.4)
crun  "for-each over text -> code points" "65
66
67" <<'EOF'
loop c in "ABC"
    out(c)
EOF
# the subject is evaluated once, even when it is a call
crun  "subject evaluated once (a call)" "104
105" <<'EOF'
f()
    return "hi"
loop c in f()
    out(c)
EOF
# break works, since it's still a loop
crun  "break inside for-each"          "97
98" <<'EOF'
loop c in "abcdef"
    if c == 99
        break
    out(c)
EOF
# nesting, with independent hidden state per loop
crun  "nested for-each"                "x1
x2
y1
y2" <<'EOF'
a = array(2)
a[0] = "x"
a[1] = "y"
b = array(2)
b[0] = 1
b[1] = 2
loop w in a
    loop n in b
        out(w . n)
EOF
# a map iterates through keys(m); the value comes from o[k]
crun  "for-each over keys(map)"        "a=1
b=2" <<'EOF'
m = {a: 1, b: 2}
loop k in keys(m)
    out(k . "=" . m[k])
EOF
# a byte-backed region (bytes/fs.read) yields each byte as an int
crun  "for-each over a byte buffer"    "65
66" <<'EOF'
b = bytes(2)
b[0] = 65
b[1] = 66
loop x in b
    out(x)
EOF
# the loop variable is a fresh copy: assigning it does not write back
crun  "loop var is a local copy"       "101
1" <<'EOF'
xs = text(2)
xs[0] = 1
xs[1] = 2
loop v in xs
    v = v + 100
    if v == 101
        out(v)
out(xs[0])
EOF
# empty region: the body never runs
crun  "for-each over an empty region"  "done" <<'EOF'
n = 0
loop v in text(0)
    n = n + 1
out("done")
EOF
# The binding is out of scope after the loop, so the name can be a new local
# there (SPEC 7.2). That local doesn't lend the binding its kind: each of
# these failed to build with a kind error about the binding.
crun  "a later k = 0 doesn't make the binding a number" "1
0" <<'EOF'
m = {ab: 1}
loop k in keys(m)
    out(m[k])
k = 0
out(k)
EOF
crun  "a later ch = text doesn't make the binding text" "121
122
q!" <<'EOF'
s = "xy"
loop ch in s
    out(ch + 1)
ch = "q"
out(ch . "!")
EOF
crun  "a later r = 7 doesn't make the binding a number" "ab|2
c|1
7" <<'EOF'
rows = array(2)
rows[0] = "ab"
rows[1] = "c"
loop r in rows
    out(r . "|" . len(r))
r = 7
out(r)
EOF
# an ordinary `loop cond` still parses (in() as a condition is unaffected)
crun  "plain loop condition still works" "3" <<'EOF'
i = 0
loop i < 3
    i = i + 1
out(i)
EOF

echo "== loop x in y: misuse is a clean error, never a crash =="
# a number subject known at compile time is rejected there
cerr  "iterate a number literal"       "needs a region to iterate" <<'EOF'
loop v in 5
    out(v)
EOF
# a map literal subject is rejected with the keys() hint
cerr  "iterate a map literal"          "cannot iterate a map directly" <<'EOF'
loop v in {a: 1}
    out(v)
EOF
# a non-region only known at run time (a parameter) faults, not segfaults
cdie  "iterate a non-region param faults" "region expected" 70 <<'EOF'
f(y)
    loop v in y
        out(v)
f(5)
EOF
# the loop variable must be a new name, so a bound one is refused (SPEC 7.2)
cerr  "loop var cannot shadow"         "already defined in this scope" <<'EOF'
v = 1
loop v in "ab"
    out(v)
EOF
# the loop variable is out of scope after the loop
cerr  "loop var is out of scope after" "undefined variable 'c'" <<'EOF'
loop c in "ab"
    out(c)
out(c)
EOF

echo "== commands: asm =="
printf '.intel_syntax noprefix\n.global _start\n.text\n_start:\n    mov rax, 60\n    mov rdi, 5\n    syscall\n' > "$tmp/min.s"
if "$WORD" asm -linux "$tmp/min.s" "$tmp/min.elf" >/dev/null 2>&1; then
  if [ "$win" = 1 ]; then
    is_elf "$tmp/min.elf" && ok "asm: assembles+links a hand-written .s$elfnote" || bad "asm: hand-written .s" "not an ELF"
  else
  $TO "$tmp/min.elf"; rc=$?
  [ "$rc" = 5 ] && ok "asm: assembles+links a hand-written .s (exit 5)" || bad "asm: hand-written .s" "produced binary exit=$rc want 5"
  fi
else bad "asm: hand-written .s" "word asm errored"; fi
cli   "asm: no args -> usage, exit 1" "usage: word asm" 1 asm

# A hand-written line that stops short of its operands, or names a register the
# target does not have, is refused with the line's own text and no output. A
# missing operand used to fault inside the assembler (exit 70), or on x86-64
# reuse the operand of an earlier line, and arm64 ORed a non-register's
# -1 into the instruction word (`mov rax, 60` became 0xffffffff).
asmrefuse() { # name, "" or -arm64, instruction line(s) for printf, expected text
  if [ "$2" = -arm64 ]; then printf ".text\n.global _start\n_start:\n$3\n" > "$tmp/bad.s"
  else printf ".intel_syntax noprefix\n.global _start\n.text\n_start:\n$3\n" > "$tmp/bad.s"; fi
  rm -f "$tmp/bad.out"
  "$WORD" asm $2 "$tmp/bad.s" "$tmp/bad.out" > "$tmp/asm.err" 2>&1; rc=$?
  if [ "$rc" = 1 ] && grep -qF "$4" "$tmp/asm.err" && [ ! -f "$tmp/bad.out" ]; then ok "asm refuses: $1"
  else bad "asm refuses: $1" "rc=$rc [$(head -c 200 "$tmp/asm.err")]"; fi; }
asmrefuse "x86 mov with one operand"  ""  "    mov rax"           "missing operand: mov rax"
asmrefuse "x86 add with one operand"  ""  "    add rax"           "missing operand: add rax"
asmrefuse "x86 jmp with no target"    ""  "    jmp"               "missing operand: jmp"
asmrefuse "x86 lea with one operand"  ""  "    lea rax"           "missing operand: lea rax"
asmrefuse "x86 shl with one operand"  ""  "    shl rax"           "missing operand: shl rax"
asmrefuse "x86 pshufd with two"       ""  "    pshufd xmm0, xmm1" "missing operand: pshufd"
asmrefuse "x86 short line after a full one" "" "    mov rdi, 7\n    mov rax" "missing operand: mov rax"
asmrefuse "a64 mov with one operand"  -arm64 "    mov x0"              "a64 missing operand: mov x0"
asmrefuse "a64 movz with one operand" -arm64 "    movz x0"             "a64 missing operand: movz x0"
asmrefuse "a64 add with one operand"  -arm64 "    add x0"              "a64 missing operand: add x0"
asmrefuse "a64 ldr with one operand"  -arm64 "    ldr x0"              "a64 missing operand: ldr x0"
asmrefuse "a64 b with no target"      -arm64 "    b"                   "a64 missing operand: b"
asmrefuse "a64 madd with three"       -arm64 "    madd x0, x1, x2"     "a64 missing operand: madd"
asmrefuse "a64 x86 register in mov"   -arm64 "    mov rax, 60"         "a64 not a register: rax"
asmrefuse "a64 x86 register in add"   -arm64 "    add x0, x1, rax"     "a64 not a register: rax"
asmrefuse "a64 x86 register in ldr"   -arm64 "    ldr rax, [x1]"       "a64 not a register: rax"
asmrefuse "a64 x register in fadd"    -arm64 "    fadd d0, d1, x2"     "a64 not a d register: x2"
asmrefuse "a64 x86 register in ret"   -arm64 "    ret rax"             "a64 not a register: rax"

# x86-64: a form the encoder has no encoding for is refused, never assembled as
# the nearest one it has. Every line here used to exit 0 with some other
# instruction in the output: a scale of 3 became 1, a displacement or an
# immediate past its field was truncated, a 32-bit register became its 64-bit
# name, an operand of the wrong kind was read as a register number, an extra
# operand was dropped, and `0 - 1` was read as 0.
asmrefuse "x86 a scale of 3"            "" "    mov rax, [rbx+rcx*3]"       "the scale is 1, 2, 4 or 8"
asmrefuse "x86 a 32-bit address"        "" "    mov rax, [eax]"             "registers are 64-bit"
asmrefuse "x86 a label without rip"     "" "    mov rax, [rbx+data]"        "needs rip"
asmrefuse "x86 a displacement past 32 bits" "" "    mov rax, [rbx+0x100000000]" "the displacement does not fit"
asmrefuse "x86 register sizes differ"   "" "    mov eax, rbx"               "operand sizes differ: mov eax, rbx"
asmrefuse "x86 a memory size differs"   "" "    mov eax, qword ptr [rbx]"   "operand sizes differ"
asmrefuse "x86 a mask past a signed imm32" "" "    and rax, 0x80000000"    "the immediate does not fit"
asmrefuse "x86 an imm8 past 255"        "" "    mov al, 300"                "the immediate does not fit"
asmrefuse "x86 a word ptr imm past 16 bits" "" "    sub word ptr [rbx], 70000" "the immediate does not fit"
asmrefuse "x86 a shift count of 256"    "" "    shl rax, 256"               "the immediate does not fit"
asmrefuse "x86 a shift count in rcx"    "" "    shl rax, rcx"               "a shift count is cl or a number"
asmrefuse "x86 add with three operands" "" "    add rax, rbx, rcx"          "too many operands"
asmrefuse "x86 syscall with an operand" "" "    syscall rax"                "too many operands"
asmrefuse "x86 a store with no size"    "" "    mov [rax], 5"               "the operand size is ambiguous"
asmrefuse "x86 lea from a register"     "" "    lea rax, rbx"               "unsupported operand form"
asmrefuse "x86 push a 32-bit register"  "" "    push eax"                   "unsupported operand form"
asmrefuse "x86 movzx from 64 bits"      "" "    movzx rax, rbx"             "unsupported operand form"
asmrefuse "x86 sete into 32 bits"       "" "    sete eax"                   "unsupported operand form"
asmrefuse "x86 addsd from a gpr"        "" "    addsd xmm0, rax"            "unsupported operand form"
asmrefuse "x86 movq between gprs"       "" "    movq rax, rbx"              "unsupported operand form"
asmrefuse "x86 call a number"           "" "    call 5"                     "unsupported operand form"
asmrefuse "x86 an expression"           "" "    mov rax, 0 - 1"             "not a number"
asmrefuse "x86 a number past 64 bits"   "" "    mov rax, 0x1ffffffffffffffff" "does not fit in 64 bits"
asmrefuse "x86 rep on a mov"            "" "    rep mov rax, 1"             "rep takes movsb, stosb, movsq or stosq"
asmrefuse "a byte past 255"             "" "    .byte 300"                  "the value does not fit"
asmrefuse "a label as data"             "" "    .quad data"                 "a data value is a number"
asmrefuse "two strings in one .ascii"   "" '    .ascii "a", "b"'            "one quoted string"
asmrefuse "a section it does not lay out" "" "    .section .text.hot"       "the sections are"
asmrefuse "an alignment of 3"           "" "    .align 3"                   "power of two"
asmrefuse "a .space fill value"         "" "    .space 8, 1"                ".space takes one size"
asmrefuse "data in .bss"                "" "    .section .bss\n    .byte 1" ".bss holds only"
asmrefuse "an unknown directive"        "" "    .bogus 1"                   "unhandled directive"

# A decimal immediate of 2^62 or more used to fault inside the assembler
# (integer overflow, exit 70). 2^63-1 shifted right 60 exits 7.
printf '.intel_syntax noprefix\n.global _start\n.text\n_start:\n    mov rdi, 9223372036854775807\n    shr rdi, 60\n    mov rax, 60\n    syscall\n' > "$tmp/big.s"
rm -f "$tmp/big.out"
"$WORD" asm -linux "$tmp/big.s" "$tmp/big.out" > "$tmp/asm.err" 2>&1; rc=$?
brc=7; [ "$win" = 1 ] || { [ -f "$tmp/big.out" ] && "$tmp/big.out"; brc=$?; }
if [ "$rc" = 0 ] && [ -f "$tmp/big.out" ] && [ "$brc" = 7 ]; then ok "asm: a decimal immediate past 2^62 assembles"
else bad "asm: a decimal immediate past 2^62" "rc=$rc run=$brc [$(head -c 200 "$tmp/asm.err")]"; fi

# The label table grows. It was a fixed 65,536 slots, and the label after that
# spun forever looking for a free one. -linux because a hand-written x86 .s
# with a raw syscall is a Linux program on every host.
awk 'BEGIN{print ".intel_syntax noprefix\n.global _start\n.text\n_start:"; for(i=0;i<70000;i++) printf "L%d:\n    nop\n", i; print "    mov rax, 60\n    mov rdi, 7\n    syscall"}' > "$tmp/many.s"
rm -f "$tmp/many.out"
$TO "$WORD" asm -linux "$tmp/many.s" "$tmp/many.out" > "$tmp/asm.err" 2>&1; rc=$?
mrc=7; [ "$win" = 1 ] || { [ -f "$tmp/many.out" ] && "$tmp/many.out"; mrc=$?; }
if [ "$rc" = 0 ] && [ -f "$tmp/many.out" ] && [ "$mrc" = 7 ]; then ok "asm: 70,001 labels assemble, past the old fixed table"
else bad "asm: 70,001 labels" "rc=$rc run=$mrc [$(head -c 200 "$tmp/asm.err")]"; fi

echo "== commands: verify / bootstrap =="
cli   "verify: rebuilds byte-identically" "byte-identical to the committed binary" 0 verify
wb="$tmp/wb"
if "$WORD" bootstrap -o "$wb" >/dev/null 2>&1 && cmp -s "$wb" "$WORD"; then
  ok "bootstrap: reproduces the committed binary"
else bad "bootstrap" "did not reproduce the committed binary byte-for-byte"; fi
# Without -o, bootstrap writes ./word, which is usually the binary running it,
# and no OS lets that be replaced while it runs. The failure says to use -o,
# and the binary is left as it was. Done in a copy, never in the checkout.
# On Windows bootstrap writes word.exe, so there the copy has to have that name.
bsn=word; [ "$win" = 1 ] && bsn=word.exe
mkdir -p "$tmp/bs/compiler"; cp compiler/word.w "$tmp/bs/compiler/"; cp "$WORD" "$tmp/bs/$bsn"
got=$(cd "$tmp/bs" && "./$bsn" bootstrap 2>&1); rc=$?
if [ "$rc" = 1 ] && printf '%s' "$got" | grep -q 'cannot be replaced while it runs: build with -o' && cmp -s "$tmp/bs/$bsn" "$WORD"; then
  ok "bootstrap: over the running binary, says to use -o and leaves it alone"
else bad "bootstrap over the running binary" "rc=$rc [$got]"; fi
# bootstrap's flags go anywhere too, and one it does not know is a usage error.
# It used to skip an unknown flag along with the -o after it, and write the
# host binary to ./word (word.exe) instead.
got=$(cd "$tmp/bs" && "./$bsn" bootstrap -x -o bsx 2>&1); rc=$?
if [ "$rc" = 1 ] && printf '%s' "$got" | grep -q 'word bootstrap: unknown flag -x' \
   && ! ls "$tmp/bs" | grep -q '^bsx' && cmp -s "$tmp/bs/$bsn" "$WORD"; then
  ok "bootstrap: an unknown flag is a usage error, and nothing is written"
else bad "bootstrap: an unknown flag" "rc=$rc [$got]"; fi
got=$(cd "$tmp/bs" && "./$bsn" bootstrap extra 2>&1); rc=$?
if [ "$rc" = 1 ] && printf '%s' "$got" | grep -q 'takes no file, but got extra'; then
  ok "bootstrap: a stray word is a usage error"
else bad "bootstrap: a stray word" "rc=$rc [$got]"; fi
if (cd "$tmp/bs" && "./$bsn" bootstrap -o bsa -arm64 >/dev/null 2>&1) \
   && [ "$(od -An -tu1 -j18 -N1 "$tmp/bs/bsa" | tr -d ' \n')" = 183 ]; then
  ok "bootstrap: a target flag after -o is honoured (-arm64)"
else bad "bootstrap: a target flag after -o" "no arm64 ELF at bsa"; fi

echo "== commands: dispatch =="
cli   "no command -> usage, exit 1"        "usage: word" 1
cli   "unknown command -> reported, exit 1" "unknown command 'frobnicate'" 1 frobnicate

echo "== contracts: success =="
crun  ":before passes, function runs"        "5" <<'EOF'
divide(a, b)
    return a / b

divide:before
    if b == 0
        return false
    return true

out(divide(20, 4))
EOF
crun  ":after passes, original value returned" "10" <<'EOF'
inc(x)
    return x + 1

inc:after
    if result <= 0
        return false
    return true

out(inc(9))
EOF
crun  ":after binds 'result'"                "25" <<'EOF'
sq(x)
    return x * x

sq:after
    if result > 1000
        return false
    return true

out(sq(5))
EOF
crun  "shared hook guards several functions"  "10
5" <<'EOF'
deposit(amount)
    return amount

withdraw(amount)
    return amount

deposit:before, withdraw:before
    if amount <= 0
        return false
    return true

out(deposit(10))
out(withdraw(5))
EOF
crun  "hooks fire on recursive calls"         "0" <<'EOF'
countdown(n)
    if n <= 0
        return 0
    return countdown(n - 1)

countdown:before
    if n < 0
        return false
    return true

out(countdown(5))
EOF
crun  "a hook's own calls bypass hooks (no infinite recursion)" "1" <<'EOF'
f(x)
    return x

f:before
    if f(1) == 1
        return true
    return false

out(f(1))
EOF

echo "== contracts: failure (must die naming the function, exit 70) =="
cdie  ":before fails -> contract violation in <fn>" "contract violation in divide" 70 <<'EOF'
divide(a, b)
    return a / b

divide:before
    if b == 0
        return false
    return true

out(divide(1, 0))
EOF
cdie  ":before fail names the function, not the hook" "contract violation in check" 70 <<'EOF'
check(x)
    return x

check:before
    if x <= 0
        return false
    return true

out(check(0 - 3))
EOF
cdie  ":after fails -> program dies"          "contract violation in must_be_positive" 70 <<'EOF'
must_be_positive(x)
    return x

must_be_positive:after
    if result <= 0
        return false
    return true

out(must_be_positive(0 - 1))
EOF
cdie  "shared hook fails for the failing target" "contract violation in withdraw" 70 <<'EOF'
deposit(amount)
    return amount

withdraw(amount)
    return amount

deposit:before, withdraw:before
    if amount <= 0
        return false
    return true

out(withdraw(0 - 5))
EOF

echo "== contracts: a hook answers true or false (SPEC 3.2) =="
# A hook's answer is a condition, like every other yes-or-no in the language.
# The check used to compare the answer with the integer 0 alone (truth as it
# was spelled before #204), so `return false` passed, and so did null and none.
# Every guard written the way SPEC shows one was dead code, the ones in
# examples/calc and examples/rpg among them, and every case above answered 0 or
# 1, so none of them could see it. A violation is reported at the hook's answer.
cdie  "return false fails the contract"        "p.w:5: contract violation in f" 70 <<'EOF'
f(a)
    return a

f:before
    return false

out(f(1))
EOF
cdie  "so does a computed false"               "p.w:5: contract violation in f" 70 <<'EOF'
f(a)
    return a

f:before
    return a == 2

out(f(1))
EOF
cdie  ":after, a false answer about result"    "p.w:5: contract violation in f" 70 <<'EOF'
f(a)
    return a

f:after
    return result == 2

out(f(1))
EOF
cdie  "a false that arrives at run time"       "p.w:5: contract violation in f" 70 <<'EOF'
f(a)
    return 7

f:before
    return a

out(f(false))
EOF
cdie  "an answer through a call names the guard's line" "p.w:8: contract violation in f" 70 <<'EOF'
check(v)
    return v

f(a)
    return 7

f:before
    return check(a)

out(f(false))
EOF
crun  "return true passes, and so does reaching the end" "1
2" <<'EOF'
f(a)
    return a

f:before
    return true

g(a)
    return a

g:before
    if a == 9
        return false

out(f(1))
out(g(2))
EOF
cdie  "a number that arrives at run time is not an answer" "p.w:5: a condition must be true or false" 70 <<'EOF'
f(a)
    return 7

f:before
    return a

out(f(0))
EOF
cdie  "and neither is none"                    "p.w:5: a condition must be true or false" 70 <<'EOF'
f(a)
    return 7

f:before
    return a

out(f(none))
EOF
cerr  "return 0 is refused where it is written" "a contract hook answers true or false, not a number: 'return false' fails the contract" <<'EOF'
f(a)
    return a

f:before
    return 0

out(f(1))
EOF
cerr  "and so is return 1"                     "a contract hook answers true or false, not a number: 'return false' fails the contract, and 'return true' passes it" <<'EOF'
f(a)
    return a

f:before
    return 1

out(f(1))
EOF
cerr  "text is not an answer either"           "a contract hook answers true or false, not text" <<'EOF'
f(a)
    return a

f:after
    return "yes"

out(f(1))
EOF
# A map literal carried no position into a diagnostic, so this was p.w:0:0.
cerr  "nor is a map, which is not a float"     "p.w:5:12: a contract hook answers true or false, not a map" <<'EOF'
f(a)
    return a

f:before
    return {a: 1}

out(f(1))
EOF

# A condition the analyzer can see is not true or false is a compile error that
# says what it is (SPEC 3.2). A map used to be called a float, an array or
# bytes(n) was called text, and `if find(s, c)` compiled and only faulted when
# it ran, where SPEC 9 says it is rejected outright.
cerr  "a map is not a condition"               "a condition must be true or false, not a map; test it, as in 'has(x, k)' or 'len(x) != 0'" <<'EOF'
m = {a: 1}
if m
    out("yes")
EOF
cerr  "nor is it under !"                      "a condition must be true or false, not a map" <<'EOF'
m = {a: 1}
out(!m)
EOF
cerr  "an array is a region, not text"         "a condition must be true or false, not a region; test it, as in 'len(x) != 0'" <<'EOF'
a = array(2)
if a
    out("yes")
EOF
cerr  "and so is bytes(n)"                     "a condition must be true or false, not a region" <<'EOF'
out(true && bytes(3))
EOF
cerr  "text is still called text"              "a condition must be true or false, not text; test it" <<'EOF'
s = "abc"
if s
    out("yes")
EOF
cerr  "if find(s, c) is rejected outright"     "a condition must be true or false, and find() answers a number or none; compare it, as in 'find(s, c) != none'" <<'EOF'
if find("abc", "a")
    out("yes")
EOF
cerr  "and so is !find(s, c)"                  "and find() answers a number or none" <<'EOF'
out(!find("abc", "z"))
EOF
crun  "a program's own find is its own"        "mine" <<'EOF'
find(a, b)
    return true
if find(1, 2)
    out("mine")
EOF

echo "== diagnostics: parser errors are located, not internal faults =="
cerr  "bare number at top level"          "expected a definition or statement" <<'EOF'
5
EOF
cerr  "assignment to a number"            "expected a definition or statement" <<'EOF'
5 = 3
EOF
cerr  "calling a number"                  "expected a definition or statement" <<'EOF'
5()
EOF
cerr  "numeric hook target"               "expected a definition or statement" <<'EOF'
5:after
    return 1
EOF
cerr  "an 'if' with no indented body"     "p.w:1:1: expected an indented block after this 'if'" <<'EOF'
if 1
out(2)
EOF
# A header with nothing under it is reported at the header, and a bracket still
# open at the end of the file at the bracket. Both were "unexpected token here"
# at the next line, blaming a line that was fine, or at a line past the end.
cerr  "an 'if' at the end of the file"     "p.w:2:1: expected an indented block after this 'if'" <<'EOF'
x = 1
if x == 1
EOF
cerr  "an 'if' followed only by a comment" "p.w:2:1: expected an indented block after this 'if'" <<'EOF'
x = 1
if x == 1
// only a comment

EOF
cerr  "an 'else' with no body"             "p.w:4:1: expected an indented block after this 'else'" <<'EOF'
x = 1
if x == 1
    out(1)
else
EOF
cerr  "an 'else if' with no body"          "p.w:4:6: expected an indented block after this 'if'" <<'EOF'
x = 1
if x == 1
    out(1)
else if x == 2
out(3)
EOF
cerr  "a 'loop' with no body"              "p.w:1:1: expected an indented block after this 'loop'" <<'EOF'
loop true
EOF
cerr  "a 'loop in' with no body"           "p.w:1:1: expected an indented block after this 'loop'" <<'EOF'
loop k in "ab"
out(1)
EOF
cerr  "a hook with no body"                "p.w:3:1: expected an indented block after this hook" <<'EOF'
f(x)
    return x
f:before
out(f(1))
EOF
cerr  "an unclosed '(' at the end of the file" "p.w:2:5: this '(' is never closed" <<'EOF'
out(1)
x = (1 +
EOF
cerr  "an unclosed '{' at the end of the file" "p.w:1:5: this '{' is never closed" <<'EOF'
x = {a: 1
EOF
cerr  "an unclosed '(' swallows the lines after it" "p.w:1:4: this '(' is never closed" <<'EOF'
out((1 + 2)
y = 3
out(y)
EOF
# A definition header and a call are the same shape, and the indent after it is
# what tells them apart. So `f(1)` with a body under it is a definition whose
# parameter is a number. That used to reach the analyzer as a list of names
# holding a number and fault there, showing the user a line of word.w.
cerr  "a literal where a parameter belongs"  "a parameter must be a name" <<'EOF'
f(1)
    return 2
out(f(3))
EOF
cerr  "text where a parameter belongs"       "a parameter must be a name" <<'EOF'
f("x")
    return 2
out(f(3))
EOF
cerr  "a subscript where a parameter belongs" "a parameter must be a name" <<'EOF'
f(a[0])
    return 2
out(f(3))
EOF
# ...and the header has to be a call shape at all. A bare name or a subscript
# with a block under it is not a definition, and used to reach the same place
# with the node's line number standing in for its parameter list.
cerr  "a bare name with a block under it"    "a definition needs a name and its parameters" <<'EOF'
x
    return 1
EOF
cerr  "a subscript with a block under it"    "a definition needs a name and its parameters" <<'EOF'
a = text(2)
a[0]
    return 1
EOF

echo "== one statement per line, and no nested functions (SPEC 4, 8.1) =="
# A second call on a line used to be parsed as a statement of its own, and the
# first reached codegen as a node it had no case for: x86-64 dropped it and
# arm64 refused the program with no location. A call with a deeper line under
# it inside a block was parsed as a nested function, with the same split. Both
# are front-end errors now, so both targets report the same thing.
cerr_both "two calls on one line are an error" "p.w:1:8: expected the end of the line (one statement per line)" <<'EOF'
out(1) out(2) out(3)
EOF
cerr_both "two calls on one line in a body are an error" "p.w:2:12: expected the end of the line" <<'EOF'
f(a)
    out(a) out(a + 1)
    return 0
k = f(5)
out(k)
EOF
cerr_both "an undefined call after a call is reported, not dropped" "p.w:1:8: expected the end of the line" <<'EOF'
out(1) nosuch(2) out(3)
EOF
cerr_both "a name before a call is a bare expression" "p.w:2:1: a bare expression is not a statement" <<'EOF'
x = 3
x out(x)
EOF
cerr_both "a bare arithmetic line is an error" "p.w:2:1: a bare expression is not a statement" <<'EOF'
x = 3
x + 1
EOF
cerr_both "a nested function is an error" "p.w:3:9: unexpected indent (a function is defined at the top level only)" <<'EOF'
f()
    g()
        return 1
    return 2
out(f())
EOF
cerr_both "an indent under a call in a top-level if is an error" "p.w:4:9: unexpected indent (a function is defined at the top level only)" <<'EOF'
x = 1
if x == 1
    out(x)
        out(2)
EOF
cerr_both "a function inside a hook is an error" "p.w:5:9: unexpected indent (a function is defined at the top level only)" <<'EOF'
f(a)
    return a
f:before
    g(b)
        return b
    return true
out(f(1))
EOF
cerr_both "a call cannot be assigned to at the top level" "p.w:3:1: cannot assign to a call" <<'EOF'
f(a)
    return a
f(1) = 3
EOF
cerr_both "a call cannot be assigned to in a function" "p.w:4:5: cannot assign to a call" <<'EOF'
f(a)
    return a
g()
    f(1) = 3
    return 5
out(g())
EOF
crun "an element of a call's result can be assigned" "7" <<'EOF'
f(a)
    return a
x = array(2)
f(x)[1] = 7
out(x[1])
EOF
cerr_both "an import after other lines is an error" "p.w:2:1: an import goes at the top of app.w" <<'EOF'
out(1)
import fs
EOF

echo "== diagnostics: malformed literals fail loudly at lex time (SPEC 2.6/2.8) =="
# An integer literal is limited to 2^61-1 = 2305843009213693951, half the value
# range (SPEC 2.6). The compiler writes a literal as the tagged word value*2+1
# and works that out in its own 63-bit arithmetic, where 2^62-1 is the largest
# that fits, so the lexer rejects anything larger instead of letting it
# overflow and mis-encode.
cerr  "integer literal above 2^61-1 rejected" "out of range (max 2305843009213693951)" <<'EOF'
out(2305843009213693952)
EOF
cerr  "wildly out-of-range integer"       "out of range" <<'EOF'
out(999999999999999999999)
EOF
cerr  "doubled underscore in a number"    "'_' in a number must sit between two digits" <<'EOF'
out(1__0)
EOF
cerr  "trailing underscore in a number"   "'_' in a number must sit between two digits" <<'EOF'
out(5_)
EOF
cerr  "digit immediately followed by id"  "cannot be immediately followed by a letter" <<'EOF'
out(12abc)
EOF
cerr  "hex form is rejected"              "cannot be immediately followed by a letter" <<'EOF'
out(0x1F)
EOF
cerr  "empty character literal"           "empty character literal" <<'EOF'
out('')
EOF
cerr  "multi-code-point char literal"     "single code point" <<'EOF'
out('ab')
EOF
# SPEC 2.8 has a short, closed set of escapes. Each rejected spelling is checked
# in both literal forms, because otherwise a typo changes the data (it used to
# become a NUL) before the parser can help.
cerr  "unknown escape in a string"         "unknown escape sequence" <<'EOF'
out("\q")
EOF
cerr  "hex escape in a string is rejected" "unknown escape sequence" <<'EOF'
out("\x")
EOF
cerr  "unicode escape in a string is rejected" "unknown escape sequence" <<'EOF'
out("\u")
EOF
cerr  "unfinished escape in a string"     "unterminated escape sequence" <<'EOF'
out("bad\
EOF
cerr  "unknown escape in a character"     "unknown escape sequence" <<'EOF'
out('\q')
EOF
cerr  "hex escape in a character is rejected" "unknown escape sequence" <<'EOF'
out('\x')
EOF
cerr  "unicode escape in a character is rejected" "unknown escape sequence" <<'EOF'
out('\u')
EOF
cerr  "unfinished escape in a character"  "unterminated escape sequence" <<'EOF'
out('\
EOF
cerr  "raw newline in a string"           "newline in string literal" <<'EOF'
out("one
two")
EOF
cerr  "raw newline in a character"        "newline in character literal" <<'EOF'
out('a
')
EOF
# A literal is text, and text is code points (SPEC 2.1): the lexer decodes the
# UTF-8 it reads from the file, so a two-byte character is one element, prints
# back as itself, and indexes as its code point.
crun  "a non-ASCII literal prints as itself" "héllo — café" <<'EOF'
out("héllo — café")
EOF
crun  "len counts code points, not bytes"  "5" <<'EOF'
out(len("héllo"))
EOF
crun  "indexing gives the code point"      "233" <<'EOF'
out("héllo"[1])
EOF
crun  "a non-ASCII character literal"      "233" <<'EOF'
out('é')
EOF
crun  "a 4-byte character is one element"  "1" <<'EOF'
out(len("😀"))
EOF

# The valid forms these guards bracket must still lex and run unchanged.
crun  "max legal integer literal"         "2305843009213693951" <<'EOF'
out(2305843009213693951)
EOF
crun  "underscores between digits are ok" "1000000" <<'EOF'
out(1_000_000)
EOF
# Separators go between digits in every part of a number (SPEC 2.6). In the
# fraction and the exponent they used to be "a letter or '_'" after a number.
crun  "underscores in a fraction and an exponent" "$(printf '3.141592\n10000000000.0\n102.5')" <<'EOF'
out(3.141_592)
out(1e1_0)
out(1_0.2_5e0_1)
EOF
cerr  "trailing underscore in a fraction"  "p.w:1:5: '_' in a number must sit between two digits" <<'EOF'
out(3.14_)
EOF
cerr  "doubled underscore in a fraction"   "p.w:1:5: '_' in a number must sit between two digits" <<'EOF'
out(1.2__3)
EOF
cerr  "underscore before an exponent"      "p.w:1:5: '_' in a number must sit between two digits" <<'EOF'
out(1.5_e3)
EOF
cerr  "trailing underscore in an exponent" "p.w:1:5: '_' in a number must sit between two digits" <<'EOF'
out(2e1_)
EOF
crun  "a decimal point is still a float"  "3.14" <<'EOF'
out(3.14)
EOF
crun  "an escaped quote character"        "39" <<'EOF'
out('\'')
EOF

echo "== diagnostics: integer arithmetic traps on overflow (SPEC 10.2 / value model) =="
# The value range is 2^62-1; (2^61-1)*4 exceeds it, so the operation must die with
# "integer overflow" and exit 70 rather than silently wrapping to a wrong answer.
cat > "$p" <<'EOF'
out(2305843009213693951 * 4)
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$($TO "$exe" 2>&1); rc=$?
  case "$got" in *"integer overflow"*) m=1;; *) m=0;; esac
  if [ "$m" = 1 ] && [ "$rc" = 70 ]; then ok "arithmetic overflow traps (integer overflow, exit 70)"
  else bad "arithmetic overflow" "got [$got] rc=$rc (want 'integer overflow', exit 70)"; fi
else bad "arithmetic overflow" "build failed"; fi
# addition just below the ceiling must be exact, not a false trap: (2^61-1)*2 = 2^62-2
crun  "max non-overflowing sum is exact"  "4611686018427387902" <<'EOF'
out(2305843009213693951 + 2305843009213693951)
EOF
# a 10^18 literal was above the old 2^59-1 cap; the 63-bit tag lifts it into range
crun  "literal past the old cap runs"     "1000000000000000000" <<'EOF'
out(1000000000000000000)
EOF

echo "== diagnostics: runaway recursion is a checked failure, not a SIGSEGV (SPEC 10.2) =="
# Unbounded recursion must stop with `p.w:N: stack exhausted` and exit 70. The
# stack guard in each prologue makes deep recursion a diagnostic, not a SIGSEGV.
cdie  "runaway recursion traps (stack exhausted, exit 70)" "stack exhausted" 70 <<'EOF'
f(n)
    return f(n + 1)
out(f(0))
EOF
# A recursion with no fallible op before the self-call still reports a line.
cdie  "bare self-recursion traps too"      "stack exhausted" 70 <<'EOF'
g()
    return g()
out(g())
EOF
# The guard must not be too tight: legitimately deep (but bounded) recursion runs.
crun  "deep-but-bounded recursion still runs" "12502500" <<'EOF'
sumto(n)
    if n <= 0
        return 0
    return n + sumto(n - 1)
out(sumto(5000))
EOF

echo "== diagnostics: analyzer errors name the offending thing =="
cerr  "undefined variable names it"       "undefined variable 'ghost'" <<'EOF'
out(ghost)
EOF
cerr  "undefined function names it"       "call to undefined function 'nope'" <<'EOF'
nope(1)
EOF
# An accidental definition nobody calls is a located error (SPEC 10.1, §15). A
# bare `name(args)` line with an indented block under it is a definition, not a
# call, so an accidental indent makes a dead function, and this catches it.
cerr  "unused function is a located error"  "function 'orphan' is defined but never used" <<'EOF'
orphan(x)
    return x + 1
out(42)
EOF
# A called function is fine, and a function with a contract hook is exempt even
# if this program never calls it, since the hook shows it's wanted.
crun  "a called function is not flagged"    "42" <<'EOF'
twice(x)
    return x + x
out(twice(21))
EOF
cbuild "a hooked-but-uncalled function is allowed" <<'EOF'
audited(x)
    return x
audited:before
    return true
out(7)
EOF
# A call counts when the top level or a hook reaches it. A call from the
# function's own body counted wherever it was, so a dead function that
# recursed, or two that called each other, compiled with nothing said.
cerr  "a function that only calls itself is unused" "p.w:1:1: function 'f' is defined but never used" <<'EOF'
f(n)
    return f(n - 1)
out(1)
EOF
cerr  "two functions that only call each other are unused" "p.w:1:1: function 'f' is defined but never used: the only calls to it are in functions that are never used either" <<'EOF'
f(n)
    return g(n)
g(n)
    return f(n)
out(1)
EOF
cerr  "a dead chain is reported at its head" "p.w:3:1: function 'f' is defined but never used" <<'EOF'
g()
    return 1
f()
    return g()
out(1)
EOF
crun  "a recursive function the program calls is used" "120" <<'EOF'
fact(n)
    if n < 2
        return 1
    return n * fact(n - 1)
out(fact(5))
EOF
crun  "a function only a hook calls is used" "1" <<'EOF'
positive(x)
    return x > 0
audited(x)
    return x
audited:before
    return positive(x)
out(audited(1))
EOF
cbuild "a function a hooked function calls is used" <<'EOF'
helper(x)
    return x
audited(x)
    return helper(x)
audited:before
    return true
out(7)
EOF
# An unknown `import` must not compile. It used to be recorded, match no
# module, and say nothing, so a typo showed up later as "unknown function
# 'get'" at the call site, pointing at the wrong line. The module list is closed
# (fs, net, json, txt and the internal sys), and any other name is an error at
# the import line (SPEC §11.1).
cerr  "unknown import is rejected, not ignored" "unknown module 'blah'" <<'EOF'
import blah
out(1)
EOF
cerr  "an import typo names the module, at its own line" "unknown module 'ent'" <<'EOF'
import ent
out(1)
EOF
cerr  "a bad import after a good one is still caught" "unknown module 'nope'" <<'EOF'
import fs
import nope
out(1)
EOF
cbuild "every built-in module name still imports" <<'EOF'
import fs
import net
import json
out(len(stringify({a: 1})) . (read("/etc/hostname") == none) . (get("http://127.0.0.1:9/") == none))
EOF

# A module function doesn't need its import: the compiler knows which module
# each of these names belongs to and brings it in on first use. The name still
# has to be one it knows, so a typo is still an error, and a function the
# program defines itself still wins over the module's.
cbuild "a module function needs no import" <<'EOF'
body = get("http://example.com")
out(len(body))
EOF
crun  "a program's own function still beats the module's" "99" <<'EOF'
split(s, sep)
    return 99
out(split("a,b", ","))
EOF
cerr  "a misspelled module function is still an error" "call to undefined function 'stringifyy'" <<'EOF'
out(stringifyy({a: 1}))
EOF
cerr  "an unknown module is still an error at the import line" "unknown module 'nope'" <<'EOF'
import nope
out(1)
EOF
cerr  "wrong argument count"              "'len' expects 1 argument(s), but got 2" <<'EOF'
out(len(1, 2))
EOF
cerr  "len on a number"                   "needs a region" <<'EOF'
out(len(5))
EOF
cerr  "arithmetic on a region"            "must be a number, but got a region" <<'EOF'
out(1 + "x")
EOF
cerr  "indexing with a region"            "index must be a number" <<'EOF'
a = text(2)
out(a["k"])
EOF
# `v = 1` then `v = 2` is a declaration and then a store. There's one operator
# and the compiler decides which it is, so there's no redeclaration to report.
# The rule that's left is the loop variable's: `loop v in ...` binds a new
# name, and one slot per name (collect_locals) means reusing a live one would
# overwrite it.
cerr  "loop variable may not reuse a live name" "'v' is already defined in this scope" <<'EOF'
v = 1
a = text(2)
loop v in a
    out(v)
EOF
crun  "assigning twice declares, then stores" "1 2" <<'EOF'
v = 1
w = v
v = 2
out(w . " " . v)
EOF
# With one assignment operator, the typo that `:=` used to catch at the write
# (`totl = 0` for `total = 0`) is caught instead by the value going unread, but
# only when the value is call-free. `junk = text(1000)` exists for the
# allocation, and a call is the only expression with a side effect (§4.2), so a
# discarded call result is a decision and a discarded literal is a mistake.
# That's why this can be an error with no `_name` escape hatch to learn.
cerr  "a discarded literal is a typo"     "'totl' is assigned but never read" <<'EOF'
total = 0
totl = 5
out(total)
EOF
cerr  "so is a discarded computation"     "'m' is assigned but never read" <<'EOF'
n = 3
m = n * 2
out(n)
EOF
crun  "a discarded call result is not"    "1" <<'EOF'
junk = text(1000)
out(1)
EOF
crun  "an unused parameter is not"        "1" <<'EOF'
f(a, b)
    return a
out(f(1, 2))
EOF
crun  "an unused loop variable is not"    "3" <<'EOF'
a = text(3)
n = 0
loop v in a
    n = n + 1
out(n)
EOF
# A scope holds any number of names. It stopped at 256 with "too many variables
# in this scope (max 256)", a ceiling SPEC 10.1 does not have, and the
# definite-assignment set behind that number has to cover every name past it.
# Generated: too many lines for a heredoc. (test_a64_lang.sh runs bigger frames
# on both targets.)
awk 'BEGIN{for(i=0;i<300;i++)print "v"i" = "i; print "t = 0"; for(i=0;i<300;i++) print "t = t + v"i; print "out(t)"}' > "$p"
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1 && [ "$($TO "$exe" 2>&1)" = 44850 ]; then ok "300 names at the top level compile and run"
else bad "300 names at the top level" "$("$WORD" build "$p" -o "$exe" 2>&1 | head -1)"; fi
awk 'BEGIN{printf "g("; for(i=0;i<300;i++) printf "%sp%d", (i?", ":""), i; print ")"; print "    return p0 + p299"; printf "out(g("; for(i=0;i<300;i++) printf "%s%d", (i?", ":""), i; print "))"}' > "$p"
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1 && [ "$($TO "$exe" 2>&1)" = 299 ]; then ok "a function with 300 parameters"
else bad "a function with 300 parameters" "$("$WORD" build "$p" -o "$exe" 2>&1 | head -1)"; fi
awk 'BEGIN{print "f(c)"; for(i=0;i<300;i++)print "    v"i" = "i; print "    t = 0"; for(i=0;i<300;i++) print "    t = t + v"i; print "    if c == 1"; print "        v300 = 1"; print "    return t + v300"; print "out(f(1))"}' > "$p"
got=$("$WORD" build "$p" -o "$exe" 2>&1); rc=$?
case "$got" in *"p.w:605:16: 'v300' is read here but is not assigned on every path"*) [ "$rc" = 1 ] && ok "definite assignment still covers the 301st name" \
    || bad "definite assignment past 256" "rc=$rc" ;;
  *) bad "definite assignment past 256" "got [$got] rc=$rc" ;; esac
cerr  "break outside a loop"              "'break' is only allowed inside a loop" <<'EOF'
break
EOF

echo "== diagnostics: contract mis-declarations =="
cerr  "bare 'return' in a hook"           "must 'return' a value" <<'EOF'
g(x)
    return x

g:before
    return
EOF
cerr  "duplicate function definition"     "'dup' is already defined" <<'EOF'
dup(a)
    return a

dup(b)
    return b
EOF
# The error names both places and says to rename one (SPEC 11). It used to
# name only the second.
printf 'dup(a)\n    return a\n\ndup(b)\n    return b\nout(dup(1))\n' > "$p"
got=$("$WORD" build "$p" -o "$exe" 2>&1); rc=$?
case "$got" in
  *"p.w:4:1: 'dup' is already defined at "*"p.w:1:1, and there are no namespaces, so rename one of them"*) m=1;;
  *) m=0;;
esac
if [ "$m" = 1 ] && [ "$rc" = 1 ]; then ok "a duplicate definition names both places"
else bad "a duplicate definition names both places" "rc=$rc [$got]"; fi
# The top-level statements are compiled as a function called _toplevel. A
# program's own _toplevel used to take its label and fail in the assembler.
cerr  "a function called _toplevel is refused with its line" "p.w:1:1: '_toplevel' is the name the compiler uses" <<'EOF'
_toplevel()
    return 1
out(_toplevel())
EOF
cerr  "two :before hooks for one function" "already has a ':before' hook" <<'EOF'
h(x)
    return x

h:before
    return true

h:before
    return true
EOF
cerr  "shared hook with mismatched params" "must have identical parameters" <<'EOF'
one(a)
    return a

two(a, b)
    return a

one:before, two:before
    return true
EOF
cerr  "shared hook mixing :before and :after" "all ':before' or all ':after'" <<'EOF'
aa(x)
    return x

bb(x)
    return x

aa:before, bb:after
    return true
EOF
# SPEC 8.3: on a mismatch the compiler reports both functions and their
# parameters. It used to give the rule and nothing else.
cerr  "a shared-hook mismatch names both functions" "'one(a)' and 'two(a, b)' differ" <<'EOF'
one(a)
    return a

two(a, b)
    return a

one:before, two:before
    return true
EOF
# A hook is an observer (SPEC 8.2): it may read its function's parameters and
# `result`, and may not assign them. It shares their slots, so an assignment
# used to change what the body ran with or what the caller got back.
cerr_both "a before-hook cannot assign a parameter" "p.w:4:5: a hook only observes, so it cannot assign to 'a'" <<'EOF'
f(a)
    return a
f:before
    a = 99
    return true
out(f(1))
EOF
cerr_both "an after-hook cannot assign result" "p.w:4:5: a hook only observes, so it cannot assign to 'result'" <<'EOF'
f(a)
    return a
f:after
    result = 99
    return true
out(f(1))
EOF
crun "a hook can still assign a name of its own" "1" <<'EOF'
f(a)
    return a
f:before
    b = a + 1
    return b > 0
out(f(1))
EOF
cerr  "contract names an unknown function" "names undefined function 'missing'" <<'EOF'
missing:before
    return true
EOF
# A hook is ':before' or ':after'. Any other word used to be accepted: the
# analyzer took it for a before-hook and codegen ran it as an after-hook, so a
# misspelt guard ran after the body it was meant to stop.
cerr_both "a misspelt hook kind is an error" "p.w:4:3: a contract hook is ':before' or ':after', not ':befor'" <<'EOF'
f(x)
    return x

f:befor
    return x > 0
out(f(1))
EOF
cerr_both "a hook kind is lower case" "p.w:3:3: a contract hook is ':before' or ':after', not ':Before'" <<'EOF'
f(x)
    return x
f:Before
    return true
out(f(1))
EOF

echo "== surface builtins: now / random / env =="
crun  "now() is a positive nanosecond clock" "true" <<'EOF'
out(now() > 0)
EOF
crun  "random() is non-negative"             "true" <<'EOF'
out(random() >= 0)
EOF
crun  "random() varies between calls"        "true" <<'EOF'
out(random() != random())
EOF
# env() reads the live process environment: a set var yields its value, an unset
# one yields `none`. Those are different answers from a variable set to the empty
# string, which they used to share. crun can't set env, so drive $exe directly.
# The last line asks by another case: Linux names are case-sensitive, and on
# Windows they aren't (test_win_pe.sh has that half).
cat > "$p" <<'EOF'
out(env("WORD_TEST_VAR"))
out(env("WORD_ABSENT_VAR_ZZZ") == none)
out(env("WORD_EMPTY_VAR") == none)
out(len(env("WORD_EMPTY_VAR")))
out(env("word_test_var") == none)
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$(WORD_TEST_VAR=hi WORD_EMPTY_VAR= $TO "$exe" 2>&1); rc=$?
  other=true
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) other=false;; esac
  want=$(printf 'hi
true
false
0
%s' "$other")
  if [ "$got" = "$want" ] && [ "$rc" = 0 ]; then ok "env(): a set var, an unset one (none), an empty one, another case"
  else bad "env()" "got [$got] rc=$rc want [$want]"; fi
else bad "env()" "build failed"; fi
# Each entry's first = ends its name, and no name is "" or holds an =. The name
# was matched on across that =, so with WORD_EQ=B=C set, env("WORD_EQ=B")
# answered "C". The value can hold an = as it likes.
cat > "$p" <<'EOF'
out(env("WORD_EQ"))
out(env("WORD_EQ=B") == none)
out(env("WORD_EQ=") == none)
out(env("") == none)
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$(WORD_EQ=B=C $TO "$exe" 2>&1 | tr '\n' ' ')
  if [ "$got" = "B=C true true true " ]; then ok "env() of a name holding = or of \"\" is none"
  else bad "env() of a name holding =" "got [$got] want [B=C true true true ]"; fi
else bad "env() of a name holding =" "build failed"; fi

# Rendering a number to text divides by ten once per digit, and the division is
# a reciprocal multiply instead of `div`: 0xCCCCCCCCCCCCCCCD is ceil(2^67/10),
# and the theorem that makes the shifted high half exact needs M*10 - 2^67 (= 2)
# to be at most 2^3, which it is. A wrong constant or a wrong shift renders a
# wrong digit somewhere, so the check is a sweep: every power-of-ten boundary
# and its neighbours in both signs, then five thousand wide pseudo-random
# values, each round-tripped through number() (a separate implementation that
# parses instead of rendering) and rebuilt digit by digit from the characters,
# so the two can't agree on the same wrong answer.
crun "decimal rendering is exact at every power-of-ten boundary and across the range" "0" <<'EOF'
bad = 0
x = 1
i = 0
loop i < 18
    d = 0 - 1
    loop d <= 1
        v = x + d
        if number(v . "") != v
            bad = bad + 1
        if number((0 - v) . "") != (0 - v)
            bad = bad + 1
        d = d + 1
    x = x * 10
    i = i + 1
if number(0 . "") != 0
    bad = bad + 1
s = 123456789
k = 0
loop k < 5000
    s = (s * 48271) % 2147483647
    v = s * 999999937
    t = v . ""
    if number(t) != v
        bad = bad + 1
    acc = 0
    m = 0
    loop m < len(t)
        acc = acc * 10 + (t[m] - 48)
        m = m + 1
    if acc != v
        bad = bad + 1
    k = k + 1
out(bad)
EOF

echo "== surface builtins: number / find / sort =="
crun  "number() parses integers, none on failure" "42 -7 none none 99" <<'EOF'
out(number("42") . " " . number("-7") . " " . number("abc") . " " . number("") . " " . number(99))
EOF
crun  "a parsed zero is not a failed parse" "0 true false" <<'EOF'
out(number("0") . " " . (number("wat") == none) . " " . (number("0") == none))
EOF
crun  "kind() folds all singleton kinds as values" "true true true true true true" <<'EOF'
out((kind(true) == "boolean") . " " . (kind(false) == "boolean") . " " . (kind(null) == "null") . " " . (kind(none) == "none") . " " . (kind(true) != "null") . " " . (kind(null) != "none"))
EOF
crun  "kind() folds all singleton kinds in conditions" "4" <<'EOF'
hits = 0
if kind(true) == "boolean"
    hits = hits + 1
if kind(false) == "boolean"
    hits = hits + 1
if kind(null) == "null"
    hits = hits + 1
if kind(none) == "none"
    hits = hits + 1
out(hits)
EOF
crun  "find() locates a run, none when absent" "2 none 0" <<'EOF'
out(find("hello", "ll") . " " . find("hello", "z") . " " . find("hello", ""))
EOF

# A miss is `none`, which isn't a condition, so a program has to test for it.
# The miss used to be -1, which was truthy, so `if find(...)` fired on a miss,
# the opposite of what the line looks like it asks.
crun  "a find() miss is not a condition"       "not found" <<'EOF'
if find("hello", "z") == none
    out("not found")
else
    out("found")
EOF
crun  "sort() orders a copy, input intact"     "11234 / 31412" <<'EOF'
a = text(5)
a[0] = 3
a[1] = 1
a[2] = 4
a[3] = 1
a[4] = 2
s = sort(a)
out(s[0] . s[1] . s[2] . s[3] . s[4] . " / " . a[0] . a[1] . a[2] . a[3] . a[4])
EOF
crun  "sort() on text is lexicographic"        "abcd" <<'EOF'
out(sort("dcba"))
EOF
cerr  "sort() rejects a number"                "needs a region" <<'EOF'
out(sort(5))
EOF

echo "== fs.rename: atomic replace =="
# rename() moves a file and reports success; the old path then reads as `none`.
cat > "$p" <<EOF
import fs
out(write("$tmp/ra", "durable"))
out(rename("$tmp/ra", "$tmp/rb"))
out(read("$tmp/rb"))
out(read("$tmp/ra"))
out(rename("$tmp/no_such_dir_zzz/x", "$tmp/y"))
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$($TO "$exe" 2>&1); rc=$?; want=$(printf 'true\ntrue\ndurable\nnone\nfalse')
  if [ "$got" = "$want" ] && [ "$rc" = 0 ]; then ok "rename() moves a file, old path gone, bad path fails"
  else bad "fs.rename()" "got [$got] rc=$rc"; fi
else bad "fs.rename()" "build failed"; fi
# A directory never replaces a file, and a file never replaces a directory:
# rename(2) refuses both (ENOTDIR, EISDIR) and nothing moves. On Windows
# MoveFileExA put the directory over the file and the file was gone.
mkdir -p "$tmp/rd_a/sub" "$tmp/rd_b"
printf 'keep-a' > "$tmp/rf_a"; printf 'keep-b' > "$tmp/rf_b"; printf 'k' > "$tmp/rd_a/sub/k"
cat > "$p" <<EOF
out(rename("$tmp/rd_a", "$tmp/rf_a"))
out(read("$tmp/rf_a"))
out(read("$tmp/rd_a/sub/k"))
out(rename("$tmp/rf_b", "$tmp/rd_b"))
out(read("$tmp/rf_b"))
out(dir("$tmp/rd_b") != none)
out(rename("$tmp/rd_a", "$tmp/rd_c"))
out(read("$tmp/rd_c/sub/k"))
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$($TO "$exe" 2>&1 | tr '\n' ' ')
  want="false keep-a k false keep-b true true k "
  if [ "$got" = "$want" ]; then ok "rename() puts neither a directory over a file nor a file over a directory"
  else bad "rename() of a directory over a file" "got [$got] want [$want]"; fi
else bad "rename() of a directory over a file" "build failed"; fi

echo "== byte-backed regions: fs.read is 1x memory, works everywhere =="
# fs.read returns a byte-backed region (one byte per element, not an 8-byte word).
# It must behave identically to a code-point region under every operation, so the
# memory saving is invisible to semantics. Round-trips content and covers index,
# len, slice, out, ==, ., find, number, sort, and index-store.
printf 'ABCDE' > "$tmp/bb.bin"
cat > "$p" <<EOF
import fs
d = read("$tmp/bb.bin")
out(len(d))
out(d[0])
out(d[4])
out(copy(d, 1, 4))
out(d == "ABCDE")
out(d == "ABCDx")
out(d . "!")
out(find(d, "CD"))
out(find("ZZABCDE", d))
d[0] = 122
out(d)
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$($TO "$exe" 2>&1); rc=$?; want=$(printf '5\n65\n69\nBCD\ntrue\nfalse\nABCDE!\n2\n2\nzBCDE')
  if [ "$got" = "$want" ] && [ "$rc" = 0 ]; then ok "byte-backed region behaves as a normal region under every op"
  else bad "byte-backed ops" "got [$got] rc=$rc"; fi
else bad "byte-backed ops" "build failed"; fi
# number() parses a byte-backed region of digits.
printf '10000000' > "$tmp/n.bin"
cat > "$p" <<EOF
import fs
out(number(read("$tmp/n.bin")) + 1)
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1; then
  got=$($TO "$exe" 2>&1)
  if [ "$got" = 10000001 ]; then ok "number() parses a byte-backed region"
  else bad "number() on bytes" "got [$got]"; fi
else bad "number() on bytes" "build failed"; fi
# A file round-trips byte-for-byte through read -> write (binary-safe, no 8x).
head -c 20000 /dev/urandom > "$tmp/bin_in"
cat > "$p" <<EOF
import fs
out(write("$tmp/bin_out", read("$tmp/bin_in")))
EOF
if "$WORD" build "$p" -o "$exe" >/dev/null 2>&1 && $TO "$exe" >/dev/null 2>&1 && cmp -s "$tmp/bin_in" "$tmp/bin_out"; then
  ok "read -> write round-trips a binary file byte-for-byte"
else bad "byte-backed round-trip" "20KB binary differs after read/write"; fi

echo "== word format: one canonical indentation =="
# Messy indentation + trailing whitespace + a comment that must align with the
# code it precedes. `word format` rewrites the file in place to four-space-per-
# level, strips trailing whitespace, and leaves nothing else to configure.
fin="$tmp/fmt.w"
printf '  // c\nout("a")   \nloop true\n      out("b")\n      break\n' > "$fin"
"$WORD" format "$fin" >/dev/null 2>&1
want=$(printf '// c\nout("a")\nloop true\n    out("b")\n    break')
got=$(cat "$fin")
if [ "$got" = "$want" ]; then ok "format canonicalizes indent, strips trailing ws, aligns comments"
else bad "format canonical" "got [$got]"; fi

# Idempotent: a second pass changes nothing.
cp "$fin" "$tmp/fmt2.w"; "$WORD" format "$tmp/fmt2.w" >/dev/null 2>&1
if cmp -s "$fin" "$tmp/fmt2.w"; then ok "format is idempotent"
else bad "format idempotent" "second pass changed the file"; fi

# Semantics preserved: the formatted program builds and runs unchanged.
if "$WORD" build "$fin" -o "$exe" >/dev/null 2>&1; then
  got=$($TO "$exe" 2>&1); rc=$?; want=$(printf 'a\nb')
  if [ "$got" = "$want" ] && [ "$rc" = 0 ]; then ok "formatted program builds and runs identically"
  else bad "format semantics" "got [$got] rc=$rc"; fi
else bad "format semantics" "formatted program failed to build"; fi

# An already-canonical file is left byte-for-byte untouched.
printf 'out("ok")\nloop true\n    break\n' > "$tmp/canon.w"; cp "$tmp/canon.w" "$tmp/canon.orig"
"$WORD" format "$tmp/canon.w" >/dev/null 2>&1
if cmp -s "$tmp/canon.w" "$tmp/canon.orig"; then ok "format leaves a canonical file untouched"
else bad "format canonical no-op" "modified an already-canonical file"; fi

# Missing argument is a located usage error, not a crash.
if "$WORD" format >/dev/null 2>&1; then bad "format usage" "missing arg exited 0"
else ok "format with no file prints usage and exits nonzero"; fi

# The formatter reads structure the way the lexer does. A line inside unmatched
# brackets takes no indentation (here a call continued at column 0 in an if
# body), and a comment-only line led by a tab is still comment-only. Both are
# programs the compiler accepts, and both used to be refused as an internal error.
printf 'f()\n    if true\n        x = add(\n1,\n2)\n        return x\n    return 0\nadd(a, b)\n    return a + b\nout(f())\n' > "$tmp/fparen.w"
cp "$tmp/fparen.w" "$tmp/fparen.orig"
"$WORD" format "$tmp/fparen.w" > "$tmp/fmt.out" 2>&1; rc=$?
got=$($TO "$WORD" run "$tmp/fparen.w" 2>&1)
if [ "$rc" = 0 ] && cmp -s "$tmp/fparen.w" "$tmp/fparen.orig" && [ "$got" = 3 ]; then
  ok "format leaves a continuation line at column 0 where the lexer reads it"
else bad "format continuation at column 0" "rc=$rc [$(head -c 200 "$tmp/fmt.out")] run [$got]"; fi

printf 'f()\n    if true\n        out(1)\n\t// note\n        out(2)\n    return 0\nf()\n' > "$tmp/ftabc.w"
"$WORD" format "$tmp/ftabc.w" > "$tmp/fmt.out" 2>&1; rc=$?
want=$(printf 'f()\n    if true\n        out(1)\n        // note\n        out(2)\n    return 0\nf()')
if [ "$rc" = 0 ] && [ "$(cat "$tmp/ftabc.w")" = "$want" ]; then ok "format reads a tab-led comment line as comment-only"
else bad "format tab-led comment" "rc=$rc [$(head -c 200 "$tmp/fmt.out")] got [$(cat "$tmp/ftabc.w")]"; fi

# A continuation line moves with the line that opened the bracket, so an
# argument list stays lined up when its block is re-indented.
printf 'add(a, b)\n  return a + b\nif 1 == 1\n  x = add(1,\n          2)\n  out(x)\n' > "$tmp/falign.w"
"$WORD" format "$tmp/falign.w" > "$tmp/fmt.out" 2>&1; rc=$?
want=$(printf 'add(a, b)\n    return a + b\nif 1 == 1\n    x = add(1,\n            2)\n    out(x)')
if [ "$rc" = 0 ] && [ "$(cat "$tmp/falign.w")" = "$want" ]; then ok "format keeps a continuation line aligned with its opening line"
else bad "format continuation alignment" "rc=$rc [$(head -c 200 "$tmp/fmt.out")] got [$(cat "$tmp/falign.w")]"; fi

# A tab in indentation is an error (SPEC 2.2), and format reports where it is.
# It used to exit 0 with the tab still there.
printf 'if 1 == 1\n\tout(1)\n' > "$tmp/ftab.w"; cp "$tmp/ftab.w" "$tmp/ftab.orig"
"$WORD" format "$tmp/ftab.w" > "$tmp/fmt.out" 2>&1; rc=$?
if [ "$rc" = 1 ] && grep -q 'ftab.w:2:1: indent with spaces, not tabs' "$tmp/fmt.out" && cmp -s "$tmp/ftab.w" "$tmp/ftab.orig"; then
  ok "format refuses a tab-indented line with a located error"
else bad "format tab indent" "rc=$rc [$(head -c 200 "$tmp/fmt.out")]"; fi

# An input that does not lex gets the compiler's own located error.
printf 'x = 12abc\n' > "$tmp/flex.w"; cp "$tmp/flex.w" "$tmp/flex.orig"
"$WORD" format "$tmp/flex.w" > "$tmp/fmt.out" 2>&1; rc=$?
if [ "$rc" = 1 ] && grep -q 'flex.w:1:5: ' "$tmp/fmt.out" && ! grep -q 'internal error' "$tmp/fmt.out" && cmp -s "$tmp/flex.w" "$tmp/flex.orig"; then
  ok "format reports a lex error in its input where it is"
else bad "format lex error" "rc=$rc [$(head -c 200 "$tmp/fmt.out")]"; fi

# Any depth and any number of blank lines the compiler takes, format takes too.
awk 'BEGIN{for(i=0;i<300;i++){s="";for(j=0;j<i;j++)s=s"  ";print s "if 1 == 1"} s="";for(j=0;j<300;j++)s=s"  "; print s "out(\"deep\")"}' > "$tmp/fdeep.w"
"$WORD" format "$tmp/fdeep.w" > "$tmp/fmt.out" 2>&1; rc=$?
got=$($TO "$WORD" run "$tmp/fdeep.w" 2>&1)
if [ "$rc" = 0 ] && [ "$got" = deep ] && grep -q '^        if 1 == 1$' "$tmp/fdeep.w"; then ok "format handles 300 nested blocks"
else bad "format 300 levels" "rc=$rc [$(head -c 200 "$tmp/fmt.out")] run [$(printf '%s' "$got" | head -c 200)]"; fi
awk 'BEGIN{for(i=0;i<70000;i++)print ""; print "out(1)"}' > "$tmp/fblank.w"
"$WORD" format "$tmp/fblank.w" > "$tmp/fmt.out" 2>&1; rc=$?
got=$($TO "$WORD" run "$tmp/fblank.w" 2>&1)
if [ "$rc" = 0 ] && [ "$got" = 1 ]; then ok "format handles 70000 blank lines"
else bad "format 70000 blank lines" "rc=$rc [$(head -c 200 "$tmp/fmt.out")] run [$(printf '%s' "$got" | head -c 200)]"; fi

# Bytes above 127 come back as they were. What the formatter builds holds the
# file's bytes one per element, and write() writes text as UTF-8, so it hands
# write() bytes; otherwise every one of them would be encoded a second time.
printf 'if 1 == 1\n  // caf\303\251 \342\202\254\n  out("\360\237\230\200")\n' > "$tmp/fu8.w"
printf 'if 1 == 1\n    // caf\303\251 \342\202\254\n    out("\360\237\230\200")\n' > "$tmp/fu8.want"
"$WORD" format "$tmp/fu8.w" > "$tmp/fmt.out" 2>&1; rc=$?
if [ "$rc" = 0 ] && cmp -s "$tmp/fu8.w" "$tmp/fu8.want"; then ok "format keeps non-ASCII text byte for byte"
else bad "format non-ASCII" "rc=$rc [$(head -c 200 "$tmp/fmt.out")] got $(od -An -tx1 "$tmp/fu8.w" | head -3 | tr -d '\n')"; fi

echo "== word build -asm: dump the emitted assembly =="
# The dump is exactly the .s a build feeds the assembler, so it round-trips:
# `-asm` piped through `word asm` must produce the same binary a direct build
# does, and running it must give the same output.
asmw="$tmp/asm.w"; printf 'x = 6\nout(x * 7)\n' > "$asmw"
"$WORD" build -asm "$asmw" > "$tmp/asm.s" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && grep -q '^_start:' "$tmp/asm.s" && grep -q '\.intel_syntax' "$tmp/asm.s"; then
  ok "build -asm writes assembly to stdout"
else bad "build -asm dump" "rc=$rc, no _start/.intel_syntax marker"; fi

# `word asm` targets the host as build does, so on Windows both are PEs. The
# dump is named after its source (asm.w, asm.s), as in SPEC 14: a PE's version
# block carries the program's name, which asm takes from the .s.
asm_rt="$tmp/asm_rt"; asm_direct="$tmp/asm_direct"
if [ "$win" = 1 ]; then asm_rt="$asm_rt.exe"; asm_direct="$asm_direct.exe"; fi
if "$WORD" asm "$tmp/asm.s" "$asm_rt" >/dev/null 2>&1 && "$WORD" build "$asmw" -o "$asm_direct" >/dev/null 2>&1; then
  if cmp -s "$asm_rt" "$asm_direct"; then ok "build -asm round-trips: dump | word asm == direct build"
  else bad "build -asm round-trip" "reassembled binary differs from a direct build"; fi
  got=$($TO "$asm_rt" 2>&1)
  if [ "$got" = 42 ]; then ok "reassembled -asm dump runs identically"
  else bad "build -asm run" "got [$got] want 42"; fi
else bad "build -asm round-trip" "word asm or direct build failed"; fi

# The round trip holds for every target. `word asm` takes the same target
# flags as build, and with none it targets the host, as build does (a Windows
# word.exe gets a PE both ways).
mkdir -p "$tmp/rt"
for f in -linux -win -arm64 -mac; do
  rm -f "$tmp/rt_asm" "$tmp/rt_build"
  "$WORD" build $f -asm "$asmw" > "$tmp/rt/asm.s" 2>/dev/null
  if "$WORD" asm $f "$tmp/rt/asm.s" "$tmp/rt_asm" >/dev/null 2>&1 && "$WORD" build $f "$asmw" -o "$tmp/rt_build" >/dev/null 2>&1 \
     && cmp -s "$tmp/rt_asm" "$tmp/rt_build"; then ok "build $f -asm then asm $f == build $f"
  else bad "asm $f round-trip" "reassembled binary differs from a direct build, or a step failed"; fi
done

# -asm honours -win (order-independent) and emits the syscall shim, not raw syscalls.
"$WORD" build -win -asm "$asmw" > "$tmp/asm_win.s" 2>/dev/null
"$WORD" build -asm -win "$asmw" > "$tmp/asm_win2.s" 2>/dev/null
if cmp -s "$tmp/asm_win.s" "$tmp/asm_win2.s" && grep -q 'call w_syscall' "$tmp/asm_win.s" && ! grep -q '^    syscall$' "$tmp/asm_win.s"; then
  ok "build -asm -win dumps the Windows target (shim, order-independent)"
else bad "build -asm -win" "win dump wrong or flag order matters"; fi

# A compile error still reports a located diagnostic and exits 1 (no asm on stdout).
printf 'out(nope_undefined)\n' > "$tmp/asmbad.w"
if "$WORD" build -asm "$tmp/asmbad.w" >/dev/null 2>&1; then bad "build -asm error" "bad program exited 0"
else ok "build -asm on a bad program exits nonzero"; fi

echo "== emitted runtime is gated on what the program uses =="
# A program that never calls into a module carries none of that module's runtime.
# Without this, an HTTP request template sits in the .rodata of a hello world,
# and a scanner takes it for a network client.
printf 'out("hi")\n' > "$tmp/bare.w"
"$WORD" build -asm "$tmp/bare.w" > "$tmp/bare.s" 2>/dev/null
miss=""
for sym in rt_read rt_writef rt_rename rt_pathcstr rt_asmput rt_writex rt_exec \
           rt_cacerts rt_readline rt_getbyte rt_fill \
           filebuf pathbuf inbuf linebuf execbuf; do
  grep -q "^$sym:" "$tmp/bare.s" && miss="$miss $sym"
done
if [ -z "$miss" ]; then ok "a module-free program emits no fs/net/sys/stdin runtime"
else bad "runtime gating" "hello world still emits:$miss"; fi

if "$WORD" build "$tmp/bare.w" -o "$tmp/bare" >/dev/null 2>&1 && \
   ! strings -a "$tmp/bare" 2>/dev/null | grep -qiE 'HTTP/1|Host: |Connection: close'; then
  ok "a module-free binary contains no HTTP request text"
else bad "runtime gating" "HTTP text present in a non-net binary"; fi

# Each module's runtime comes back when the program calls it.
printf 'import fs\nout(len(read("x")))\n' > "$tmp/usefs.w"
"$WORD" build -asm "$tmp/usefs.w" > "$tmp/usefs.s" 2>/dev/null
if grep -q '^rt_read:' "$tmp/usefs.s" && grep -q '^rt_pathcstr:' "$tmp/usefs.s" \
   && grep -q '^filebuf:' "$tmp/usefs.s" && ! grep -q '^fn_net_fetch:' "$tmp/usefs.s"; then
  ok "import fs brings back the fs runtime, and only that"
else bad "runtime gating" "fs program missing fs runtime or pulling in net"; fi

printf 'x = in()\nout(x)\n' > "$tmp/usein.w"
"$WORD" build -asm "$tmp/usein.w" > "$tmp/usein.s" 2>/dev/null
if grep -q '^rt_readline:' "$tmp/usein.s" && grep -q '^inbuf:' "$tmp/usein.s"; then
  ok "in() brings back the stdin runtime"
else bad "runtime gating" "in() program has no stdin runtime"; fi

# `net` is written in word (the net library, carried in compiler/word.w) and
# bundled into a program that uses it, so what a net program carries is the
# library's own compiled functions. It carries the fs runtime too, because
# net_load_roots reads the trust store.
printf 'out(len(get("http://example.com")))\n' > "$tmp/usenet.w"
"$WORD" build -asm "$tmp/usenet.w" > "$tmp/usenet.s" 2>/dev/null
if grep -q '^fn_net_fetch:' "$tmp/usenet.s" && grep -q '^fn_tls13_client_hello:' "$tmp/usenet.s"; then
  ok "a net program carries the bundled word net library"
else bad "runtime gating" "net program missing the bundled library"; fi

# A program that doesn't reach the network carries none of it.
printf 'out(1)\n' > "$tmp/nonet.w"
"$WORD" build -asm "$tmp/nonet.w" > "$tmp/nonet.s" 2>/dev/null
if ! grep -q 'net_fetch' "$tmp/nonet.s" && ! grep -q 'tls13_' "$tmp/nonet.s"; then
  ok "a program that never calls net carries none of the library"
else bad "runtime gating" "the net library leaked into a program that does not use it"; fi

# sys comes in pieces, each for the program that calls it: the emit buffer,
# writex, exec and the sockets. A program that only opened a socket (and so
# every net program) used to carry execve and the executable writer as well,
# and one that only ran a program carried the sockets. The same goes for the
# exec and file-open arms of the Windows and macOS OS layers.
printf 'ip = bytes(4)\nout(connect(ip, 9))\n' > "$tmp/gsock.w"
printf 'l = text(1)\nl[0] = 0\nx = exec("/bin/true", l)\n' > "$tmp/gexec.w"
printf 'out(writex("x", bytes(1)))\n' > "$tmp/gwritex.w"
# sys_has <label> <program> <target> <want> <refuse>: the program's asm for that
# target defines every label in <want> and none in <refuse>.
sys_has() {
  "$WORD" build $3 -asm "$tmp/$2.w" > "$tmp/$2$3.s" 2>/dev/null || { bad "sys gating: $1 ($3)" "no asm"; return; }
  miss=""; for s in $4; do grep -q "^$s:" "$tmp/$2$3.s" || miss="$miss $s"; done
  extra=""; for s in $5; do grep -q "^$s:" "$tmp/$2$3.s" && extra="$extra $s"; done
  if [ -z "$miss$extra" ]; then ok "sys gating: $1 ($3)"
  else bad "sys gating: $1 ($3)" "missing:$miss, carries:$extra"; fi
}
for f in -linux -arm64 -win -mac; do
  sys_has "a socket-only program has no exec or file code" gsock "$f" "rt_connect" \
    "rt_exec rt_writex rt_pathcstr rt_asmput filebuf pathbuf .wsc_exec .wsc_open .ms_execve .ms_openat"
  sys_has "an exec-only program has no socket or file code" gexec "$f" "rt_exec" \
    "rt_connect rt_send rt_recv rt_writex rt_pathcstr rt_asmput filebuf .wsc_socket .wsc_open .ms_openat"
  sys_has "a writex-only program has no exec or socket code" gwritex "$f" "rt_writex rt_pathcstr" \
    "rt_exec rt_connect rt_asmput .wsc_exec .wsc_socket .ms_execve"
  sys_has "a net program has no exec and no executable writer" usenet "$f" "fn_net_fetch rt_connect" \
    "rt_exec rt_writex rt_asmput .wsc_exec .ms_execve"
done
# fs is split the same way: writing, appending and renaming come together, and
# only with a call to one of them. A program that only reads files, which every net
# program does (the trust store, resolv.conf), used to carry rt_writef and
# rt_rename, and MoveFileExA on Windows.
printf 'out(len(read("x")))\n' > "$tmp/gread.w"
printf 'out(write("x", "y"))\n' > "$tmp/gwrite.w"
printf 'out(rename("x", "y"))\n' > "$tmp/gren.w"
for f in -linux -arm64 -win -mac; do
  sys_has "a program that only reads has no file writer" gread "$f" "rt_read rt_pathcstr" \
    "rt_writef rt_rename rt_pathcstr2 pathbuf2 .wsc_rename .ms_renameat"
  sys_has "a net program has no file writer" usenet "$f" "rt_read" \
    "rt_writef rt_rename rt_pathcstr2 .wsc_rename .ms_renameat"
  sys_has "write brings the file writer" gwrite "$f" "rt_writef rt_rename" ""
  sys_has "rename brings the file writer" gren "$f" "rt_writef rt_rename rt_pathcstr2" ""
done
sys_has "rename brings the OS layer's rename" gren -win ".wsc_rename" ""
sys_has "rename brings the OS layer's rename" gren -mac ".ms_renameat" ""
# writex has to reach the OS layer's open where there is one; on Windows a
# program that called it and nothing from fs had no open to call.
sys_has "writex brings the open arm" gwritex -win ".wsc_open .wsc_close" ""
sys_has "writex brings the open arm" gwritex -mac ".ms_openat" ""
# sys.os() is the operating system a binary was built for, a constant each
# target writes in (0 Linux, 1 Windows, 2 macOS), so no environment can change
# it. sys.image() asks Windows for the path of the running executable and is
# `none` elsewhere; only a program that calls it carries rt_image.
printf 'out(os())\n' > "$tmp/gos.w"
os_is() { # <target> <the instruction that loads os()'s answer for out()>
  "$WORD" build $1 -asm "$tmp/gos.w" 2>/dev/null | grep -B2 -e '    call rt_out$' -e '    bl rt_out$' | grep -qx "    $2"; }
if os_is -linux "mov rax, 1" && os_is -win "mov rax, 3" && os_is -arm64 "mov x0, #1" && os_is -mac "mov x0, #5"; then
  ok "os() is a constant per target: 0 Linux, 1 Windows, 2 macOS"
else bad "os() per target" "a target does not load its own constant"; fi
printf 'out(os())\nout(kind(image()))\n' > "$tmp/gimg.w"
for f in -linux -arm64 -win -mac; do
  sys_has "image() brings rt_image" gimg "$f" "rt_image" ""
  sys_has "a program that never calls image() has no rt_image" bare "$f" "" "rt_image"
done
if grep -q 'GetModuleFileNameW' "$tmp/gimg-win.s" && ! grep -q 'GetModuleFileNameW' "$tmp/bare-win.s"; then
  ok "only a PE that calls image() asks GetModuleFileNameW"
else bad "image() gating" "GetModuleFileNameW missing from the image() PE or present in hello"; fi
# ...and what the built program answers on this host, with the variable the
# answer used to come from set the other way.
want="0
none"; [ "$win" = 1 ] && want="1
bytes"
if "$WORD" build "$tmp/gimg.w" -o "$exe" >/dev/null 2>&1; then
  if [ "$win" = 1 ]; then got=$(env -u OS "$exe" 2>&1); else got=$(env OS=Windows_NT "$exe" 2>&1); fi
  [ "$got" = "$want" ] && ok "os() and image() answer for this host, whatever OS says" \
    || bad "os() and image() on this host" "got [$got] want [$want]"
else bad "os() and image() on this host" "build failed"; fi
if [ "$win" = 1 ]; then
  printf 'out(len(read(image())))\n' > "$tmp/gself.w"
  if "$WORD" build "$tmp/gself.w" -o "$tmp/gself.exe" >/dev/null 2>&1 \
     && [ "$("$tmp/gself.exe")" = "$(wc -c < "$tmp/gself.exe" | tr -d ' ')" ]; then
    ok "image() names the running executable"
  else bad "image() names the running executable" "read(image()) is not this file"; fi
fi
# And no execve instruction outside a program that calls exec.
for f in -linux -arm64; do
  n=0; for g in gsock gwritex usenet; do
    grep -q 'mov rax, 59$\|mov x8, #221$' "$tmp/$g$f.s" && n=$((n+1)); done
  if [ "$n" = 0 ] && grep -q 'mov rax, 59$\|mov x8, #221$' "$tmp/gexec$f.s"; then
    ok "only the exec program issues execve ($f)"
  else bad "sys gating: execve ($f)" "$n non-exec programs issue it, or the exec program does not"; fi
done

# --- a literal operand folded into the instruction's immediate ---------------
#
# `i + 1`, `i - 1` and `i < n` against a constant lower to one instruction that
# carries the constant itself, with the tag arithmetic folded into it: `+`/`-`
# add or subtract 2b to the tagged word instead of stripping the tag, adding
# 2b+1 and putting it back. The fold only fires when the scaled constant fits a
# sign-extended imm32, so 2^30 and 2^31 sit on either side of the switch, and
# these check that both spellings agree.
crun "a folded literal add and subtract carry the tag correctly" "8|2|-3|-1|0" <<'EOF'
a = 5
b = 0 - 2
out((a + 3) . "|" . (a - 3) . "|" . (b - 1) . "|" . (b + 1) . "|" . (a - 5))
EOF
crun "the fold switches off above imm32 and answers the same" "1073741824|1073741823|2147483648|2147483647|4611686018427387902" <<'EOF'
a = 1073741823
b = 2147483647
c = 2305843009213693951
out((a + 1) . "|" . (a + 0) . "|" . (b + 1) . "|" . (b + 0) . "|" . (c + c))
EOF
crun "a folded compare orders the same as a register one" "true|false|true|false|true|false|true" <<'EOF'
n = 1073741824
m = 1073741824
out((n < 1073741825) . "|" . (n < 1073741824) . "|" . (n <= m) . "|" . (n > 2147483647) . "|" . (n >= 1073741824) . "|" . (n != m) . "|" . (n == 1073741824))
EOF
crun "a folded compare on a negative left operand" "true|true|false|false" <<'EOF'
n = 0 - 3000000000
out((n < 0) . "|" . (n < 2147483647) . "|" . (n > 0 - 1) . "|" . (n == 0 - 2147483648))
EOF
crun "the loop counter idiom is still exact at 100000 steps" "100000|4999950000" <<'EOF'
i = 0
s = 0
loop i < 100000
    s = s + i
    i = i + 1
out(i . "|" . s)
EOF

# The index bound is one unsigned compare, so a negative index and a too-large
# one take the same branch. Both must still be the located fault, and the
# message still has to give the offending index, which is what a single
# unsigned test could have lost.
cdie "a negative index still faults, and still names itself" "index -1 out of bounds for a region of length 4" 70 <<'EOF'
a = text(4)
i = 0 - 1
out(a[i])
EOF
cdie "a negative index STORE still faults, and still names itself" "index -1 out of bounds for a region of length 4" 70 <<'EOF'
a = text(4)
i = 0 - 1
a[i] = 1
EOF
cdie "an index at len still faults" "index 4 out of bounds for a region of length 4" 70 <<'EOF'
a = text(4)
i = 4
out(a[i])
EOF
crun "the last valid index still reads" "0" <<'EOF'
a = text(4)
i = 3
out(a[i])
EOF

# --- args(): the whole command line, as a list -------------------------------
#
# It replaced argument(n), which could only be asked one index at a time and
# answered an absent argument with an empty region, the same answer as an
# argument that is empty, and there was no way to ask how many there were.
cat > "$p" <<'EOF'
a = args()
out(len(a) . "|" . a[0] . "|" . a[1] . "|" . a[2])
EOF
"$WORD" build "$p" -o "$exe" >/dev/null 2>&1
got=$($TO "$exe" one two 2>&1)
# Git Bash starts a Windows program with its name spelled the Windows way.
a0="$exe"; [ "$win" = 1 ] && a0=$(cygpath -w "$exe")
case "$got" in
  3"|$a0|one|two") ok "args() is the whole command line, program name at 0" ;;
  *) bad "args()" "got [$got]" ;;
esac
cat > "$p" <<'EOF'
out(len(args()))
EOF
"$WORD" build "$p" -o "$exe" >/dev/null 2>&1
[ "$($TO "$exe")" = 1 ] && ok "args() with nothing typed is just the program name" \
  || bad "args() bare" "got [$($TO "$exe")]"
cat > "$p" <<'EOF'
out(args())
EOF
"$WORD" build "$p" -o "$exe" >/dev/null 2>&1
case "$($TO "$exe" x)" in
  '["'*'","x"]') ok "args() renders as a list, so out() of it is readable" ;;
  *) bad "args() rendering" "got [$($TO "$exe" x)]" ;;
esac
cat > "$p" <<'EOF'
out(args()[3])
EOF
"$WORD" build "$p" -o "$exe" >/dev/null 2>&1
$TO "$exe" >/dev/null 2>"$tmp/e"; rc=$?
case "$(cat "$tmp/e")" in
  *"index 3 out of bounds"*) [ "$rc" = 70 ] && ok "an argument that is not there is a bounds fault, not an empty answer" \
                              || bad "args() bounds" "rc=$rc" ;;
  *) bad "args() bounds" "[$(cat "$tmp/e")]" ;;
esac
cerr  "argument() is gone" "call to undefined function 'argument'" <<'EOF'
out(argument(1))
EOF

# --- constant folding --------------------------------------------------------
#
# Two integer literals are computed at compile time. The fold is exact or it
# doesn't happen: /0 and %0 are left for the runtime to fault on, a shift out of
# range is left alone, and an operand past 2^30 doesn't fold at all, which also
# keeps the compiler's own arithmetic from overflowing while it folds.
crun "a constant expression folds to one instruction" "86400|1048576|14|true" <<'EOF'
out((60 * 60 * 24) . "|" . (1024 * 1024) . "|" . ((3 + 4) * 2) . "|" . (2 < 3))
EOF
cbuild "the fold really is one instruction" <<'EOF'
out(60 * 60 * 24)
EOF
cat > "$p" <<'EOF'
out(60 * 60 * 24)
EOF
"$WORD" build -asm "$p" 2>/dev/null | sed -n '/^fn__toplevel\.body:/,/^fn_/p' > "$tmp/fold.s"
if grep -q 'movabs rax, 172801' "$tmp/fold.s" && ! grep -q 'imul' "$tmp/fold.s"; then
  ok "60 * 60 * 24 is emitted as the number, with no multiply left"
else bad "constant fold" "still emitting arithmetic"; fi
cdie "a folded-away divide by zero still faults at run time" "divide by zero" 70 <<'EOF'
out(1 / 0)
EOF
crun "an operand too large to fold safely still computes" "4611686018427387902" <<'EOF'
out(2305843009213693951 * 2)
EOF
crun "folding matches the runtime on truncation and sign" "-2|-1|2|1|-3" <<'EOF'
out((((0 - 7) - (0 - 7) % 3) / 3) . "|" . (0 - 7) % 3 . "|" . ((7 - 7 % 3) / 3) . "|" . 7 % 3 . "|" . ((0 - 12) >> 2))
EOF

# `/` is exact: it answers an integer only when the division comes out even, and
# a float otherwise (SPEC 3.3). The folder has to agree with the runtime about
# which. A literal pair folds and a pair through locals doesn't, and the two
# spellings have to print the same thing.
crun "an exact division is an integer, an inexact one is a float" "3|3.5|2|0.5|-3.5" <<'EOF'
out(6 / 2 . "|" . 7 / 2 . "|" . 10 / 5 . "|" . 1 / 2 . "|" . (0 - 7) / 2)
EOF
crun "and the same through locals, where the folder cannot see it" "3|3.5|0.5" <<'EOF'
a = 6
b = 7
c = 1
out(a / 2 . "|" . b / 2 . "|" . c / 2)
EOF
crun "a float that came out of / prints the way its literal does" "3.4|3.4|0.2|0.2" <<'EOF'
out(17 / 5 . "|" . 3.4 . "|" . 1 / 5 . "|" . 0.2)
EOF
# There's one division. The whole part is `(a - a % b) / b`, which is exact by
# construction: `a % b` carries the sign of `a`, so `a - a % b` is always a
# multiple of `b`, and the division always answers an integer.
crun "the whole part is an idiom, not a second divide" "3|-3|0" <<'EOF'
whole(a, b)
    return (a - a % b) / b
out(whole(7, 2) . "|" . whole(0 - 7, 2) . "|" . whole(1, 2))
EOF
crun "and a power of two is a shift, which is what bit math writes" "3|32|0" <<'EOF'
out((7 >> 1) . "|" . (256 >> 3) . "|" . (1 >> 1))
EOF
cerr "div is not a name the language knows" "call to undefined function 'div'" <<'EOF'
out(div(7, 2))
EOF

# --- slice takes an end index -----------------------------------------------
#
# It used to take a count, which reads the same as an end index and answers
# differently, the one shape in the language that could be wrong without being
# an error. `copy(s, 2, 5)` is now elements 2, 3 and 4, as it is everywhere else.
crun "slice is half-open: start up to but not including end" "cde|abc|fgh|abcdefgh" <<'EOF'
s = "abcdefgh"
out(copy(s, 2, 5) . "|" . copy(s, 0, 3) . "|" . copy(s, 5, 8) . "|" . copy(s))
EOF
crun "end == start is the empty region, and end - start is the length" "0|3|1" <<'EOF'
s = "abcdefgh"
out(len(copy(s, 4, 4)) . "|" . len(copy(s, 2, 5)) . "|" . len(copy(s, 7, 8)))
EOF
cdie "end past the length faults" "index out of bounds" 70 <<'EOF'
out(copy("abc", 1, 4))
EOF
cdie "end before start faults" "index out of bounds" 70 <<'EOF'
out(copy("abc", 2, 1))
EOF
cdie "a negative start faults" "index out of bounds" 70 <<'EOF'
i = 0 - 1
out(copy("abc", i, 2))
EOF
crun "the whole region is copy(p)" "true" <<'EOF'
s = "hello"
out(copy(s) == s)
EOF

# --- array() is the JSON array; text() is the storage ----------------------
#
# `list(n)` is gone. The name `array` now belongs to the thing JSON calls an
# array, and `text(n)` (SPEC 3.4's own word for what it allocates) is the same
# storage without the rendering mark, and without the ~4 KB of runtime that
# rendering one costs.
crun "array() prints as an array and kind() says so" "[7,0,0]|array" <<'EOF'
a = array(3)
a[0] = 7
out(a . "|" . kind(a))
EOF
crun "text() is the same storage with no mark" "3|7|text" <<'EOF'
c = text(3)
c[0] = 7
out(len(c) . "|" . c[0] . "|" . kind(c))
EOF
crun "the mark survives slice and sort, as the JSON array it is" "array|array" <<'EOF'
a = array(3)
out(kind(copy(a, 0, 2)) . "|" . kind(sort(a)))
EOF
crun "an array of text renders with quotes; cells of the same guesses" "[\"hi\"]" <<'EOF'
a = array(1)
a[0] = "hi"
out(a)
EOF
cerr "list() is gone" "call to undefined function 'list'" <<'EOF'
out(list(2))
EOF
# text() carries none of the JSON rendering runtime; array() does.
cat > "$p" <<'EOF'
c = text(3)
out(c[0])
EOF
"$WORD" build -asm "$p" 2>/dev/null | grep -q rt_map_new \
  && bad "text() dragged in the map runtime" "the gate is on array(), not text()" \
  || ok "text() carries none of the JSON-rendering runtime"

# --- what the loop already knows ------------------------------------------
#
# `loop i < len(a)` reloads the length every iteration only if the length can
# change. When the body never assigns `a`, it can't, so the load is hoisted
# into a hidden local.
cat > "$p" <<'EOF'
a = text(4)
i = 0
loop i < len(a)
    a[i] = i
    i = i + 1
out(a[3])
EOF
if "$WORD" run "$p" 2>&1 | grep -q '^3$'; then
  ok "a hoisted length still walks the whole region"
else
  bad "a hoisted length still walks the whole region" "3"
fi
# The length load is `mov rax, [reg]` off the region reference. Hoisted, it
# sits before the loop label; not hoisted, it sits inside the back edge.
"$WORD" build -asm "$p" 2>/dev/null > "$p.s"
if python3 - "$p.s" <<'PYEOF'
import re, sys
a = open(sys.argv[1]).read().split("fn__toplevel:", 1)[1]
lines = [l.strip() for l in a.splitlines()]
seen, body = {}, []
for i, l in enumerate(lines):
    m = re.match(r"^(\.L\d+):$", l)
    if m:
        seen[m.group(1)] = i
    m = re.match(r"^jmp (\.L\d+)$", l)
    if m and m.group(1) in seen:
        body += lines[seen[m.group(1)]:i]
sys.exit(1 if any(l == "mov rax, [rax]" for l in body) else 0)
PYEOF
then
  ok "len() in a loop guard is loaded once, not per iteration"
else
  bad "len() in a loop guard is loaded once" "no length load inside the loop"
fi

# When the body does assign the name, the length has to be re-read.
crun "a body that regrows the region re-reads its length" "5|5" <<'EOF'
a = text(2)
i = 0
loop i < len(a)
    if len(a) < 5
        a = text(len(a) + 1)
    i = i + 1
out(len(a) . "|" . i)
EOF

# --- and the bounds check the guard already made ---------------------------
#
# `loop i < len(a)` proves `i < len(a)`, and `i >= 0` comes from `i` being a
# counting local, only ever set to a non-negative literal or advanced by a
# positive one, which is what the unsigned check is really testing. Together
# they make `a[i]` inside the body a subscript that can't be out of range.
#
# The fact dies at the first statement that writes `i`: after `i = i + 1` the
# guard's answer is about the value before it.
bc_count() { "$WORD" build -asm "$1" 2>/dev/null | grep -c 'jae rt_boundsidx' || true; }

cat > "$p" <<'EOF'
sum(a)
    i = 0
    s = 0
    loop i < len(a)
        s = s + a[i]
        i = i + 1
    return s
b = array(3)
b[0] = 1
b[1] = 2
b[2] = 4
out(sum(b))
EOF
if [ "$("$WORD" run "$p" 2>&1)" = "7" ]; then ok "an elided loop still sums the region"
else bad "an elided loop still sums the region" "7"; fi
if [ "$(bc_count "$p")" = "0" ]; then ok "a[i] under its own guard checks nothing"
else bad "a[i] under its own guard" "expected no jae rt_boundsidx, got $(bc_count "$p")"; fi

# The shapes that must keep the check. Each is a real out-of-range read away
# from the shape above, so each is spelled out rather than trusted.
for shape in 'increment first' 'not strictly less' 'a parameter index' 'decremented somewhere' 'index set from a call' 'another region, same index' 'the guarded region, another index'; do
  case "$shape" in
    'increment first') cat > "$p" <<'EOF'
f(a)
    i = 0
    s = 0
    loop i < len(a)
        i = i + 1
        s = s + a[i]
    return s
out(f(array(3)))
EOF
;;
    'not strictly less') cat > "$p" <<'EOF'
f(a)
    i = 0
    s = 0
    loop i <= len(a)
        s = s + a[i]
        i = i + 1
    return s
out(f(array(3)))
EOF
;;
    'a parameter index') cat > "$p" <<'EOF'
f(a, i)
    s = 0
    loop i < len(a)
        s = s + a[i]
        i = i + 1
    return s
out(f(array(3), 0))
EOF
;;
    'decremented somewhere') cat > "$p" <<'EOF'
f(a, z)
    i = 0
    s = 0
    if z > 0
        i = i - 1
    loop i < len(a)
        s = s + a[i]
        i = i + 1
    return s
out(f(array(3), 0))
EOF
;;
    'index set from a call') cat > "$p" <<'EOF'
g()
    return 0 - 1
f(a)
    i = g()
    s = 0
    loop i < len(a)
        s = s + a[i]
        i = i + 1
    return s
out(f(array(3)))
EOF
;;
    'another region, same index') cat > "$p" <<'EOF'
f(a, b)
    i = 0
    s = 0
    loop i < len(a)
        s = s + b[i]
        i = i + 1
    return s
out(f(array(4), array(2)))
EOF
;;
    'the guarded region, another index') cat > "$p" <<'EOF'
f(a, j)
    i = 0
    s = 0
    loop i < len(a)
        s = s + a[j]
        j = j + 1
        i = i + 1
    return s
out(f(array(3), 1))
EOF
;;
  esac
  if [ "$(bc_count "$p")" != "0" ]; then ok "the check stays: $shape"
  else bad "the check stays: $shape" "the bounds check was elided"; fi
done

# The read past the end still faults, at the right line.
cdie "incrementing first still faults on the read" "index 3 out of bounds" 70 <<'EOF'
f(a)
    i = 0
    s = 0
    loop i < len(a)
        i = i + 1
        s = s + a[i]
    return s
out(f(array(3)))
EOF
cdie "i <= len(a) still faults" "index 3 out of bounds" 70 <<'EOF'
f(a)
    i = 0
    s = 0
    loop i <= len(a)
        s = s + a[i]
        i = i + 1
    return s
out(f(array(3)))
EOF
# An increment nested inside an `if` counts as one: the statement after it can
# no longer rely on the guard, whichever way the branch went.
cdie "an increment inside an if ends the fact" "index 3 out of bounds" 70 <<'EOF'
f(a, z)
    i = 0
    s = 0
    loop i < len(a)
        if z > 0
            i = i + 1
        s = s + a[i]
        i = i + 1
    return s
out(f(array(3), 1))
EOF

# The guard proves one (region, index) pair, and nothing about any other pair in
# the same body. Both halves are spelled out as faults instead of counts,
# because a dropped bounds check can't be seen in a program that stays in range.
# That's how `index_elidable(...) == 0` got through: the answer is a boolean,
# `false == 0` is false, and every subscript the guard didn't cover lost its
# check.
cdie "a second region under the guard still faults" "index 2 out of bounds" 70 <<'EOF'
f(a, b)
    i = 0
    s = 0
    loop i < len(a)
        s = s + b[i]
        i = i + 1
    return s
out(f(array(4), array(2)))
EOF
cdie "the guarded region under another index still faults" "index 3 out of bounds" 70 <<'EOF'
f(a, j)
    i = 0
    s = 0
    loop i < len(a)
        s = s + a[j]
        j = j + 1
        i = i + 1
    return s
out(f(array(3), 1))
EOF

# A store under the guard is elided on the same terms, and a byte-backed
# subject reads through the subkind branch that sits after the check.
crun "a store under its own guard" "7|7|7" <<'EOF'
fill(a)
    i = 0
    loop i < len(a)
        a[i] = 7
        i = i + 1
    return a
b = fill(array(3))
out(b[0] . "|" . b[1] . "|" . b[2])
EOF
crun "a byte-backed subject walks the same way" "14" <<'EOF'
sum(a)
    i = 0
    s = 0
    loop i < len(a)
        s = s + a[i]
        i = i + 1
    return s
b = bytes(4)
b[0] = 9
b[3] = 5
out(sum(b))
EOF
# A map has a len() too, and m[i] with an integer key is a map read, not a
# region read, so the elision must not put it on the region path.
cdie "a map subject is still a map read" "region expected" 70 <<'EOF'
sum(a)
    i = 0
    s = 0
    loop i < len(a)
        s = s + a[i]
        i = i + 1
    return s
out(sum({x: 1}))
EOF
# Nested loops over the same region, each with its own counter.
crun "nested loops each get their own fact" "36" <<'EOF'
sq(a)
    i = 0
    t = 0
    loop i < len(a)
        j = 0
        loop j < len(a)
            t = t + a[i] + a[j]
            j = j + 1
        i = i + 1
    return t
b = array(3)
b[0] = 1
b[1] = 2
b[2] = 3
out(sq(b))
EOF
# The length can only grow while the loop runs (an in-place append raises it,
# and nothing lowers it), so a body that appends through another name is fine.
# A region that starts empty enters no iteration.
crun "an empty region enters no iteration" "0" <<'EOF'
sum(a)
    i = 0
    s = 0
    loop i < len(a)
        s = s + a[i]
        i = i + 1
    return s
out(sum(array(0)))
EOF

# --- the line a fault reports, across a call --------------------------------
#
# Every function stores its own line, so on return `cur_line` holds whatever
# the callee last executed. A statement that calls and then faults used to
# report a line inside a function that had already returned. The line is put
# back after a call, but only in a statement where something after the call can
# still fault, which is also what decides whether a statement needs its line
# stored at all.
cdie "an overflow after a call names the caller" "p.w:5: integer overflow" 70 <<'EOF'
big()
    y = 2
    return y
f(a)
    return a + big() + a
out(f(2305843009213693951))
EOF
cdie "a divide by zero after a call names the caller" "p.w:5: divide by zero" 70 <<'EOF'
one()
    z = 1
    return z
f(a)
    return a / (one() - 1)
out(f(10))
EOF
cdie "a bad index after a call names the caller" "p.w:5: index 99" 70 <<'EOF'
far()
    z = 99
    return z
f(a)
    return a[far()]
out(f(array(3)))
EOF
# The callee's own fault still names the callee: putting the line back must not
# reach backwards.
cdie "a fault inside the callee still names the callee" "p.w:3: divide by zero" 70 <<'EOF'
bad(n)
    m = n - 1
    return 7 / m
f(a)
    return a + bad(1)
out(f(2))
EOF
# Two calls in one statement: the second one's prologue and the operator after
# it both have to see the caller's line.
cdie "the last call in a statement is covered too" "p.w:8: integer overflow" 70 <<'EOF'
big()
    y = 2305843009213693951
    return y
huge()
    y = 2305843009213693951
    return y
f(a)
    return a + big() + huge()
out(f(2))
EOF
# And a fault with no call in front of it is unchanged.
cdie "a fault with no call in front is unchanged" "p.w:3: integer overflow" 70 <<'EOF'
a = 2305843009213693951
b = 2305843009213693951
out(a + b + b)
EOF

# A statement that can't fault (a literal or a plain local read into a local)
# needs no line store, because it can never produce a located message.
cat > "$p" <<'EOF'
f(q)
    x = 5
    y = x
    z = y
    return z + q
out(f(1))
EOF
# Three stores: `return z + q`, the `out(f(1))` statement, and the one put back
# after `call fn_f` because `out` can still fault. The three that cannot
# (`x = 5`, `y = x`, `z = y`) store nothing. They are counted from the first
# function on, past the runtime, whose rt_init stores line 1 before any
# statement runs.
lnst() { "$WORD" build -asm "$1" 2>/dev/null | awk '/^fn_/ { f = 1 } f' | grep -c 'mov qword ptr \[rip+cur_line\]'; }
if [ "$(lnst "$p")" = "3" ]; then
  ok "a statement that cannot fault stores no line"
else
  bad "a statement that cannot fault stores no line" "expected 3 line stores, got $(lnst "$p")"
fi
# One that can fault still stores its line.
cat > "$p" <<'EOF'
f(q)
    x = q + 1
    return x
out(f(1))
EOF
if [ "$(lnst "$p")" -ge 3 ]; then
  ok "a statement that can fault still stores its line"
else
  bad "a statement that can fault still stores its line" "the store went missing"
fi

# --- the line a condition's fault reports -----------------------------------
#
# The truth test after `if x`, `else if x` and `loop x` can fault by itself.
# When the condition was a plain local there was nothing else in it that could,
# so the statement stored no line and a null there was reported on whichever
# line was stored last. A loop's test also runs again on every later pass,
# after the body has stored lines of its own.
cdie "if on a null local names the if" "p.w:6: a condition must be true or false" 70 <<'EOF'
hide(x)
    return x
x = hide(null)
out("a")
out("b")
if x
    out("yes")
EOF
cdie "else if on a none local names the else if" "p.w:9: a condition must be true or false" 70 <<'EOF'
hide(x)
    return x
i = 0
loop i < 3
    i = i + 1
    x = hide(none)
    if i == 1
        out(i)
    else if x
        out("y")
EOF
cdie "loop on a local names the loop" "p.w:5: a condition must be true or false" 70 <<'EOF'
hide(x)
    return x
n = hide("s")
out("a")
loop n
    break
EOF
cdie "if inside a function names its own line" "p.w:3: a condition must be true or false" 70 <<'EOF'
check(v)
    out("in check")
    if v
        return 1
    return 0
out(check(5))
EOF
cdie "if on a call names the if, not the callee" "p.w:4: a condition must be true or false" 70 <<'EOF'
f(v)
    out("in f")
    return v
if f(null)
    out("yes")
EOF
cdie "a loop test that faults on a later pass names the loop" "p.w:3: index 2 out of bounds" 70 <<'EOF'
s = "ab"
i = 0
loop s[i] != 0
    out(i)
    i = i + 1
EOF
cdie "and so does a local the body sets to null" "p.w:4: a condition must be true or false" 70 <<'EOF'
hide(x)
    return x
x = true
loop x
    out("a")
    x = hide(null)
EOF
cdie "and a call that answers none on a later pass" "p.w:8: a condition must be true or false" 70 <<'EOF'
f(v)
    out("in f")
    return v
hide(x)
    return x
x = true
n = 0
loop f(x)
    n = n + 1
    out(n)
    x = hide(none)
EOF
cdie "a local that is true on one path and null on another faults where it is tested" "p.w:6: a condition must be true or false" 70 <<'EOF'
ready()
    return true
x = true
if ready()
    x = null
if x
    out("y")
EOF
cdie "a comparison the body breaks on a later pass names the loop" "p.w:5: cannot order-compare a number and text" 70 <<'EOF'
hide(x)
    return x
lim = 3
i = 0
loop i < lim
    i = i + 1
    lim = hide("x")
EOF

# The loop's line goes back at the top of a pass only when the test can fault
# on a later pass where it didn't on the first, and that takes a body that
# changes something the test reads. A counted loop's test compares numbers, a
# hoisted len() runs once, a call to one of the program's functions puts the
# line back after itself, an inlined accessor reads a list the body doesn't
# reassign, and a parameter compared with a counter stays what it was. So none
# of these five loops stores a line per pass, and the two after them do. The
# count is the same on arm64, which has no hoisted len().
lntop() { lt_x=$("$WORD" build -asm "$1" 2>/dev/null | awk '/\.align 16/{a=1;next} a==1&&/:$/{a=2;next} a==2{ if ($0 ~ /rip\+cur_line\]/) c++; a=0 } END{print c+0}')
  lt_a=$("$WORD" build -arm64 -asm "$1" 2>/dev/null | awk '/\.align 16/{a=1;next} a==1&&/:$/{a=2;n=0;next} a==2{ n++; if ($0 ~ /cur_line/) { c++; a=0 } else if (n >= 3) a=0 } END{print c+0}')
  if [ "$lt_x" = "$lt_a" ]; then echo "$lt_x"; else echo "x86-64 $lt_x, arm64 $lt_a"; fi; }
cat > "$p" <<'EOF'
cnt(xs)
    n = len(xs)
    return n
first(xs)
    return xs[0]
upto(n)
    u = 0
    loop u < n
        u = u + 1
    return u
xs = array(3)
i = 0
loop i < 10
    i = i + 1
j = 0
loop j < len(xs)
    j = j + 1
k = 0
loop k < cnt(xs)
    k = k + 1
m = 0
loop m < first(xs)
    m = m + 1
out(i + j + k + m + upto(4))
EOF
if [ "$(lntop "$p")" = "0" ]; then
  ok "a loop whose test cannot fault on a later pass stores no line per pass"
else
  bad "a loop whose test cannot fault on a later pass stores no line per pass" "got $(lntop "$p") stores at a loop head"
fi
cat > "$p" <<'EOF'
hide(x)
    return x
s = "ab"
i = 0
loop s[i] != 0
    i = i + 1
x = true
loop x
    x = hide(false)
out(i)
EOF
if [ "$(lntop "$p")" = "2" ]; then
  ok "a loop whose test can fault on a later pass stores its line per pass"
else
  bad "a loop whose test can fault on a later pass stores its line per pass" "got $(lntop "$p") stores at a loop head"
fi

# --- copy(s, j, j + w) is the width the caller already wrote ---------------
#
# The end-index spelling shouldn't cost an add to build the end and a subtract
# to take it apart again. When the end is the start plus something, that
# something is the count rt_copy takes.
crun "a fixed-width window, either way round" "3|2|4|3|2" <<'EOF'
s = text(10)
i = 0
loop i < 10
    s[i] = i
    i = i + 1
j = 2
w = 3
t = copy(s, j, j + w)
u = copy(s, j, w + j)
out(len(t) . "|" . t[0] . "|" . t[2] . "|" . len(u) . "|" . u[0])
EOF
cat > "$p" <<'EOF'
s = text(10)
j = 2
w = 3
t = copy(s, j, j + w)
out(len(t))
EOF
if "$WORD" build -asm "$p" 2>/dev/null | awk '/^fn__toplevel:/{f=1} f' | grep -q -e 'sub rdx, rsi' -e 'call rt_copyrange'; then
  bad "copy(s, j, j + w) skips the end/count round trip" "no sub rdx, rsi and no call rt_copyrange"
else
  ok "copy(s, j, j + w) skips the end/count round trip"
fi
# A general end index goes to rt_copyrange, which checks it is a whole number
# and converts it to the count rt_copy takes.
cat > "$p" <<'EOF'
s = text(10)
j = 2
k = 5
t = copy(s, j, k)
out(len(t))
EOF
if "$WORD" build -asm "$p" 2>/dev/null | awk '/^fn__toplevel:/{f=1} f' | grep -q 'call rt_copyrange'; then
  ok "an unrelated end index still converts to a count"
else
  bad "an unrelated end index still converts to a count" "call rt_copyrange"
fi

# --- an index is a compare and a test, with nothing staged in a register ------
#
# The bound and the subkind flag are both memory the check can read directly.
# They used to be loaded into r11 first, which cost an instruction each on the
# operation the language runs most. The fault path reads the length itself now,
# since that path is already on its way out.
# A region whose shape the subkind pass can't pin down: the function returns a
# byte-backed region on one path and a word-backed one on the other, so the join
# is "nothing known" and the access keeps its full dispatch. These two check
# how that dispatch is encoded.
cat > "$p" <<'EOF'
mk(n)
    if n == 1
        return text(4)
    return bytes(4)
a = mk(1)
a[1] = 9
out(a[1])
EOF
asm=$("$WORD" build -asm "$p" 2>/dev/null | awk '/^fn__toplevel:/{f=1} f')
if printf '%s' "$asm" | grep -q 'cmp rcx, \[rax\]'; then
  ok "the bound is the compare's memory operand"
else
  bad "the bound is the compare's memory operand" "cmp rcx, [rax]"
fi
if printf '%s' "$asm" | grep -q 'test qword ptr \[rax - 16\], 1'; then
  ok "the subkind flag is the test's memory operand"
else
  bad "the subkind flag is the test's memory operand" "test qword ptr [rax - 16], 1"
fi

# When the pass can see the shape, none of that is emitted: a region allocated
# right here is byte- or word-backed by construction and can't be a literal, so
# the dispatch, the write guard and one of the two store forms all go. That was
# most of the size of a crypto inner loop.
cat > "$p" <<'EOF'
a = text(4)
a[1] = 9
b = bytes(4)
b[2] = 7
out(a[1] + b[2])
EOF
asm=$("$WORD" build -asm "$p" 2>/dev/null | awk '/^fn__toplevel:/{f=1} f')
if printf '%s' "$asm" | grep -q 'test qword ptr \[rax - 16\], 1'; then
  bad "a known subkind needs no dispatch" "the flag test is still emitted"
else
  ok "a known subkind needs no dispatch"
fi
if printf '%s' "$asm" | grep -q 'cmp rax, \[rip+litpool_top\]'; then
  bad "a freshly allocated region needs no write guard" "litpool_top is still compared"
else
  ok "a freshly allocated region needs no write guard"
fi
# A literal index into a length written in the source is decided at compile
# time too, so the bound goes with the rest and the element is a displacement.
if printf '%s' "$asm" | grep -q 'jae rt_boundsidx'; then
  bad "a literal index into a known length needs no bound" "the check is still emitted"
else
  ok "a literal index into a known length needs no bound"
fi
# A variable index still gets its check, since nothing here proves it's in range.
cat > "$p" <<'EOF'
a = text(4)
i = 0
loop i < 4
    a[i] = i
    i = i + 1
out(a[3])
EOF
asmv=$("$WORD" build -asm "$p" 2>/dev/null | awk '/^fn__toplevel:/{f=1} f')
if printf '%s' "$asmv" | grep -q 'jae rt_boundsidx'; then
  ok "a variable index still gets its bounds check"
else
  bad "a variable index still gets its bounds check" "it was elided"
fi
if printf '%s' "$asm" | grep -q 'mov r11, \[rax'; then
  bad "nothing is staged in r11 for an index" "no mov r11, [rax...]"
else
  ok "nothing is staged in r11 for an index"
fi
# The message still gives the length, which is why the load has to happen
# somewhere.
cat > "$p" <<'EOF'
a = text(4)
out(a[7])
EOF
if "$WORD" run "$p" 2>&1 | grep -q 'index 7 out of bounds for a region of length 4'; then
  ok "the fault still names both numbers"
else
  bad "the fault still names both numbers" "index 7 out of bounds for a region of length 4"
fi

# --- a global the check reads is the check's memory operand --------------------
#
# Same argument as the index bound above, for the two guards every program pays:
# the stack-overflow check on entry to a function, and the write-to-a-literal
# check on an index store. Both compared against a global that was loaded into a
# scratch register first.
cat > "$p" <<'EOF'
f(n)
    return n + 1
mk2(n)
    if n == 1
        return text(2)
    return bytes(2)
a = mk2(1)
a[0] = f(1)
out(a[0])
EOF
asm=$("$WORD" build -asm "$p" 2>/dev/null)
if printf '%s' "$asm" | grep -q 'cmp rsp, \[rip+stack_limit\]'; then
  ok "a function prologue compares rsp against the limit directly"
else
  bad "a function prologue compares rsp against the limit directly" "cmp rsp, [rip+stack_limit]"
fi
if printf '%s' "$asm" | grep -q 'cmp rax, \[rip+litpool_top\]'; then
  ok "an index store compares against litpool_top directly"
else
  bad "an index store compares against litpool_top directly" "cmp rax, [rip+litpool_top]"
fi
# Both guards still fire.
cat > "$p" <<'EOF'
s = "abc"
s[0] = 90
EOF
if "$WORD" run "$p" 2>&1 | grep -q 'write to a literal'; then
  ok "the literal guard still fires"
else
  bad "the literal guard still fires" "write to a literal"
fi
cat > "$p" <<'EOF'
deep(n)
    return deep(n + 1)
out(deep(0))
EOF
if "$WORD" run "$p" 2>&1 | grep -qi 'stack'; then
  ok "the stack guard still fires"
else
  bad "the stack guard still fires" "a stack overflow message"
fi

# --- a built program names its source file, not the machine it was built on ---
#
# The fault prefix embeds the source name so a run-time failure looks like a
# compile error. It used to embed the whole path it was compiled from, which put
# the build directory (a username, a checkout layout, sometimes a CI token in
# the path) inside every binary.
mkdir -p "$tmp/deep/nested"
cat > "$tmp/deep/nested/prog.w" <<'EOF'
a = text(2)
out(a[9])
EOF
"$WORD" build "$tmp/deep/nested/prog.w" -o "$tmp/prog.bin" 2>/dev/null
if "$tmp/prog.bin" 2>&1 | grep -q '^prog.w:2: index 9 out of bounds'; then
  ok "a fault names the source file"
else
  bad "a fault names the source file" "prog.w:2: index 9 out of bounds"
fi
if strings -a "$tmp/prog.bin" 2>/dev/null | grep -q "$tmp/deep/nested"; then
  bad "the build path is not in the binary" "no build directory in the image"
else
  ok "the build path is not in the binary"
fi

# --- copy(p): the whole region ---------------------------------------------
#
# Regions are references, so `t = p` makes two names for one region, and this
# is the spelling that gives you your own. It used to be `slice(p, 0, len(p))`,
# which said how instead of what, and in Go and Rust a slice is a view that
# aliases, which this never was.
crun "copy(p) is independent of p" "hello Jello" <<'EOF'
s = "hello"
t = copy(s)
t[0] = 74
out(s . " " . t)
EOF
crun "a bare assignment still aliases, which is what copy() is for" "Jello Jello" <<'EOF'
s = "hello" . ""
t = s
t[0] = 74
out(s . " " . t)
EOF
crun "copy(p) keeps the length and the elements" "5|0|40" <<'EOF'
a = text(5)
i = 0
loop i < 5
    a[i] = i * 10
    i = i + 1
b = copy(a)
out(len(b) . "|" . b[0] . "|" . b[4])
EOF
crun "copy of an empty region is empty" "0" <<'EOF'
out(len(copy(text(0))))
EOF
# Subkinds carry through the no-bounds form exactly as through the ranged one.
crun "copy of a JSON array is a JSON array" "[7,0,0]|array" <<'EOF'
a = array(3)
a[0] = 7
b = copy(a)
out(b . "|" . kind(b))
EOF
crun "copy(p) and copy(p, 0, len(p)) agree" "true" <<'EOF'
s = "abcdef"
out(copy(s) == copy(s, 0, len(s)))
EOF
cerr "copy() of a number is caught at compile time" "needs a region" <<'EOF'
out(copy(5))
EOF
cerr "copy() takes one, two or three arguments" "'copy' takes a region or map" <<'EOF'
a = text(2)
out(copy(a, 0, 1, 2))
EOF
cerr "slice() is gone" "call to undefined function 'slice'" <<'EOF'
out(slice("abc", 0, 2))
EOF

# --- copy(m): a map is a reference too -------------------------------------
#
# copy() is there because `t = p` makes two names for one thing. That's as
# true of a map as of a region, so copy() takes either.
crun "copy(m) is independent of m" '{"a":1,"b":2,"c":3}|{"a":99,"b":2,"c":3,"d":4}' <<'EOF'
m = {a: 1, b: 2, c: 3}
n = copy(m)
n["a"] = 99
n["d"] = 4
out(m . "|" . n)
EOF
crun "a copied map keeps insertion order and answers has()" "3|4|false|true" <<'EOF'
m = {a: 1, b: 2, c: 3}
n = copy(m)
n["d"] = 4
out(len(keys(m)) . "|" . len(keys(n)) . "|" . has(m, "d") . "|" . has(n, "d"))
EOF
crun "a copied map is still a map to index" "1" <<'EOF'
m = {a: 1}
n = copy(m)
out(n["a"])
EOF
# Shallow, as copy() of a region is: the words are copied, so a value that is
# itself a region is shared.
crun "copy(m) is shallow, like copy of a region" "77" <<'EOF'
inner = text(2)
inner[0] = 5
m = {v: inner}
n = copy(m)
inner[0] = 77
out(n["v"][0])
EOF
crun "kind() of a copied map is still a map" "map" <<'EOF'
out(kind(copy({a: 1})))
EOF
# A ranged copy of a map means nothing and faults, and the message has to say
# what it got. It said "number" for a map until rt_regfault started reading the
# tag the check had already computed.
cdie "a ranged copy of a map says map" "region expected, got a map" 70 <<'EOF'
m = {a: 1}
out(len(copy(m, 0, 2)))
EOF
cdie "copy(m, start) says map too" "region expected, got a map" 70 <<'EOF'
m = {a: 1}
out(len(copy(m, 1)))
EOF
cdie "a ranged copy of a number still says number" "region expected, got a number" 70 <<'EOF'
id(v)
    return v
out(len(copy(id(5), 0, 2)))
EOF
# A float is a number to kind(), so it is a number here.
cdie "a ranged copy of a float says number" "region expected, got a number" 70 <<'EOF'
id(v)
    return v
out(len(copy(id(1.5), 0, 2)))
EOF
cdie "encode of a map says map" "region expected, got a map" 70 <<'EOF'
import txt
m = {a: 1}
out(encode(m))
EOF
cdie "decode of a map says map" "region expected, got a map" 70 <<'EOF'
import txt
m = {a: 1}
out(decode(m))
EOF
cdie "pad of a map says map" "region expected, got a map" 70 <<'EOF'
import txt
m = {a: 1}
out(pad(m, 5, 32))
EOF
# The generic region check (`loop v in m`) reaches rt_regfault from the other
# direction, through regcheck instead of a runtime entry.
cdie "iterating a map says map" "region expected, got a map" 70 <<'EOF'
f(y)
    loop v in y
        out(v)
f({a: 1})
EOF

# --- copy(p, start): from there to the end ---------------------------------
crun "copy(p, start) runs to the end" "cdef" <<'EOF'
out(copy("abcdef", 2))
EOF
crun "copy(p, 0) is the whole region" "abcdef|true" <<'EOF'
s = "abcdef"
out(copy(s, 0) . "|" . (copy(s, 0) == copy(s)))
EOF
crun "copy(p, len(p)) is empty" "0" <<'EOF'
s = "abcdef"
out(len(copy(s, len(s))))
EOF
crun "copy(p, start) on an array keeps the elements" "2|3|4" <<'EOF'
a = text(5)
i = 0
loop i < 5
    a[i] = i
    i = i + 1
b = copy(a, 3)
out(len(b) . "|" . b[0] . "|" . b[1])
EOF
cdie "a start past the end still faults" "index out of bounds" 70 <<'EOF'
out(copy("abc", 9))
EOF

echo "== a one-line accessor is substituted at the call site =="
# `f(x) = return <expr>` is inlined into its callers before any analysis runs.
# The value has to be the same; the conditions that decline it are what the rest
# of this block is about, because each one is a way to get a different program.
crun "a one-line accessor gives the same answer" "3 30 7" <<'EOF'
count(l)
    return l[0]
at(l, i)
    return l[i + 1]
main()
    l = array(4)
    l[0] = 3
    l[1] = 10
    l[2] = 20
    l[3] = 30
    out(count(l) . " " . at(l, 2) . " " . (at(l, 0) + at(l, 1) - 23))
    return 0
main()
EOF
# The bug this test exists for: with the parameter never read, substituting
# drops the argument, and with it the bounds check it was supposed to perform.
cdie "an argument the body ignores is still evaluated" "index 99 out of bounds for a region of length 3" 70 <<'EOF'
ignore(x)
    return 7
main()
    a = array(3)
    out(ignore(a[99]))
    return 0
main()
EOF
cdie "and so is one that would divide by zero" "divide by zero" 70 <<'EOF'
ignore(x)
    return 7
main()
    z = 0
    out(ignore(5 / z))
    return 0
main()
EOF
crun "a name or a literal may be dropped" "7 7" <<'EOF'
ignore(x)
    return 7
main()
    a = 5
    out(ignore(a) . " " . ignore(1))
    return 0
main()
EOF
# An argument that calls something is never substituted, so its effect happens
# once, in the order the call already used, which is right to left, as it was
# before any of this.
crun "a call argument keeps its effect and its order" "b
a
12" <<'EOF'
shout(s)
    out(s)
    return 1
add(x, y)
    return x + y
main()
    out(add(shout("a") * 10, shout("b") * 2))
    return 0
main()
EOF
crun "a two-statement body is not touched" "9" <<'EOF'
two(x)
    y = x + 4
    return y
main()
    out(two(5))
    return 0
main()
EOF
crun "a parameter read twice, from a name, is substituted and answers the same" "25" <<'EOF'
sq(x)
    return x * x
main()
    n = 5
    out(sq(n))
    return 0
main()
EOF
# A one-liner whose body calls something isn't substituted (that keeps a chain
# of them from growing the tree), but the inner call still is, and the answer is
# the same either way.
crun "a one-liner whose body calls is left alone" "42" <<'EOF'
inner(x)
    return x + 2
outer(x)
    return inner(x) * 2
main()
    out(outer(19))
    return 0
main()
EOF
crun "recursion in a one-liner terminates the substitution" "1" <<'EOF'
down(n)
    return n
main()
    out(down(1))
    return 0
main()
EOF
# The one visible change besides speed: a fault inside the substituted
# expression names the line that asked, not the accessor's own line.
cdie "a fault in an inlined accessor names the caller" "p.w:7: index 9 out of bounds" 70 <<'EOF'
at(l, i)
    return l[i + 1]
main()
    l = array(2)
    l[0] = 1
    l[1] = 2
    out(at(l, 8))
    return 0
main()
EOF
# Calls from top-level code are substituted too, so the same holds there.
cdie "and so does one called from top-level code" "p.w:4: index 9 out of bounds" 70 <<'EOF'
at(l, i)
    return l[i + 1]
l = array(2)
out(at(l, 8))
EOF
# A parameter read twice is substituted when its argument is a name, which
# reads the same value both times: the overflow in x * x is the caller's line.
cdie "a one-liner reading its parameter twice is substituted for a name" "p.w:4: integer overflow" 70 <<'EOF'
sq(x)
    return x * x
v = 3037000500
out(sq(v))
EOF
# ...and not when the argument is an index, which substituting would read
# twice: that stays a call, and the fault is the accessor's line.
cdie "but not for an index, which would be read twice" "p.w:2: integer overflow" 70 <<'EOF'
sq(x)
    return x * x
a = array(1)
a[0] = 3037000500
out(sq(a[0]))
EOF

echo
echo "== the command line and the program have no limits nobody wrote down =="
# `word run` handed a program its arguments through a 64-entry list and faulted
# inside the compiler (word.w: index 65 out of bounds) on the 65th. An empty
# argument ended that list, so everything after it vanished. Behind the list,
# exec laid the arguments out in 64 KB and 256 pointers and never checked
# either. `word asm` had the same list, at 16 files.
printf 'a = args()\nout(len(a) . " " . a[1] . "|" . a[len(a) - 2] . "|" . a[len(a) - 1])\n' > "$tmp/argv.w"
got=$($TO "$WORD" run "$tmp/argv.w" $(awk 'BEGIN{for(i=1;i<=300;i++) printf "%d ", i}') 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$got" = "301 1|299|300" ]; then ok "word run passes 300 arguments"
else bad "word run passes 300 arguments" "got [$got] rc=$rc"; fi

got=$($TO "$WORD" run "$tmp/argv.w" first "" "" last 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$got" = "5 first||last" ]; then ok "an empty argument is passed, and so is everything after it"
else bad "an empty argument is passed, and so is everything after it" "got [$got] rc=$rc"; fi

# Windows caps a whole command line at 32,767 characters, so there these two
# ask for what fits under it: 30 KB in two arguments, and 250 arguments.
bigl=100000; nargs=3000
biglabel="200 KB of argument text arrives whole"; nlabel="3000 arguments of 100 bytes each"
if [ "$win" = 1 ]; then
  bigl=15000; nargs=250
  biglabel="30 KB of argument text arrives whole (a Windows command line holds 32 KB)"
  nlabel="250 arguments of 100 bytes each (a Windows command line holds 32 KB)"
fi
big=$(awk -v m="$bigl" 'BEGIN{while(n<m){printf "x";n++}}')
got=$($TO "$WORD" run "$tmp/argv.w" "$big" "$big" 2>&1 | awk '{print length($0)}'); rc=$?
if [ "$got" = "$((bigl * 3 + 4))" ]; then ok "$biglabel"
else bad "$biglabel" "got [$got]"; fi

got=$($TO "$WORD" run "$tmp/argv.w" $(awk -v m="$nargs" 'BEGIN{for(i=1;i<=m;i++) printf "a%099d ", i}') 2>&1 | awk '{print $1}')
if [ "$got" = "$((nargs + 1))" ]; then ok "$nlabel"
else bad "$nlabel" "got [$got]"; fi

printf '.global _start\n_start:\n    mov rax, 60\n    xor rdi, rdi\n    syscall\n' > "$tmp/asm0.s"
files=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19; do
  printf '    nop\n' > "$tmp/asm$i.s"; files="$files $tmp/asm$i.s"
done
if "$WORD" asm -linux "$tmp/asm0.s" $files "$tmp/asm20" >"$tmp/asmerr" 2>&1 \
   && if [ "$win" = 1 ]; then is_elf "$tmp/asm20"; else $TO "$tmp/asm20"; fi; then
  ok "word asm takes 20 input files$elfnote"
else bad "word asm takes 20 input files" "$(head -2 "$tmp/asmerr")"; fi
cli "word asm names an input it cannot read" "word asm: cannot read" 1 asm "$tmp/no_such_input.s" "$tmp/asmout"

printf 'out(7)\n' > "$tmp/o.w"
rm -f "$tmp/o_after_empty"
"$WORD" build "$tmp/o.w" "" -o "$tmp/o_after_empty" >/dev/null 2>&1
if [ -x "$tmp/o_after_empty" ]; then ok "build: -o after an empty argument is still read"
else bad "build: -o after an empty argument is still read" "no output at $tmp/o_after_empty"; fi

# Every list the compiler fills from the program grows. Each of these reached a
# fixed capacity and faulted inside the compiler instead of compiling.
#
# These used to be written `awk ... | crun`, and a case on the right of a pipe
# runs in a subshell, where `fail=$((fail+1))` is lost when the subshell exits.
# Such a case printed FAIL and the suite still said "0 failed" and exited 0, so
# the five generated cases in this section, every compiler limit this file
# checks, couldn't fail it, and a real regression got past them. The program
# goes through a file now, so the helper runs in this shell.
gen="$tmp/gen.w"
awk 'BEGIN{for(i=1;i<=70;i++) printf "f%d(x)\n    return x\n\n", i
  printf "f1:before"; for(i=2;i<=70;i++) printf ", f%d:before", i
  printf "\n    return x > 0\n\nout(f70(3))\n"}' > "$gen"
crun "one hook shared by 70 functions" "3" < "$gen"

awk 'BEGIN{for(i=1;i<=40;i++) printf "import sys\nimport fs\n"; printf "out(1)\n"}' > "$gen"
crun "80 import lines" "1" < "$gen"

got=$(awk 'BEGIN{for(i=1;i<=9000;i++) printf "out(%d)\n", i}' > "$p"; "$WORD" build "$p" -o "$exe" 2>&1 && "$exe" | tail -1)
if [ "$got" = "9000" ]; then ok "9000 top-level statements"; else bad "9000 top-level statements" "got [$got]"; fi

awk 'BEGIN{for(i=1;i<9000;i++) printf "g%d()\n    return g%d()\n\n", i, i+1
  printf "g9000()\n    return 9000\n\nout(g1())\n"}' > "$gen"
crun "9000 functions" "9000" < "$gen"

# 4100 functions under one hook: past the hook tables (4096) and the list of
# contract names (256) at once. A hooked function counts as used.
awk 'BEGIN{for(i=1;i<=4100;i++) printf "h%d(x)\n    return x\n\n", i
  printf "h1:before"; for(i=2;i<=4100;i++) printf ", h%d:before", i
  printf "\n    return x > 0\n\nout(h4100(5))\n"}' > "$gen"
crun "4100 functions sharing one hook" "5" < "$gen"

awk 'BEGIN{printf "x = 0\n"; for(i=0;i<300;i++){for(j=0;j<i;j++) printf "    "; printf "if x == 0\n"}
  for(j=0;j<300;j++) printf "    "; printf "out(\"deep\")\n"}' > "$gen"
crun "300 levels of nesting" "deep" < "$gen"

# Nesting is the one the compiler couldn't survive. The parser is recursive
# descent, the analyzer and the code generator walk the same tree the same way,
# and nothing bounded any of them: 10,000 nested parentheses ran the compiler
# off the end of its own stack and printed `word.w:877: stack exhausted`, a
# run-time fault with exit 70, reported against a line of the compiler's own
# source. test_fuzz_frontend.sh counts that as a bug, since arbitrary input has
# two acceptable outcomes: compiled, or refused with a located diagnostic.
#
# SPEC 10.1 sets three limits, because each shape costs a different amount of
# the compiler's stack per level: a level of expression about eleven frames, a
# level of block about two. The third, an operator chain, is tested in
# test_compile_limits.sh. Every shape that recurses is checked here at 10,000,
# the depth that faulted, and each must come back as a located diagnostic on
# stderr, exit 1 and nothing on stdout, which is what cerr checks.
deep_expr() { awk "$2" > "$gen"; cerr "$1" "expression nests too deeply" < "$gen"; }

deep_expr "10,000 nested parentheses" 'BEGIN{s="out("; for(i=0;i<10000;i++) s=s "("; s=s "1"; for(i=0;i<10000;i++) s=s ")"; print s ")"}'
deep_expr "10,000 nested calls" 'BEGIN{print "id(x)"; print "    return x"; print ""; s="out("; for(i=0;i<10000;i++) s=s "id("; s=s "1"; for(i=0;i<10000;i++) s=s ")"; print s ")"}'
deep_expr "10,000 right-nested binary operators" 'BEGIN{s="out("; for(i=0;i<10000;i++) s=s "1 + ("; s=s "1"; for(i=0;i<10000;i++) s=s ")"; print s ")"}'
deep_expr "10,000 nested subscripts" 'BEGIN{print "a = array(1)"; s="out("; for(i=0;i<10000;i++) s=s "a["; s=s "0"; for(i=0;i<10000;i++) s=s "]"; print s ")"}'
deep_expr "10,000 nested array literals" 'BEGIN{s="out(len("; for(i=0;i<10000;i++) s=s "array("; s=s "1"; for(i=0;i<10000;i++) s=s ")"; print s "))"}'
deep_expr "10,000 nested map literals" 'BEGIN{s="out("; for(i=0;i<10000;i++) s=s "{a: "; s=s "1"; for(i=0;i<10000;i++) s=s "}"; print s ")"}'
deep_expr "10,000 prefix operators" 'BEGIN{s="out("; for(i=0;i<10000;i++) s=s "!"; print s "true)"}'
deep_expr "10,000 levels of mixed nesting" 'BEGIN{print "a = array(1)"; s="out(len("; for(i=0;i<2500;i++) s=s "array(a[0 + ("; s=s "0"; for(i=0;i<2500;i++) s=s ")])"; print s "))"}'

# The block limit has two shapes: indentation, and an `else if` chain, which
# nests in the tree without indenting at all.
awk 'BEGIN{print "x = 0"; for(i=0;i<2000;i++){t=""; for(j=0;j<i;j++) t=t "    "; print t "if x == 0"} t=""; for(j=0;j<2000;j++) t=t "    "; print t "out(1)"}' > "$gen"
cerr "2,000 nested if blocks" "block nests too deeply" < "$gen"

awk 'BEGIN{print "f(x)"; print "    if x == 0"; print "        return 0"; for(i=1;i<2000;i++){print "    else if x == " i; print "        return " i} print "    return 0 - 1"; print ""; print "out(f(1))"}' > "$gen"
cerr "a 2,000-arm else-if chain" "block nests too deeply" < "$gen"

# The depths that must still compile, which show the limits are generous: the
# deepest nesting anywhere in this repository is 8 brackets, 9 indents and a
# 31-arm chain.
awk 'BEGIN{s="out("; for(i=0;i<255;i++) s=s "("; s=s "7"; for(i=0;i<255;i++) s=s ")"; print s ")"}' > "$gen"
crun "255 nested parentheses still compile" "7" < "$gen"

awk 'BEGIN{print "f(x)"; print "    if x == 0"; print "        return 0"; for(i=1;i<250;i++){print "    else if x == " i; print "        return " i} print "    return 0 - 1"; print ""; print "out(f(249))"}' > "$gen"
crun "a 250-arm else-if chain still compiles" "249" < "$gen"

# 70000 string literals is 70000 statements and over half a million tokens:
# past the literal table (65536), the token array (200000) and the item list.
got=$(awk 'BEGIN{printf "n = 0\n"; for(i=1;i<=70000;i++) printf "n = n + len(\"s%d\")\n", i; printf "out(n)\n"}' > "$p"; "$WORD" build "$p" -o "$exe" 2>&1 && "$exe")
if [ "$got" = "408894" ]; then ok "70000 string literals"; else bad "70000 string literals" "got [$(printf '%s' "$got" | head -c 200)]"; fi

# The folder is the program, and a folder can hold more than eight files.
mkdir -p "$tmp/folder"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'f%d()\n    return %d\n' $i $i > "$tmp/folder/s$i.w"; done
printf 'out(f1() + f2() + f3() + f4() + f5() + f6() + f7() + f8() + f9() + f10() + f11() + f12())\n' > "$tmp/folder/app.w"
got=$($TO "$WORD" run "$tmp/folder/app.w" 2>&1)
if [ "$got" = "78" ]; then ok "a folder of thirteen files"; else bad "a folder of thirteen files" "got [$got]"; fi

echo
echo "test_lang: $pass passed, $fail failed"
[ "$fail" = 0 ]
