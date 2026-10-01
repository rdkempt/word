#!/bin/sh
# test_output.sh: out() and err() write what they were given, in the order they
# were called, whatever buffering sits between the program and the descriptor.
#
# out() fills a 64 KB buffer and writes it when it fills, before err(), before
# a fault message, at exit, and before anything that can block or hand the
# descriptor to another process: reading stdin, the fs verbs, exec and the
# sockets. On a terminal each out() is written as it ends. Each case below
# checks one of those:
#
#   - out and err interleave in call order, into one file and through one pipe
#   - a fault writes the lines whose out() finished, and nothing of the one
#     that faulted, before its message
#   - the exit status survives the final write
#   - a line bigger than the buffer, a byte region, floats, maps, lists and
#     text that is not ASCII all come out as they did one write at a time
#   - a prompt reaches a pipe before the program waits for its answer, so a
#     program that talks to another one through pipes cannot deadlock
#   - exec's child writes after everything the parent printed (Linux)
#   - a file opened on the same descriptor sees the earlier lines first (Linux)
#   - on a terminal a line arrives when its out() ends, not at exit (Linux)
#   - and the reason for the buffer: 100,000 lines into a pipe take a handful of
#     write(2) calls, counted in /proc/self/io (Linux), where each out() used to
#     make two
#
# The cases that need a second process (the prompt, the terminal) use python3
# and say SKIP without it. On Windows the suite runs natively under Git Bash,
# without the four Linux cases. With qemu-aarch64 present the portable cases
# run on arm64 as well, and must print byte for byte what x86-64 does.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
. "$here/hostpath.sh"; win=0
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in msys*|cygwin*|win32|MINGW*|MSYS*|CYGWIN*) win=1;; esac
WORD=${WORD:-"$root/word"}; tmp=$(hostpath "$(mktemp -d)"); trap 'rm -rf "$tmp"' EXIT
cd "$root"
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 60"
PY=""; command -v python3 >/dev/null 2>&1 && PY=python3
QEMU=""
if [ "$win" = 0 ] && [ "$(uname -s)" = Linux ]; then
  QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
  case "$(uname -m)" in aarch64|arm64) QEMU="";; esac
fi

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  OK   $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1 -- $2"; }
skip() { echo "  SKIP $1 ($2)"; }

# build NAME: $tmp/NAME.w to $tmp/NAME.exe for the host and, with qemu, to
# $tmp/NAME.a64 for arm64. Answers 1 if the host build failed.
build() {
  if ! "$WORD" build "$tmp/$1.w" -o "$tmp/$1.exe" > "$tmp/berr" 2>&1; then
    bad "$1 builds" "$(head -3 "$tmp/berr")"; return 1
  fi
  if [ -n "$QEMU" ] && ! "$WORD" build -arm64 "$tmp/$1.w" -o "$tmp/$1.a64" > "$tmp/berr" 2>&1; then
    bad "$1 builds for arm64" "$(head -3 "$tmp/berr")"
  fi
  return 0
}

# same NAME WHAT: $tmp/NAME.got must be the bytes of $tmp/NAME.want
same() {
  if cmp -s "$tmp/$1.got" "$tmp/$1.want"; then ok "$2"
  else bad "$2" "got [$(head -c 300 "$tmp/$1.got" | tr '\n' '|')] want [$(head -c 300 "$tmp/$1.want" | tr '\n' '|')]"; fi
}

# targets NAME: the builds of NAME there are to run, "exe" and, with qemu, "a64";
# runner T: what runs a build of that kind, nothing for the host and qemu for arm64
targets() { echo "exe"; [ -n "$QEMU" ] && [ -f "$tmp/$1.a64" ] && echo "a64"; }
runner() { if [ "$1" = a64 ]; then echo "$QEMU"; fi; }

echo "== out and err in call order =="
cat > "$tmp/order.w" <<'EOF'
out("a")
err("b")
out("c")
err("d")
out("e")
EOF
printf 'a\nb\nc\nd\ne\n' > "$tmp/order.want"
if build order; then
  for t in $(targets order); do
    $TO $(runner $t) "$tmp/order.$t" > "$tmp/order.got" 2>&1
    same order "out and err interleave into one file ($t)"
    $TO $(runner $t) "$tmp/order.$t" 2>&1 | cat > "$tmp/order.got"
    same order "out and err interleave through one pipe ($t)"
    $TO $(runner $t) "$tmp/order.$t" 2>/dev/null | cat > "$tmp/order.got"
    printf 'a\nc\ne\n' > "$tmp/order2.want"; cp "$tmp/order.got" "$tmp/order2.got"
    same order2 "stdout alone holds the out lines ($t)"
  done
fi

echo "== a fault writes what finished before its message =="
cat > "$tmp/fault.w" <<'EOF'
out("before")
a = text(1)
i = 5
out(a[i])
EOF
if build fault; then
  for t in $(targets fault); do
    $TO $(runner $t) "$tmp/fault.$t" > "$tmp/fault.got" 2>&1; rc=$?
    first=$(head -1 "$tmp/fault.got"); second=$(sed -n 2p "$tmp/fault.got")
    case "$second" in *"fault.w:4: index 5 out of bounds"*) m=1;; *) m=0;; esac
    if [ "$rc" = 70 ] && [ "$first" = before ] && [ "$m" = 1 ]; then ok "the line printed before a fault comes before its message ($t)"
    else bad "the line printed before a fault comes before its message ($t)" "rc=$rc [$(tr '\n' '|' < "$tmp/fault.got")]"; fi
  done
fi
cat > "$tmp/midline.w" <<'EOF'
out("first")
t = text(3)
t[0] = 65
t[1] = 66
t[2] = none
out(t)
EOF
printf 'first\n' > "$tmp/midline.want"
if build midline; then
  for t in $(targets midline); do
    $TO $(runner $t) "$tmp/midline.$t" > "$tmp/midline.got" 2> "$tmp/midline.err"; rc=$?
    case "$(cat "$tmp/midline.err")" in *"midline.w:6: not a character"*) m=1;; *) m=0;; esac
    if [ "$rc" = 70 ] && [ "$m" = 1 ]; then same midline "an out() that faults writes none of its line ($t)"
    else bad "an out() that faults writes none of its line ($t)" "rc=$rc err=[$(cat "$tmp/midline.err")]"; fi
  done
fi

echo "== the exit status and the last line =="
cat > "$tmp/status.w" <<'EOF'
out("x")
out(2.5)
out(true)
return 3
EOF
printf 'x\n2.5\ntrue\n' > "$tmp/status.want"
if build status; then
  for t in $(targets status); do
    $TO $(runner $t) "$tmp/status.$t" 2>&1 | cat > "$tmp/status.got"
    same status "what is still buffered at exit is written ($t)"
    $TO $(runner $t) "$tmp/status.$t" > /dev/null 2>&1; rc=$?
    if [ "$rc" = 3 ]; then ok "and the exit status is the program's ($t)"; else bad "the exit status ($t)" "rc=$rc want 3"; fi
  done
fi

echo "== what one write per call used to put out =="
cat > "$tmp/shapes.w" <<'EOF'
s = ""
i = 0
loop i < 100000
    s = s . "ab"
    i = i + 1
out(s)
out(len(s))
b = bytes(70000)
i = 0
loop i < 70000
    b[i] = 120
    i = i + 1
out(b)
err("between")
m = {a: 1, b: "x"}
out(m)
a3 = array(3)
a3[0] = 1
a3[1] = 2
a3[2] = 3
out(a3)
out(none)
out(-42)
out(0)
out("café ☃ 😀")
out(array(3))
out(text(3))
out(1.5)
out(0 - 0.25)
x = 1
loop x < 70000
    out(x)
    x = x * 3
EOF
{
  awk 'BEGIN { for (i = 0; i < 100000; i++) printf "ab"; printf "\n200000\n"; for (i = 0; i < 70000; i++) printf "x"; printf "\n" }'
  printf '%s\n' '{"a":1,"b":"x"}' '[1,2,3]' none -42 0 'café ☃ 😀' '[0,0,0]' '[0, 0, 0]' 1.5 -0.25
  printf '%s\n' 1 3 9 27 81 243 729 2187 6561 19683 59049
} > "$tmp/shapes.want"
if build shapes; then
  for t in $(targets shapes); do
    $TO $(runner $t) "$tmp/shapes.$t" 2>/dev/null | cat > "$tmp/shapes.got"
    same shapes "a line past the buffer, bytes, maps, lists, floats and UTF-8 ($t)"
  done
fi

echo "== a prompt reaches a pipe before the program reads =="
cat > "$tmp/prompt.w" <<'EOF'
out("name?")
n = in()
out("hi " . n)
out("again?")
m = in()
out("bye " . m)
EOF
cat > "$tmp/drive.py" <<'EOF'
# drive.py CMD...: answer the program's prompts one at a time, the way a person
# or another program at the far end of two pipes would. A prompt still sitting
# in the program's buffer while it waits for its answer is a deadlock, which
# shows up here as the 20-second timeout.
import subprocess, sys, threading, queue
p = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
q = queue.Queue()
def reader():
    b = b""
    while True:
        c = p.stdout.read(1)
        if not c:
            q.put(None)
            return
        b += c
        if c == b"\n":
            q.put(b.decode().rstrip("\r\n"))
            b = b""
threading.Thread(target=reader, daemon=True).start()
def line():
    try:
        return q.get(timeout=20)
    except queue.Empty:
        print("TIMEOUT")
        p.kill()
        sys.exit(1)
a = line(); p.stdin.write(b"bob\n"); p.stdin.flush()
b = line(); c = line(); p.stdin.write(b"al\n"); p.stdin.flush()
d = line(); p.wait()
print("|".join([a, b, c, d]))
EOF
if [ -z "$PY" ]; then skip "a prompt reaches a pipe before the program reads" "no python3"
elif build prompt; then
  for t in $(targets prompt); do
    got=$($PY "$(hostpath "$tmp/drive.py")" $(runner $t) "$(hostpath "$tmp/prompt.$t")" 2>&1)
    if [ "$got" = "name?|hi bob|again?|bye al" ]; then ok "a prompt reaches a pipe before the program reads ($t)"
    else bad "a prompt reaches a pipe before the program reads ($t)" "[$got]"; fi
  done
fi

if [ "$win" = 1 ]; then
  skip "exec, /dev/stdout, the terminal and the write count" "Linux questions"
else
  echo "== exec's child writes after the parent =="
  cat > "$tmp/exec.w" <<'EOF'
import sys
out("parent says hi")
l = text(3)
l[0] = 2
l[1] = "-c"
l[2] = "echo child"
exec("/bin/sh", l)
EOF
  printf 'parent says hi\nchild\n' > "$tmp/exec.want"
  if build exec; then
    for t in $(targets exec); do
      $TO $(runner $t) "$tmp/exec.$t" 2>&1 | cat > "$tmp/exec.got"
      same exec "exec hands over the descriptor with the parent's lines written ($t)"
    done
  fi

  echo "== a file opened on the same descriptor sees the earlier lines =="
  cat > "$tmp/devout.w" <<'EOF'
out("one")
write("/dev/stdout", "two\n")
out("three")
append("/dev/stdout", "four\n")
out("five")
EOF
  printf 'one\ntwo\nthree\nfour\nfive\n' > "$tmp/devout.want"
  if build devout; then
    for t in $(targets devout); do
      $TO $(runner $t) "$tmp/devout.$t" 2>&1 | cat > "$tmp/devout.got"
      same devout "write() and append() to /dev/stdout keep their place ($t)"
    done
  fi

  echo "== on a terminal a line arrives when its out() ends =="
  cat > "$tmp/tty.w" <<'EOF'
out("tick")
i = 0
x = 1
loop i < 20000000000
    x = (x * 1103515245 + 12345) & 2147483647
    i = i + 1
out("done " . x)
EOF
  cat > "$tmp/ptyline.py" <<'EOF'
# ptyline.py EXE: run EXE on a pseudo-terminal and wait for its first line. The
# program then computes for a minute, so the line arrives now only if out()
# wrote it as it ended; a buffered one would wait for the exit, and this kills
# the program long before that.
import os, pty, select, signal, sys
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1]])
got = b""
while b"\n" not in got:
    r, _, _ = select.select([fd], [], [], 20)
    if not r:
        break
    try:
        d = os.read(fd, 1024)
    except OSError:
        break
    if not d:
        break
    got += d
os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)
print(got.decode(errors="replace").strip())
EOF
  if [ -z "$PY" ]; then skip "a terminal gets each line as out() ends" "no python3"
  elif build tty; then
    got=$($PY "$tmp/ptyline.py" "$tmp/tty.exe" 2>&1)
    if [ "$got" = tick ]; then ok "a terminal gets each line as out() ends"
    else bad "a terminal gets each line as out() ends" "[$got] (want the first line while the program still runs)"; fi
  fi

  echo "== the point of the buffer =="
  cat > "$tmp/count.w" <<'EOF'
i = 0
loop i < 100000
    out(i)
    i = i + 1
err(read("/proc/self/io"))
EOF
  if [ ! -r /proc/self/io ]; then skip "100,000 lines into a pipe are a handful of writes" "no /proc/self/io"
  elif build count; then
    $TO "$tmp/count.exe" 2> "$tmp/count.io" | cat > "$tmp/count.got"
    n=$(sed -n 's/^syscw: *//p' "$tmp/count.io")
    lines=$(wc -l < "$tmp/count.got" | tr -d ' ')
    if [ "$lines" = 100000 ] && [ -n "$n" ] && [ "$n" -lt 1000 ]; then ok "100,000 lines into a pipe are $n write(2) calls"
    else bad "100,000 lines into a pipe are a handful of writes" "lines=$lines syscw=[$n] (two per line was 200,000)"; fi
  fi
fi

[ -n "$QEMU" ] || [ "$win" = 1 ] || echo "  note: no qemu-aarch64, so only the host target ran"
echo "test_output: $pass passed, $fail failed"
[ "$fail" = 0 ]
