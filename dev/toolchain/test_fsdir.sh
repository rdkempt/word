#!/bin/sh
# test_fsdir.sh: fs.dir (readdir) on x86-64 and, under qemu, arm64, from the
# same source. dir() lists a directory's entry names. Run from the repository
# root so the fixture path compiler/ resolves.
#
# fspath_test.w runs too: the path every fs function hands the OS, checked on
# both targets against what dir() says the OS stored. That's UTF-8 for text,
# the bytes themselves for bytes, and nothing at all for a path with a NUL or
# one longer than the OS takes.
#
# It also checks what write() and out() do on both targets when a pipe's
# reader has gone: write() answers false, and out() ends the program with
# SIGPIPE as it always has. A write past the file size limit answers false too.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
cd "$root"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# A FIFO for fsdir_test.w to list. Opening one to read waits for a writer, so a
# dir() that opened it before refusing it would never return. That's what the
# timeout is for.
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 20"
FIFO=-; mkfifo "$tmp/fifo" 2>/dev/null && FIFO="$tmp/fifo"
[ "$FIFO" != - ] || echo "  (no mkfifo here: dir() of a FIFO is not checked)"

# A directory whose names add up to about 1.2 MB: 5,000 files with 247-byte
# names. dir() used to stop at 1,040,000 bytes. `ls -a` gives the entries and
# the bytes dir() should answer with, one newline after each name.
mkdir "$tmp/big"
z=$(printf '%240s' '' | tr ' ' z)
i=10000
while [ "$i" -lt 15000 ]; do : > "$tmp/big/n${i}_$z"; i=$((i + 1)); done
BIGN=$(ls -a "$tmp/big" | wc -l | tr -d ' ')
BIGB=$(ls -a "$tmp/big" | wc -c | tr -d ' ')
set -- "$FIFO" "$tmp/big" "$BIGN" "$BIGB"

# write() into a FIFO whose reader has gone, and out() into a pipe whose reader
# has gone. SIGPIPE's default action used to end the program at the write(),
# with status 141 and no message. write() has to answer false and the program
# carry on. out() still ends the program the way it always has, which also
# shows that write() put SIGPIPE's old action back.
cat > "$tmp/pw.w" <<'EOF'
import fs
a = args()
s = "x"
i = 0
loop i < 21
    s = s . s
    i = i + 1
out(write(a[1], s))
out("still here")
EOF
cat > "$tmp/yes.w" <<'EOF'
import fs
a = args()
ok = write(a[1], "x")
loop true
    out("y")
EOF
# A write past the file size limit (ulimit -f) raises SIGXFSZ, whose default
# action ended the program with status 153: write() and append() have to answer
# false and the program carry on, the same as for a pipe whose reader has gone.
cat > "$tmp/fz.w" <<'EOF'
import fs
a = args()
s = "x"
i = 0
loop i < 21
    s = s . s
    i = i + 1
out(write(a[1], s) . " " . append(a[1], s))
out("still here")
EOF
pipe_checks() { # pipe_checks <target> [runner]: runs $tmp/pw, $tmp/yes and $tmp/fz for <target>
  t=$1; shift
  if [ "$FIFO" = - ]; then echo "  (no mkfifo here: write() to a FIFO is not checked)"; else
    rm -f "$tmp/wf"; mkfifo "$tmp/wf"
    # The reader lets the writer's open finish, then closes without reading. 2 MB
    # is more than a pipe holds, so the write cannot finish before it goes.
    ( exec 3<"$tmp/wf"; exec 3<&- ) & rpid=$!
    rc=0; got=$($TO "$@" "$tmp/pw.$t" "$tmp/wf" 2>&1) || rc=$?
    kill "$rpid" 2>/dev/null || true; wait "$rpid" 2>/dev/null || true
    if [ "$rc" = 0 ] && [ "$got" = "false
still here" ]; then echo "  ok: $t: write() to a FIFO whose reader has gone answers false"
    else echo "  FAIL: $t: write() to a FIFO whose reader has gone: status $rc [$got]"; fail=1; fi
  fi
  rm -f "$tmp/yes.rc"
  { rc=0; $TO "$@" "$tmp/yes.$t" "$tmp/yes.txt" || rc=$?; echo "$rc" > "$tmp/yes.rc"; } | head -n 1 > /dev/null
  rc=$(cat "$tmp/yes.rc" 2>/dev/null || echo none)
  if [ "$rc" = 141 ]; then echo "  ok: $t: out() to a pipe whose reader has gone still ends the program (141)"
  else echo "  FAIL: $t: out() to a pipe whose reader has gone: status [$rc], want 141"; fail=1; fi
  if ( ulimit -f 64 ) 2>/dev/null; then
    rm -f "$tmp/fz.txt"
    rc=0; got=$( ( ulimit -f 64; exec $TO "$@" "$tmp/fz.$t" "$tmp/fz.txt" ) 2>&1 ) || rc=$?
    if [ "$rc" = 0 ] && [ "$got" = "false false
still here" ]; then echo "  ok: $t: write() and append() past the file size limit answer false"
    else echo "  FAIL: $t: write() and append() past the file size limit: status $rc [$got]"; fail=1; fi
  else echo "  (no ulimit -f here: a write past the file size limit is not checked)"; fi
}

fail=0
if "$WORD" build "$tmp/pw.w" -o "$tmp/pw.x86-64" >"$tmp/err" 2>&1 &&
   "$WORD" build "$tmp/yes.w" -o "$tmp/yes.x86-64" >>"$tmp/err" 2>&1 &&
   "$WORD" build "$tmp/fz.w" -o "$tmp/fz.x86-64" >>"$tmp/err" 2>&1; then
  pipe_checks x86-64
else echo "  FAIL: x86-64 build of pw.w, yes.w or fz.w"; sed 's/^/    /' "$tmp/err"; fail=1; fi
if ! "$WORD" build "$here/fsdir_test.w" -o "$tmp/fsdir" >"$tmp/err" 2>&1; then
  echo "  FAIL: x86-64 build"; sed 's/^/    /' "$tmp/err"; fail=1
else
  rc=0; $TO "$tmp/fsdir" "$@" || rc=$?; [ "$rc" = 0 ] || { [ "$rc" = 124 ] && echo "  FAIL: x86-64 timed out"; fail=1; }
fi
if ! "$WORD" build "$here/fspath_test.w" -o "$tmp/fspath" >"$tmp/err" 2>&1; then
  echo "  FAIL: x86-64 build of fspath_test.w"; sed 's/^/    /' "$tmp/err"; fail=1
else
  mkdir -p "$tmp/px/sub"
  rc=0; "$tmp/fspath" "$tmp/px" || rc=$?; [ "$rc" = 0 ] || fail=1
fi

QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
if [ -n "$QEMU" ]; then
  if ! "$WORD" build -arm64 "$here/fsdir_test.w" -o "$tmp/fsdir.a64" >"$tmp/err" 2>&1; then
    echo "  FAIL: arm64 build"; sed 's/^/    /' "$tmp/err"; fail=1
  else
    rc=0; $TO $QEMU "$tmp/fsdir.a64" "$@" > "$tmp/a64.txt" 2>&1 || rc=$?
    sed 's/^/  arm64: /' "$tmp/a64.txt"
    [ "$rc" = 0 ] || { [ "$rc" = 124 ] && echo "  FAIL: arm64 timed out"; fail=1; }
  fi
  if ! "$WORD" build -arm64 "$here/fspath_test.w" -o "$tmp/fspath.a64" >"$tmp/err" 2>&1; then
    echo "  FAIL: arm64 build of fspath_test.w"; sed 's/^/    /' "$tmp/err"; fail=1
  else
    mkdir -p "$tmp/pa/sub"
    rc=0; $QEMU "$tmp/fspath.a64" "$tmp/pa" > "$tmp/a64.txt" 2>&1 || rc=$?
    sed 's/^/  arm64: /' "$tmp/a64.txt"
    [ "$rc" = 0 ] || fail=1
  fi
  if "$WORD" build -arm64 "$tmp/pw.w" -o "$tmp/pw.arm64" >"$tmp/err" 2>&1 &&
     "$WORD" build -arm64 "$tmp/yes.w" -o "$tmp/yes.arm64" >>"$tmp/err" 2>&1 &&
     "$WORD" build -arm64 "$tmp/fz.w" -o "$tmp/fz.arm64" >>"$tmp/err" 2>&1; then
    pipe_checks arm64 $QEMU
  else echo "  FAIL: arm64 build of pw.w, yes.w or fz.w"; sed 's/^/    /' "$tmp/err"; fail=1; fi
fi

[ "$fail" = 0 ] || { echo "test_fsdir: FAIL"; exit 1; }
echo "test_fsdir: PASS"
