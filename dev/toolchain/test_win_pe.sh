#!/bin/sh
# test_win_pe.sh: word's Windows PE backend. `word asm -win` links a
# hand-written Windows program into a PE (a kernel32 import table and IAT, from
# word's own linker, no MinGW), and `word build -win` cross-compiles .w
# programs. objdump and python3 check each PE's structure, imports and
# resources. When a PE can run here (natively on Windows, under wine, or
# through WSL interop; see win_runner.sh), the suite runs them and checks what
# they print. CI installs no wine, so in ci.yml the runtime cases skip;
# windows.yml runs them natively. Nothing needs wine to build word or a word
# program.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
# word.exe is a native Windows binary when this runs on Windows, and cannot open
# an MSYS path. One conversion here keeps every line below it working on both.
. "$here/hostpath.sh"; here=$(hostpath "$here"); root=$(hostpath "$root")
WORD=$(wordbin "${WORD:-$root/word}")
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
tmp=$(hostpath "$(mktemp -d)"); trap 'rm -rf "$tmp"' EXIT
fail=0
# How to run a PE from here: natively on Windows, under wine, or through WSL
# interop, which hands the PE to Windows itself. See win_runner.sh.
. "$here/win_runner.sh"
win_runner_init "$tmp"

echo "Windows PE backend (word asm -win):"
"$WORD" asm -win "$here/win_smoke/hello_win.s" "$tmp/hello.exe" 2>"$tmp/err" \
  || { echo "  FAIL: word asm -win errored:"; sed 's/^/    /' "$tmp/err"; exit 1; }

if command -v objdump >/dev/null 2>&1; then
  objdump -f "$tmp/hello.exe" 2>/dev/null | grep -q 'pei-x86-64' \
    && echo "  ok: emits a PE64 (pei-x86-64) image" || { echo "  FAIL: not pei-x86-64"; fail=1; }
  objdump -x "$tmp/hello.exe" 2>/dev/null | grep -qi 'kernel32.dll' \
    && echo "  ok: kernel32 import table present" || { echo "  FAIL: no kernel32 imports"; fail=1; }
else
  echo "  SKIP: objdump not present (structural check)"
fi

# The probe is also the first runtime case. If a PE can't run here at all,
# every later runtime case skips and the structural ones carry on.
if [ -n "$PE_KIND" ]; then
  win_runner_probe "$tmp/hello.exe" "Hello, word!" \
    && echo "  ok: runs under $(win_runner_name) -> 'Hello, word!'"
else
  echo "  SKIP: no way to run a PE here (wine absent, not WSL); structural checks only"
fi

# With no flag, word asm targets the host the way build does, so a dump from
# `build -asm` goes back through `asm` to the binary `build` writes. On a
# Windows host that's a PE both ways. asm used to default to a Linux ELF
# there, and the round trip failed to link. The dump is named after its
# source, as SPEC 14 says to, because a PE's version block carries the
# program's name, and asm takes it from the .s the way build takes it from
# the .w.
if "$WORD" build -asm "$root/examples/hello/hello.w" > "$tmp/hello.s" 2>"$tmp/err" \
   && "$WORD" asm "$tmp/hello.s" "$tmp/rt_asm.exe" 2>>"$tmp/err" \
   && "$WORD" build "$root/examples/hello/hello.w" -o "$tmp/rt_build.exe" 2>>"$tmp/err" \
   && cmp -s "$tmp/rt_asm.exe" "$tmp/rt_build.exe"; then
  echo "  ok: build -asm then asm with no flag gives the binary build does, for this host"
else
  echo "  FAIL: build -asm then asm with no flag differs from build on this host:"; sed 's/^/    /' "$tmp/err"; fail=1
fi

# --- `word build -win`: cross-compile real .w programs to PEs and, where a PE
# can run, run them. That covers the emitted Windows runtime: the VirtualAlloc
# arena and literal pool copy, the w_syscall shim (WriteFile, ReadFile,
# CreateFileA and the rest) and args from GetCommandLineA. The structure is
# always checked, and the behaviour when a PE can run. ---
echo "Windows runtime (word build -win):"
"$WORD" build -win "$root/examples/hello/hello.w" -o "$tmp/hw.exe" 2>"$tmp/err" \
  || { echo "  FAIL: word build -win errored:"; sed 's/^/    /' "$tmp/err"; fail=1; }
"$WORD" build -win "$root/examples/greet/greet.w" -o "$tmp/gw.exe" 2>/dev/null || fail=1
if command -v objdump >/dev/null 2>&1 && [ -f "$tmp/hw.exe" ]; then
  objdump -f "$tmp/hw.exe" 2>/dev/null | grep -q 'pei-x86-64' \
    && echo "  ok: hello.w -> PE64" || { echo "  FAIL: hello.w not a PE64"; fail=1; }
  # rdrand is an illegal instruction on a CPU without it, so the startup has to
  # ask CPUID (leaf 1, ECX bit 30) before it runs one. Without that check, every
  # word-built .exe died before main on older CPUs and on VMs that hide RDRAND.
  dis=$(objdump -d "$tmp/hw.exe" 2>/dev/null)
  c=$(printf '%s\n' "$dis" | grep -n 'cpuid' | head -1 | cut -d: -f1)
  r=$(printf '%s\n' "$dis" | grep -n 'rdrand' | head -1 | cut -d: -f1)
  t=$(printf '%s\n' "$dis" | grep -n 'test.*0x40000000' | head -1 | cut -d: -f1)
  if [ -n "$c" ] && [ -n "$r" ] && [ -n "$t" ] && [ "$c" -lt "$t" ] && [ "$t" -lt "$r" ]; then
    echo "  ok: the startup checks CPUID for RDRAND before it uses rdrand"
  else
    echo "  FAIL: rdrand is not guarded by a CPUID check (cpuid@$c test@$t rdrand@$r)"; fail=1
  fi
fi
# -win with no -o names the output after the source and adds .exe.
( cd "$tmp" && cp "$root/examples/hello/hello.w" . && "$WORD" build -win hello.w >/dev/null 2>&1 \
  && [ -f "$tmp/hello.exe" ] ) \
  && echo "  ok: -win with no -o defaults the name to hello.exe" \
  || { echo "  FAIL: -win did not default the output to hello.exe"; fail=1; }
if [ -n "$PE_KIND" ] && [ -f "$tmp/hw.exe" ]; then
  R=$(win_runner_name)
  o=$(pe_run 90 "$tmp/hw.exe" 2>/dev/null || true)
  [ "$o" = "Hello, word!" ] && echo "  ok: hello.w runs under $R -> 'Hello, word!'" \
    || { echo "  FAIL: hello.w stdout [$o]"; fail=1; }
  # greet takes an argument -> exercises GetCommandLineA / w_argptr
  printf 'a = args()\ns = read(a[1])\nok = write(a[2], s)\nout(len(s))\n' > "$tmp/rt.w"
  o=$(pe_run 90 "$tmp/gw.exe" Ada 2>/dev/null || true)
  [ "$o" = "Hello, Ada!" ] && echo "  ok: greet.w Ada -> 'Hello, Ada!' (args via GetCommandLineA)" \
    || { echo "  FAIL: greet.w stdout [$o]"; fail=1; }
  # fs read/write round-trip through the w_syscall file path. Run from $tmp with
  # relative names, so the argv paths need no translation on either runner.
  "$WORD" build -win "$tmp/rt.w" -o "$tmp/rt.exe" 2>/dev/null
  ( cd "$tmp" && printf 'round trip bytes\n' > i.txt \
    && n=$(pe_run 90 "$tmp/rt.exe" i.txt o.txt 2>/dev/null || true) \
    && [ "$n" = "$(wc -c < i.txt)" ] && cmp -s i.txt o.txt ) \
    && echo "  ok: fs read/write round-trips under $R" \
    || { echo "  FAIL: fs round-trip"; fail=1; }
  # fs.rename (syscall 82, MoveFileExA on Windows) used to be unmapped there,
  # like now() and random() below. Having the import doesn't prove it works, so
  # run it. Relative names, from $tmp, so no argv path needs translating.
  printf 'import fs\nok = write("rn_a.txt", "moved")\nr = rename("rn_a.txt", "rn_b.txt")\nout(r . " " . read("rn_b.txt"))\n' > "$tmp/rn2.w"
  if "$WORD" build -win "$tmp/rn2.w" -o "$tmp/rn2.exe" 2>/dev/null; then
    ( cd "$tmp" && rm -f rn_a.txt rn_b.txt
      got=$(pe_run 90 "$tmp/rn2.exe" 2>/dev/null)
      if [ "$got" = "true moved" ]; then echo "  ok: fs.rename actually renames on Windows (MoveFileExA)"
      else echo "  FAIL: fs.rename on Windows gave [$got], want [true moved]"; exit 1; fi ) || fail=1
  fi
  # sys.writex opens its file through the same arm of the OS layer as fs, and
  # that arm used to come with fs and the sockets only: a program that called
  # writex and nothing from fs had no open to call, and writex answered 0.
  printf 'b = bytes(3)\nb[0] = 119\nb[1] = 120\nb[2] = 10\nout(writex("wx_out.txt", b))\n' > "$tmp/wx.w"
  if "$WORD" build -win "$tmp/wx.w" -o "$tmp/wx.exe" 2>/dev/null; then
    ( cd "$tmp" && rm -f wx_out.txt
      got=$(pe_run 90 "$tmp/wx.exe" 2>/dev/null)
      if [ "$got" = 1 ] && [ "$(cat wx_out.txt 2>/dev/null)" = wx ]; then echo "  ok: sys.writex writes its file on Windows in a program without fs"
      else echo "  FAIL: sys.writex on Windows gave [$got] and wrote [$(cat wx_out.txt 2>/dev/null)]"; exit 1; fi ) || fail=1
  fi

  # fs.dir: Windows doesn't open a directory as a file, so the OS layer lists it
  # with FindFirstFileW. Before that, dir() answered none on Windows, and for a
  # missing path it created a file, because the O_DIRECTORY open fell into the
  # create-and-truncate arm. The listing must hold . and .. and the entries, a
  # missing path is none, and asking leaves nothing behind.
  printf 'import fs\nout(dir("."))\nout(kind(dir("nothing_here")))\n' > "$tmp/dr.w"
  if "$WORD" build -win "$tmp/dr.w" -o "$tmp/dr.exe" 2>/dev/null; then
    ( cd "$tmp" && rm -rf dirtest && mkdir dirtest && cd dirtest && : > one.txt && : > two.txt
      lst=$(pe_run 90 "$tmp/dr.exe" 2>/dev/null | tr '\n' ' ')
      miss=
      for want in . .. one.txt two.txt none; do
        case " $lst " in *" $want "*) ;; *) miss="$miss $want" ;; esac
      done
      if [ -n "$miss" ]; then echo "  FAIL: fs.dir on Windows gave [$lst], missing:$miss"; exit 1; fi
      if [ -e nothing_here ]; then echo "  FAIL: dir() of a missing path created it"; exit 1; fi
      echo "  ok: fs.dir lists a directory on Windows, and creates nothing (FindFirstFileW)"
      exit 0 ) || fail=1
  fi

  # The compiler needs dir() too: a folder program is every .w file beside
  # app.w (SPEC 11), and the compiler finds them by listing the directory. A
  # word.exe on Windows couldn't, so it built app.w alone and failed on the
  # first call into a sibling.
  mkdir -p "$tmp/fold"
  printf 'out(hi())\n' > "$tmp/fold/app.w"
  printf 'hi()\n    return "from the sibling"\n' > "$tmp/fold/lib.w"
  if "$WORD" build -win "$tmp/fold/app.w" -o "$tmp/fold/app.exe" 2>"$tmp/err"; then
    o=$(pe_run 90 "$tmp/fold/app.exe" 2>/dev/null || true)
    [ "$o" = "from the sibling" ] \
      && echo "  ok: a folder program builds and runs ($R)" \
      || { echo "  FAIL: folder program stdout [$o]"; fail=1; }
  else
    echo "  FAIL: folder program build: $(head -1 "$tmp/err")"; fail=1
  fi

  # now() and random() answer from the OS. Both used to return 0 on Windows,
  # because their syscalls were mapped only for net programs. The test wants a
  # clock later than 2020 and two different draws.
  printf 'out(now())\nout(random())\nout(random())\n' > "$tmp/nr.w"
  if "$WORD" build -win "$tmp/nr.w" -o "$tmp/nr.exe" 2>/dev/null; then
    nr=$(pe_run 90 "$tmp/nr.exe" 2>/dev/null || true)
    t=$(echo "$nr" | sed -n 1p); r1=$(echo "$nr" | sed -n 2p); r2=$(echo "$nr" | sed -n 3p)
    if [ "${t:-0}" -gt 1600000000000000000 ] 2>/dev/null; then
      echo "  ok: now() reads the Windows clock (not 0)"
    else echo "  FAIL: now() on Windows gave [$t]"; fail=1; fi
    if [ -n "$r1" ] && [ "$r1" != 0 ] && [ "$r1" != "$r2" ]; then
      echo "  ok: random() draws from the system CSPRNG (not 0, not repeated)"
    else echo "  FAIL: random() on Windows gave [$r1] then [$r2]"; fail=1; fi
  fi

  # An argument has to survive both halves of a Windows command line: the parent
  # quotes its argv into one string for CreateProcessA (as exec() and `word run`
  # do), and the child splits it back the way the Microsoft C runtime does.
  # Before both followed that rule, a quote split an argument in two, a trailing
  # backslash swallowed the next argument, and the string went into an 8 KB
  # buffer with no length check. The runner quoting the parent's own arguments
  # is a third pass over the same rule, so every argument below crosses it three
  # times.
  printf 'a = args()\nout(len(a))\nout(copy(a, 1))\n' > "$tmp/avc.w"
  printf 'import sys\na = args()\nn = len(a) - 2\nl = text(n + 1)\nl[0] = n\ni = 0\nloop i < n\n    l[i + 1] = a[i + 2]\n    i = i + 1\nexec(a[1], l)\nout("exec failed")\n' > "$tmp/avp.w"
  if "$WORD" build -win "$tmp/avc.w" -o "$tmp/avc.exe" 2>/dev/null && "$WORD" build -win "$tmp/avp.w" -o "$tmp/avp.exe" 2>/dev/null; then
    got=$(pe_run 90 "$tmp/avp.exe" "$(pe_path "$tmp/avc.exe")" plain 'two words' 'a"b' 'trail\' '' 'q\"x' 'x\\' 2>&1 || true)
    want='8
["plain","two words","a\"b","trail\\","","q\\\"x","x\\\\"]'
    if [ "$got" = "$want" ]; then echo "  ok: quotes, backslashes and an empty argument reach a child intact"
    else echo "  FAIL: argv round trip through CreateProcessA gave [$got]"; fail=1; fi
    # 40 KB of arguments can't be a Windows command line (the limit is 32,767),
    # so the parent has to refuse instead of writing past its buffer.
    printf 'import sys\nbig = text(20000)\ni = 0\nloop i < 20000\n    big[i] = 120\n    i = i + 1\nl = text(3)\nl[0] = 2\nl[1] = big\nl[2] = big\nexec(args()[1], l)\nout("refused")\n' > "$tmp/avbig.w"
    if "$WORD" build -win "$tmp/avbig.w" -o "$tmp/avbig.exe" 2>/dev/null; then
      got=$(pe_run 90 "$tmp/avbig.exe" "$(pe_path "$tmp/avc.exe")" 2>&1 || true)
      if [ "$got" = "refused" ]; then echo "  ok: a command line too long for Windows is refused, not overrun"
      else echo "  FAIL: a 40 KB command line gave [$got]"; fail=1; fi
    fi
  else echo "  FAIL: could not build the argv round-trip programs"; fail=1; fi
elif [ -z "$PE_KIND" ]; then
  echo "  SKIP: no PE runner (build -win structurally checked only)"
fi

# --- a frame of a page or more. Windows commits a thread's stack one guard page
# at a time (SizeOfStackCommit is 4096), so a function whose frame is a page or
# more has to touch it a page at a time from the top before using it, or its
# first store far below what's committed skips the guard page and dies as an
# access violation. A function with 12,000 locals (a 96 KB frame) that called
# out() before touching most of them did that, while Linux ran it fine. ---
echo "Windows stack (word build -win):"
awk 'BEGIN{ n=12000; print "f(x)"; print "    s = 0"; print "    if x > 5"
  for(i=0;i<n;i++) printf "        a%d = %d\n", i, i
  for(c=0;c<n/500;c++){ printf "        s = s"; for(i=c*500;i<(c+1)*500;i++) printf " + a%d", i; print "" }
  print "    out(\"hi\")"; print "    return s"; print ""; print "out(f(1))" }' > "$tmp/bigf.w"
if "$WORD" build -win -asm "$tmp/bigf.w" > "$tmp/bigf.s" 2>"$tmp/err"; then
  # A touch at each 4 KB down to the frame's last whole page, then the frame:
  # 23 for 96,016 bytes.
  np=$(awk '/^fn_f:/{on=1} on && /^    test qword ptr \[rbp - [0-9]+\], rax$/{n++}
    on && /^    sub rsp, [0-9]+$/{print n+0, int($3/4096); exit}' "$tmp/bigf.s")
  if [ "$np" = "23 23" ]; then echo "  ok: a 96 KB frame is touched a page at a time before it's taken (23 pages)"
  else echo "  FAIL: a 96 KB frame's prologue touches [$np] (touches, whole pages), want 23 23"; fail=1; fi
else
  echo "  FAIL: the big-frame program did not build for -win: $(head -1 "$tmp/err")"; fail=1
fi
if [ -n "$PE_KIND" ]; then
  if "$WORD" build -win "$tmp/bigf.w" -o "$tmp/bigf.exe" 2>"$tmp/err"; then
    rc=0; o=$(pe_run 90 "$tmp/bigf.exe" 2>&1) || rc=$?
    if [ "$o" = "hi
0" ] && [ "$rc" = 0 ]; then echo "  ok: a function with a 96 KB frame runs ($(win_runner_name))"
    else echo "  FAIL: a function with a 96 KB frame gave [$o] exit $rc ($(win_runner_name))"; fail=1; fi
  else echo "  FAIL: the big-frame program did not build: $(head -1 "$tmp/err")"; fail=1; fi
fi

# --- net on the Windows target: the word net library (carried in
# compiler/word.w) compiles into the PE, with sockets going to ws2_32.
# Cross-compile a net program and check its import table. A PE that uses no
# net must not import the DLL.
#
# A net PE imports crypt32 as well, because Windows keeps its trust anchors in
# the ROOT store instead of a file, and net.w reaches them through
# sys.cacerts(). It also imports iphlpapi, because Windows lists its DNS
# resolvers through GetNetworkParams instead of /etc/resolv.conf, and net.w
# asks for them through sys.nameservers(). The sys.cacerts and
# sys.nameservers sections below check that each import is there when the
# program uses it, and only then. ---
echo "Windows net (word build -win, ws2_32):"
"$WORD" build -win "$root/examples/https/https.w" -o "$tmp/fetch.exe" 2>"$tmp/err" \
  || { echo "  FAIL: word build -win errored on a net program:"; sed 's/^/    /' "$tmp/err"; fail=1; }
if command -v objdump >/dev/null 2>&1 && [ -f "$tmp/fetch.exe" ]; then
  imp=$(objdump -x "$tmp/fetch.exe" 2>/dev/null)
  printf '%s' "$imp" | grep -qi 'ws2_32.dll' \
    && echo "  ok: fetch.w PE imports ws2_32 (sockets)" || { echo "  FAIL: no ws2_32 import"; fail=1; }
  printf '%s' "$imp" | grep -qi 'crypt32.dll' \
    && echo "  ok: fetch.w PE imports crypt32 (the ROOT trust store)" \
    || { echo "  FAIL: a net PE with no crypt32 import has no trust anchors"; fail=1; }
  printf '%s' "$imp" | grep -qi 'iphlpapi.dll' \
    && echo "  ok: fetch.w PE imports iphlpapi (the host's DNS resolvers)" \
    || { echo "  FAIL: a net PE with no iphlpapi import cannot ask the host for its resolver"; fail=1; }
  printf '%s' "$imp" | grep -qi 'bcrypt.dll' \
    && echo "  ok: fetch.w PE imports bcrypt (handshake CSPRNG)" || { echo "  FAIL: no bcrypt import"; fail=1; }
  miss=""
  for fn in socket connect send recv closesocket setsockopt WSAStartup BCryptGenRandom; do
    printf '%s' "$imp" | grep -qi "  *$fn\$" || miss="$miss $fn"
  done
  [ -z "$miss" ] && echo "  ok: all 7 ws2_32 + BCryptGenRandom imports resolved" \
    || { echo "  FAIL: net imports missing:$miss"; fail=1; }
  # udp is connect() on a datagram socket, so nothing calls sendto or recvfrom,
  # and a PE shouldn't import something no code path uses.
  printf '%s' "$imp" | grep -qiE "  *(sendto|recvfrom)\$" \
    && { echo "  FAIL: a net PE imports sendto or recvfrom, which nothing calls"; fail=1; } \
    || echo "  ok: and not sendto or recvfrom, which nothing calls"
  # A program without net imports none of the net DLLs.
  if [ -f "$tmp/hw.exe" ]; then
    hwi=$(objdump -x "$tmp/hw.exe" 2>/dev/null)
    printf '%s' "$hwi" | grep -qiE 'ws2_32|bcrypt' \
      && { echo "  FAIL: non-net hello.w imports a net DLL"; fail=1; } \
      || echo "  ok: non-net PE imports neither ws2_32 nor bcrypt (net-gated)"
  fi

  # ...but random() is a syscall too, and it isn't net. getrandom used to be
  # mapped only for net programs, so in any other PE syscall 318 fell through
  # to -1, rt_random read back its zeroed buffer, and random() answered 0 every
  # time. A program that calls random() must carry bcrypt and the 318 dispatch.
  printf 'out(random())\n' > "$tmp/rnd.w"
  if "$WORD" build -win "$tmp/rnd.w" -o "$tmp/rnd.exe" 2>/dev/null; then
    objdump -x "$tmp/rnd.exe" 2>/dev/null | grep -qi 'bcrypt' \
      && echo "  ok: a non-net PE that calls random() imports bcrypt (system CSPRNG)" \
      || { echo "  FAIL: random() in a non-net PE has no CSPRNG; it would answer 0"; fail=1; }
    "$WORD" build -win -asm "$tmp/rnd.w" 2>/dev/null | grep -q '\.wsc_getrandom' \
      && echo "  ok: w_syscall maps getrandom (318) for a non-net PE that needs it" \
      || { echo "  FAIL: no getrandom mapping emitted for random() in a non-net PE"; fail=1; }
  else
    echo "  SKIP: random() PE did not build"
  fi

  # The socket verbs had the same problem. The ws2_32 layer was gated on the net
  # verbs, so a program that called connect() without one (a test that builds
  # dns.w by itself) had no sockets at all: socket (41) fell through to -1,
  # connect() answered 0, and send() and recv() went to the file descriptors
  # with the same numbers.
  printf 'lo = bytes(4)\nlo[0] = 127\nlo[3] = 1\nout(connect(lo, 9))\n' > "$tmp/sk.w"
  if "$WORD" build -win "$tmp/sk.w" -o "$tmp/sk.exe" 2>/dev/null; then
    objdump -x "$tmp/sk.exe" 2>/dev/null | grep -qi 'ws2_32' \
      && echo "  ok: a PE that calls a socket verb and no net verb imports ws2_32" \
      || { echo "  FAIL: connect() in a PE with no net verb has no socket layer"; fail=1; }
    "$WORD" build -win -asm "$tmp/sk.w" 2>/dev/null | grep -q '\.wsc_socket' \
      && echo "  ok: w_syscall maps socket (41) for it" \
      || { echo "  FAIL: no socket mapping emitted for connect() without a net verb"; fail=1; }
  else
    echo "  SKIP: socket-verb PE did not build"
  fi

  # fs.dir too: Windows doesn't read a directory through a handle, so the OS
  # layer lists it with FindFirstFileW. The five kernel32 imports that takes are
  # in a program that calls dir(), and in no other.
  printf 'import fs\nout(kind(dir(".")))\n' > "$tmp/dr0.w"
  if "$WORD" build -win "$tmp/dr0.w" -o "$tmp/dr0.exe" 2>/dev/null; then
    objdump -x "$tmp/dr0.exe" 2>/dev/null | grep -qi 'FindFirstFileW' \
      && echo "  ok: a PE that calls dir() imports FindFirstFileW" \
      || { echo "  FAIL: dir() in a PE has nothing to list a directory with"; fail=1; }
  fi
  printf 'import fs\nout(kind(read("x")))\n' > "$tmp/rd0.w"
  if "$WORD" build -win "$tmp/rd0.w" -o "$tmp/rd0.exe" 2>/dev/null; then
    objdump -x "$tmp/rd0.exe" 2>/dev/null | grep -qi 'FindFirstFileW' \
      && { echo "  FAIL: an fs PE that never lists a directory imports FindFirstFileW"; fail=1; } \
      || echo "  ok: an fs PE that never calls dir() does not (gated on the call)"
  fi

  # Every syscall number the emitted runtime issues has to be in w_syscall's
  # dispatch for the programs that reach it. now() issues clock_gettime (228)
  # and used to answer 0 on Windows, and fs.rename issues rename (82) and always
  # failed. Both are kernel32, so the gate here is about not listing an import a
  # program doesn't use, not about loading a DLL.
  printf 'out(now())\n' > "$tmp/nw.w"
  if "$WORD" build -win "$tmp/nw.w" -o "$tmp/nw.exe" 2>/dev/null; then
    objdump -x "$tmp/nw.exe" 2>/dev/null | grep -qi 'GetSystemTimeAsFileTime' \
      && echo "  ok: a non-net PE that calls now() imports GetSystemTimeAsFileTime" \
      || { echo "  FAIL: now() in a non-net PE has no clock; it would answer 0"; fail=1; }
  else
    echo "  SKIP: now() PE did not build"
  fi
  printf 'import fs\nout(rename("a.tmp", "b.tmp"))\n' > "$tmp/rn.w"
  if "$WORD" build -win "$tmp/rn.w" -o "$tmp/rn.exe" 2>/dev/null; then
    objdump -x "$tmp/rn.exe" 2>/dev/null | grep -qi 'MoveFileExA' \
      && echo "  ok: a PE that calls fs.rename imports MoveFileExA" \
      || { echo "  FAIL: fs.rename in a PE has no rename; it would always fail"; fail=1; }
  else
    echo "  SKIP: fs.rename PE did not build"
  fi
  # ...and a program that needs none of the three imports none of them.
  if [ -f "$tmp/hw.exe" ]; then
    objdump -x "$tmp/hw.exe" 2>/dev/null | grep -qiE 'MoveFileExA|GetSystemTimeAsFileTime|BCryptGenRandom' \
      && { echo "  FAIL: hello.w imports a syscall shim it cannot reach"; fail=1; } \
      || echo "  ok: hello.w names no clock, RNG or rename import (each use-gated)"
  fi
  # A program that uses the socket verbs, and never random() or now(), imports
  # neither the RNG nor the clock. Both used to come with the sockets.
  printf 'fd = connect(bytes("7f000001"), 9)\nout(fd)\n' > "$tmp/sk.w"
  if "$WORD" build -win "$tmp/sk.w" -o "$tmp/sk.exe" 2>/dev/null; then
    objdump -x "$tmp/sk.exe" 2>/dev/null | grep -qiE 'GetSystemTimeAsFileTime|BCryptGenRandom' \
      && { echo "  FAIL: a socket program with no random() or now() imports the RNG or the clock"; fail=1; } \
      || echo "  ok: a socket program with no random() or now() imports neither the RNG nor the clock"
  else
    echo "  FAIL: a socket program did not build for Windows"; fail=1
  fi
else
  echo "  SKIP: objdump not present (net PE import check)"
fi

# --- PE hygiene: sections, security flags, checksum -------------------------
#
# The image used to be one 0xE0000020 section (readable, writable and
# executable), with DllCharacteristics 0 and no checksum. The ELF side has
# always had W^X. This checks the same for the PE, plus the header bits that
# tell Windows to enforce it, a .reloc section, a checksum and an 8 MB stack.
if command -v python3 >/dev/null 2>&1 && [ -f "$tmp/hw.exe" ]; then
  python3 - "$tmp/hw.exe" <<'PYEOF' && echo "  ok: W^X sections, NX+ASLR flags, .reloc, non-zero checksum, 8 MB stack" || { echo "  FAIL: PE header hygiene (see above)"; fail=1; }
import sys
d = open(sys.argv[1], 'rb').read()
lf = int.from_bytes(d[60:64], 'little')
nsec = int.from_bytes(d[lf+6:lf+8], 'little')
optsz = int.from_bytes(d[lf+20:lf+22], 'little')
opt = lf + 24
bad = []
# section table: name -> characteristics
base = opt + optsz
secs = {}
for i in range(nsec):
    h = d[base+i*40 : base+i*40+40]
    secs[h[0:8].rstrip(b'\0').decode()] = int.from_bytes(h[36:40], 'little')
IMAGE_SCN_MEM_EXECUTE = 0x20000000
IMAGE_SCN_MEM_WRITE   = 0x80000000
for nm, ch in secs.items():
    if (ch & IMAGE_SCN_MEM_EXECUTE) and (ch & IMAGE_SCN_MEM_WRITE):
        bad.append("section %s is both writable and executable (%#x)" % (nm, ch))
for want in (".text", ".rdata", ".data", ".reloc"):
    if want not in secs:
        bad.append("no %s section" % want)
if secs.get(".text", 0) & IMAGE_SCN_MEM_WRITE:
    bad.append(".text is writable")
if not (secs.get(".data", 0) & IMAGE_SCN_MEM_WRITE):
    bad.append(".data is not writable")
if secs.get(".rdata", 0) & (IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE):
    bad.append(".rdata is writable or executable")
dll = int.from_bytes(d[opt+70:opt+72], 'little')
for bit, nm in ((0x0020, "HIGH_ENTROPY_VA"), (0x0040, "DYNAMIC_BASE"), (0x0100, "NX_COMPAT")):
    if not (dll & bit):
        bad.append("DllCharacteristics %#06x lacks %s" % (dll, nm))
if int.from_bytes(d[opt+64:opt+68], 'little') == 0:
    bad.append("CheckSum is zero")
# 8 MB of stack, the Linux default, so a program recurses as deep on both
stack = int.from_bytes(d[opt+72:opt+80], 'little')
if stack != 8388608:
    bad.append("SizeOfStackReserve is %d, expected 8388608" % stack)
# base relocation directory (index 5): without it Windows ignores DYNAMIC_BASE
reloc_va = int.from_bytes(d[opt+112+5*8 : opt+112+5*8+4], 'little')
reloc_sz = int.from_bytes(d[opt+112+5*8+4 : opt+112+5*8+8], 'little')
if reloc_va == 0 or reloc_sz == 0:
    bad.append("no base relocation directory, so DYNAMIC_BASE is ignored")
for b in bad:
    print("    " + b)
sys.exit(1 if bad else 0)
PYEOF
else
  echo "  SKIP: python3 absent or no hello PE (header hygiene)"
fi

# --- .rsrc: the version block and the application manifest ------------------
#
# A word PE used to have an empty Details tab in Explorer and no manifest. The
# manifest matters: word calls the ANSI entry points (CreateFileA,
# GetCommandLineA), and without an activeCodePage declaration those use the
# legacy code page instead of UTF-8.
if command -v python3 >/dev/null 2>&1 && [ -f "$tmp/hw.exe" ]; then
  python3 - "$tmp/hw.exe" <<'PYEOF' && echo "  ok: version block and manifest are well-formed" || { echo "  FAIL: .rsrc contents (see above)"; fail=1; }
import struct, sys, xml.etree.ElementTree as ET
d = open(sys.argv[1], 'rb').read()
lf = int.from_bytes(d[60:64], 'little')
nsec = int.from_bytes(d[lf+6:lf+8], 'little')
optsz = int.from_bytes(d[lf+20:lf+22], 'little')
opt = lf + 24
base = opt + optsz
rs = None
for i in range(nsec):
    h = d[base+i*40 : base+i*40+40]
    if h[0:8].rstrip(b'\0') == b'.rsrc':
        rs = (int.from_bytes(h[12:16],'little'), int.from_bytes(h[20:24],'little'))
bad = []
if rs is None:
    print("    no .rsrc section"); sys.exit(1)
Rva, Rb = rs
at = lambda rva, n: d[Rb+(rva-Rva) : Rb+(rva-Rva)+n]

def walk(off, path):
    h = d[Rb+off : Rb+off+16]
    n = int.from_bytes(h[12:14],'little') + int.from_bytes(h[14:16],'little')
    out = []
    for i in range(n):
        e = d[Rb+off+16+i*8 : Rb+off+16+i*8+8]
        eid = int.from_bytes(e[0:4],'little'); eoff = int.from_bytes(e[4:8],'little')
        if eoff & 0x80000000:
            out += walk(eoff & 0x7fffffff, path+[eid])
        else:
            de = d[Rb+eoff : Rb+eoff+16]
            out.append((path+[eid], int.from_bytes(de[0:4],'little'), int.from_bytes(de[4:8],'little')))
    return out

res = {p[0]: (va, sz) for p, va, sz in walk(0, [])}
# RT_MANIFEST (24) must be valid XML that asks for asInvoker, UTF-8 and long paths
if 24 not in res:
    bad.append("no RT_MANIFEST resource")
else:
    man = at(*res[24]).decode('utf-8')
    try:
        ET.fromstring(man)
    except Exception as ex:
        bad.append("manifest is not well-formed XML: %s" % ex)
    for want in ("asInvoker", "UTF-8", "longPathAware"):
        if want not in man:
            bad.append("manifest does not declare %s" % want)
# RT_VERSION (16) must be a VS_VERSIONINFO whose length matches the blob
if 16 not in res:
    bad.append("no RT_VERSION resource")
else:
    v = at(*res[16]); blob = res[16][1]
    def rdnode(b, o):
        wl, wv, wt = struct.unpack_from('<HHH', b, o)
        p = o + 6; k = []
        while True:
            c = struct.unpack_from('<H', b, p)[0]; p += 2
            if c == 0: break
            k.append(chr(c))
        return wl, wv, wt, ''.join(k), (p+3) & ~3
    wl, wv, wt, key, p = rdnode(v, 0)
    if key != "VS_VERSION_INFO": bad.append("version key is %r" % key)
    if wl != blob: bad.append("wLength %d but blob is %d" % (wl, blob))
    if int.from_bytes(v[p:p+4], 'little') != 0xFEEF04BD:
        bad.append("VS_FIXEDFILEINFO signature is wrong")
    seen = {}
    p2 = (p + 52 + 3) & ~3
    while p2 < wl:
        cl, cv, ct, ck, cp = rdnode(v, p2)
        if ck == "StringFileInfo":
            tl, tv, tt, tk, tp = rdnode(v, cp)
            q = tp
            while q < cp + tl:
                sl, sv, st_, sk, sp = rdnode(v, q)
                val = []; r = sp
                while True:
                    c = struct.unpack_from('<H', v, r)[0]; r += 2
                    if c == 0: break
                    val.append(chr(c))
                seen[sk] = ''.join(val)
                q = (q + sl + 3) & ~3
        p2 = (p2 + cl + 3) & ~3
    # The source is hello.w, and a program declares no version. The output
    # file's name (hw.exe) isn't in the block: it used to be, and made the bytes
    # depend on the name the image was written under.
    for k, want in (("ProductName", "hello"), ("FileDescription", "hello"),
                    ("FileVersion", "0.0.0.0"), ("ProductVersion", "0.0.0.0")):
        if seen.get(k) != want:
            bad.append("%s is %r, expected %r" % (k, seen.get(k), want))
    for k in ("InternalName", "OriginalFilename"):
        if k in seen:
            bad.append("version block has %s = %r" % (k, seen[k]))
for b in bad:
    print("    " + b)
sys.exit(1 if bad else 0)
PYEOF
else
  echo "  SKIP: python3 absent or no hello PE (.rsrc contents)"
fi

# The same source gives the same PE whatever file it is written to. The
# version block used to carry the output's name, so the release asset
# (word-windows-x64.exe) differed from a word.exe built from the same commit,
# and `word version` called a renamed word.exe out of step.
if [ -f "$tmp/hw.exe" ] && "$WORD" build -win "$root/examples/hello/hello.w" -o "$tmp/Other-Name.exe" 2>/dev/null \
   && cmp -s "$tmp/hw.exe" "$tmp/Other-Name.exe"; then
  echo "  ok: a PE's bytes do not depend on its output file name"
else
  echo "  FAIL: hello.w built as hw.exe and as Other-Name.exe differ"; fail=1
fi

# --- imports are gated by what the program can reach -------------------------
#
# A hello world used to declare thirteen kernel32 imports, among them
# CreateProcessA, CreateFileA and GetCommandLineA, none of which it can call.
# Each one is something a reader (or an antivirus heuristic) has to account for.
if command -v objdump >/dev/null 2>&1 && [ -f "$tmp/hw.exe" ]; then
  hwimp=$(objdump -x "$tmp/hw.exe" 2>/dev/null)
  miss=""
  for f in GetStdHandle WriteFile VirtualAlloc ExitProcess; do
    printf '%s' "$hwimp" | grep -q "$f" || miss="$miss $f"
  done
  [ -z "$miss" ] && echo "  ok: hello.w imports the four names it needs" \
    || { echo "  FAIL: hello.w is missing$miss"; fail=1; }
  extra=""
  for f in CreateProcessA WaitForSingleObject GetExitCodeProcess CreateFileA ReadFile \
           CloseHandle GetFileSizeEx GetCommandLineA GetEnvironmentStringsA GetModuleFileNameW; do
    printf '%s' "$hwimp" | grep -q "$f" && extra="$extra $f"
  done
  [ -z "$extra" ] && echo "  ok: and none it cannot reach" \
    || { echo "  FAIL: hello.w imports$extra"; fail=1; }

  # ...and each gated feature brings its own back.
  gate_check() { # <label> <source> <required-import>
    printf '%s' "$2" > "$tmp/g.w"
    if "$WORD" build -win "$tmp/g.w" -o "$tmp/g.exe" 2>/dev/null; then
      objdump -x "$tmp/g.exe" 2>/dev/null | grep -q "$3" \
        && echo "  ok: $1 imports $3" \
        || { echo "  FAIL: $1 does not import $3"; fail=1; }
    else
      echo "  SKIP: $1 did not build"
    fi
  }
  gate_check "args()"    'a = args()
out(len(a))
'                                        GetCommandLineA
  gate_check "env()"     'out(env("PATH"))
'                                        GetEnvironmentStringsA
  gate_check "fs.read"   'import fs
out(len(read("x")))
'                                        CreateFileA
  gate_check "sys.exec"  'import sys
exec("x", args())
'                                        CreateProcessA
  gate_check "in()"      'out(ended())
'                                        ReadFile
  # writex opens its file through the same arm fs.read does. A program that
  # called it and nothing from fs used to have no open to call.
  gate_check "sys.writex" 'out(writex("x", bytes(1)))
'                                        CreateFileA
  # sys.image asks Windows where the running executable is (word version).
  gate_check "sys.image" 'out(kind(image()))
'                                        GetModuleFileNameW

  # ...and each piece of sys stays out of a program that doesn't call it. A
  # socket used to bring the exec and file-open arms along, and exec brought the
  # sockets. <names> are matched ignoring case, so ws2_32 is the DLL itself.
  gate_absent() { # <label> <source> <names>
    printf '%s' "$2" > "$tmp/g.w"
    if "$WORD" build -win "$tmp/g.w" -o "$tmp/g.exe" 2>/dev/null; then
      imp=$(objdump -x "$tmp/g.exe" 2>/dev/null); extra=""
      for f in $3; do printf '%s' "$imp" | grep -qi "$f" && extra="$extra $f"; done
      [ -z "$extra" ] && echo "  ok: $1 imports none of $3" \
        || { echo "  FAIL: $1 imports$extra"; fail=1; }
    else
      echo "  SKIP: $1 did not build"
    fi
  }
  gate_absent "a socket-only program" 'ip = bytes(4)
out(connect(ip, 9))
'   "CreateProcessA WaitForSingleObject GetExitCodeProcess CreateFileA"
  gate_absent "an exec-only program" 'l = text(1)
l[0] = 0
x = exec("x", l)
'   "ws2_32 CreateFileA"
  # fs.rename is MoveFileExA, and only a program that writes, appends or renames
  # files has it now.
  gate_absent "a program that only reads files" 'out(len(read("x")))
'   "MoveFileExA"
  gate_check "fs.rename" 'out(rename("x", "y"))
'                                        MoveFileExA
else
  echo "  SKIP: objdump absent (import gating)"
fi

# --- net PE at run time: cross-compile a fetcher that takes a URL, fetch a
# real host over HTTP and HTTPS, and require the Windows PE to get the same body
# length as the Linux build. That runs the whole Windows net stack live: ws2_32
# for DNS, TCP, send and recv, BCryptGenRandom, the now() ->
# GetSystemTimeAsFileTime mapping the certificate date check needs, and the
# trust store. The trust store is the ROOT store only (a PE never reads the PEM
# paths net_ca_paths lists, under wine or on Windows), but this case can't show
# which anchors it used. The sys.cacerts case below and test_win_netconf.sh
# do. It skips when no PE runner is available (as in ci.yml) or the host is
# unreachable, so a flaky network never fails the suite, but a mismatch on a
# reachable host does. ---
if [ -n "$PE_KIND" ]; then
  R=$(win_runner_name)
  printf 'b = get(args()[1])\nif b == none\n    out(0)\nif b != none\n    out(len(b))\n' > "$tmp/nf.w"
  if "$WORD" build "$tmp/nf.w" -o "$tmp/nf_lin" 2>/dev/null && "$WORD" build -win "$tmp/nf.w" -o "$tmp/nf.exe" 2>/dev/null; then
    net_probe() { # <label> <url> [any]
      # With `any`, the host's body isn't the same on every request (several
      # servers answer for api.github.com, and their JSON differs), so a fetch
      # passes when it brings back a body. A failed handshake answers none (0).
      lab="$1"; url="$2"
      L=$(timeout 60 "$tmp/nf_lin" "$url" 2>/dev/null)
      W=$(pe_run 120 "$tmp/nf.exe" "$url" 2>/dev/null)
      if [ -z "$L" ] || [ "$L" = 0 ]; then echo "  SKIP: $lab (host unreachable from the Linux build)"; return; fi
      if [ "$W" = "$L" ]; then echo "  ok: $lab -> PE fetched $W bytes (== Linux)"
      elif [ "$3" = any ] && [ -n "$W" ] && [ "$W" != 0 ]; then echo "  ok: $lab -> PE fetched $W bytes (Linux $L; this host's body varies)"
      else echo "  FAIL: $lab -> PE got [$W], Linux got [$L]"; fail=1; fi
    }
    net_probe "http  fetch under $R"  "http://example.com/"
    # Two hosts for the HTTPS probe. api.github.com chains to DigiCert Global
    # Root G2, which every Windows ROOT store has.
    #
    # example.com chains to "SSL.com TLS ECC Root CA 2022", which a stock
    # Windows ROOT store doesn't carry (Windows fetches roots on demand through
    # CertGetCertificateChain, which word doesn't use), so its path goes through
    # the cross-signed copy of that root (signed sha256WithRSAEncryption) up to
    # "AAA Certificate Services". That anchor is self-signed with SHA-1, and
    # x509_parse used to refuse it for that, so net_load_roots dropped an anchor
    # the chain needed (19 of the 53 anchors on the Windows machine where this
    # was found went the same way). An anchor's own self-signature isn't a link
    # in the path (RFC 5280 6.1.1). example.com is the case that fails if that
    # regresses.
    net_probe "https fetch under $R (TLS 1.3 + chain verification)" "https://api.github.com/" any
    net_probe "https fetch under $R (anchored on a SHA-1 self-signed root)" "https://example.com/"
  else
    echo "  SKIP: net fetcher did not build"
  fi
fi

# --- sys.cacerts(): the ROOT store, where Windows keeps its trust anchors.
# Linux keeps them in a PEM file that net.w reads with fs.read. Windows ships no
# such file, so without this a verifying https:// fetch there would have an
# empty trust store and fail closed. The structural half runs everywhere, CI
# included: a program that asks for the store imports crypt32, and no other
# program does. ---
echo "Windows trust store (sys.cacerts):"
printf 'import sys\nb = cacerts()\nn = 0\ni = 0\nloop i + 4 <= len(b)\n    l = b[i] + b[i + 1] * 256 + b[i + 2] * 65536 + b[i + 3] * 16777216\n    i = i + 4 + l\n    if i > len(b)\n        err("a length ran past the end of the store")\n    n = n + 1\nout("" . n . " " . len(b))\n' > "$tmp/ca.w"
if "$WORD" build -win "$tmp/ca.w" -o "$tmp/ca.exe" 2>"$tmp/err"; then
  if command -v objdump >/dev/null 2>&1; then
    objdump -x "$tmp/ca.exe" 2>/dev/null | grep -qi 'crypt32.dll' \
      && echo "  ok: a program that calls cacerts() imports crypt32" \
      || { echo "  FAIL: cacerts() built without a crypt32 import"; fail=1; }
    objdump -x "$tmp/hw.exe" 2>/dev/null | grep -qi 'crypt32.dll' \
      && { echo "  FAIL: a program that never asks for the trust store imports crypt32"; fail=1; } \
      || echo "  ok: a program that does not call it imports no crypt32"
  else
    echo "  SKIP: objdump not present (import check)"
  fi
  if [ -n "$PE_KIND" ]; then
    out=$(pe_run 120 "$tmp/ca.exe" 2>/dev/null)
    n=${out%% *}; b=${out##* }
    if [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null; then
      echo "  ok: $n certificates ($b bytes) from the ROOT store under $(win_runner_name)"
    else
      echo "  FAIL: the ROOT store came back empty [$out]"; fail=1
    fi
  else
    echo "  SKIP: no way to run a PE here; import check only"
  fi
else
  echo "  FAIL: cacerts() did not build for -win:"; sed 's/^/    /' "$tmp/err"; fail=1
fi

# --- sys.nameservers(): the DNS resolvers, which Windows lists through
# GetNetworkParams and not in a file. On Windows, /etc/resolv.conf names a file
# under the root of the current drive, where any signed-in user can create a
# directory. The structural half runs everywhere: a program that asks imports
# iphlpapi, and no other program does. At run time every line it answers must
# be a dotted quad. test_win_netconf.sh checks natively which resolver net
# then uses, and that nothing at the drive root is read instead. ---
echo "Windows resolvers (sys.nameservers):"
printf 'import sys\nb = nameservers()\nout(kind(b))\nout(decode(b))\n' > "$tmp/ns.w"
if "$WORD" build -win "$tmp/ns.w" -o "$tmp/ns.exe" 2>"$tmp/err"; then
  if command -v objdump >/dev/null 2>&1; then
    objdump -x "$tmp/ns.exe" 2>/dev/null | grep -qi 'iphlpapi.dll' \
      && echo "  ok: a program that calls nameservers() imports iphlpapi" \
      || { echo "  FAIL: nameservers() built without an iphlpapi import"; fail=1; }
    objdump -x "$tmp/hw.exe" 2>/dev/null | grep -qi 'iphlpapi.dll' \
      && { echo "  FAIL: a program that never asks for a resolver imports iphlpapi"; fail=1; } \
      || echo "  ok: a program that does not call it imports no iphlpapi"
  else
    echo "  SKIP: objdump not present (import check)"
  fi
  if [ -n "$PE_KIND" ]; then
    out=$(pe_run 60 "$tmp/ns.exe" 2>/dev/null | tr -d '\r')
    k=$(printf '%s\n' "$out" | sed -n 1p)
    addrs=$(printf '%s\n' "$out" | sed '1d' | sed '/^$/d')
    if [ "$k" != bytes ]; then
      echo "  FAIL: nameservers() answered [$k] under $(win_runner_name), not bytes"; fail=1
    elif [ -n "$addrs" ] && printf '%s\n' "$addrs" | grep -qvE '^([0-9]{1,3}[.]){3}[0-9]{1,3}$'; then
      echo "  FAIL: nameservers() listed something that is not a dotted quad: [$addrs]"; fail=1
    else
      echo "  ok: nameservers() lists $(printf '%s' "$addrs" | grep -c .) resolver(s) under $(win_runner_name): [$(echo $addrs)]"
    fi
  else
    echo "  SKIP: no way to run a PE here; import check only"
  fi
else
  echo "  FAIL: nameservers() did not build for -win:"; sed 's/^/    /' "$tmp/err"; fail=1
fi

# --- env() names are case-insensitive on Windows ---
# Windows treats Path and PATH as one variable, so env() matches an ASCII letter
# in either case there (Linux names are case-sensitive; test_lang.sh has that
# half). It used to compare bytes, and env("Path") was none when the block said
# PATH. WSLENV carries the variable across when the runner is WSL interop.
printf 'out(env("WORD_ENV_CASE"))\nout(env("word_env_case"))\nout(env("Word_Env_Case"))\nout(env("WORD_ENV_CAS") == none)\nout(env("WORD_ENV_CASEX") == none)\n' > "$tmp/ec.w"
if "$WORD" build -win "$tmp/ec.w" -o "$tmp/ec.exe" 2>"$tmp/err"; then
  if [ -n "$PE_KIND" ]; then
    o=$(export WORD_ENV_CASE=yes WSLENV="${WSLENV:+$WSLENV:}WORD_ENV_CASE"; pe_run 60 "$tmp/ec.exe" 2>&1 | tr -d '\r' | tr '\n' ' ')
    [ "$o" = "yes yes yes true true " ] && echo "  ok: env() finds WORD_ENV_CASE by any case under $(win_runner_name)" \
      || { echo "  FAIL: env() by another case under $(win_runner_name) printed [$o]"; fail=1; }
  else
    echo "  SKIP: no way to run a PE here; env() case check"
  fi
else
  echo "  FAIL: env() program did not build for -win:"; sed 's/^/    /' "$tmp/err"; fail=1
fi

echo "test_win_pe: FAIL=$fail"
[ "$fail" = 0 ]
