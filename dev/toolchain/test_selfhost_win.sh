#!/bin/sh
# test_selfhost_win.sh: the Windows self-hosting fixed point.
#
# The Linux word cross-compiles compiler/word.w to word.exe with `build -win`.
# Then word.exe itself, run under wine or through WSL interop (see
# win_runner.sh), rebuilds compiler/word.w with `build -win`, and the result
# must be byte-identical to word.exe. It's the Windows version of `word
# verify`: word.exe, running as a Windows program, reproduces itself byte for
# byte.
# The suite also checks that word.exe can build and run small programs.
#
# wine and WSL interop are only used to run the output, like GNU as and
# openssl elsewhere; nothing needs them to build word or a word program. CI
# installs neither, so in ci.yml the PE gets the objdump check and the runtime
# checks skip. windows.yml runs word.exe natively.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$root"   # word / word.exe read compiler/word.w and examples/ by relative path
fail=0
# win_runner.sh finds a way to run a PE: natively on Windows, under wine, or
# through WSL interop, which hands the PE to Windows itself. pe_path spells an
# output path the way the PE will read it (unchanged under wine, a Windows path
# under interop, where the process is a Windows process).
. "$here/win_runner.sh"
win_runner_init "$tmp"

echo "Windows self-hosting (word.exe):"
# 1) Linux word cross-compiles word.w -> word.exe
"$WORD" build -win compiler/word.w -o "$tmp/word.exe" 2>"$tmp/err" \
  || { echo "  FAIL: cross-compile word.w -> word.exe:"; sed 's/^/    /' "$tmp/err"; exit 1; }
if command -v objdump >/dev/null 2>&1; then
  objdump -f "$tmp/word.exe" 2>/dev/null | grep -q 'pei-x86-64' \
    && echo "  ok: word.w cross-compiles to a PE64 word.exe" \
    || { echo "  FAIL: word.exe is not a PE64"; fail=1; }
fi

# Try the runner on a PE the Linux word built before trusting it with the
# compiler, so a runner that can't run hello.exe skips instead of failing
# everything.
if [ -n "$PE_KIND" ]; then
  "$WORD" build -win examples/hello/hello.w -o "$tmp/probe.exe" 2>/dev/null
  win_runner_probe "$tmp/probe.exe" "Hello, word!" || true
fi
if [ -n "$PE_KIND" ]; then
  R=$(win_runner_name)
  # 2) word.exe builds and runs a small program.
  #
  # The report says which step failed: the build exiting nonzero, the build
  # writing nothing, or the program running but printing the wrong thing.
  build_and_run() { # <label> <out.exe> <build args...>
    lab="$1"; oexe="$2"; shift 2
    rm -f "$oexe"
    if ! pe_run 120 "$tmp/word.exe" "$@" -o "$(pe_path "$oexe")" 2>"$tmp/berr"; then
      echo "  FAIL: $lab -- word.exe exited nonzero: $(head -1 "$tmp/berr")"; fail=1; return
    fi
    if [ ! -f "$oexe" ]; then
      echo "  FAIL: $lab -- word.exe reported success but wrote no $oexe"; fail=1; return
    fi
    o=$(pe_run 60 "$oexe" 2>"$tmp/rerr"); rrc=$?
    if [ "$o" = "Hello, word!" ]; then
      echo "  ok: $lab"
    elif [ "$rrc" != 0 ] && [ -z "$o" ]; then
      echo "  FAIL: $lab -- built fine ($(wc -c <"$oexe") bytes) but would not run (rc=$rrc): $(head -1 "$tmp/rerr")"; fail=1
    else
      echo "  FAIL: $lab -- ran but printed [$o]"; fail=1
    fi
  }
  build_and_run "word.exe builds+runs hello.w under $R" "$tmp/hello.exe" build -win examples/hello/hello.w
  # 3) the fixed point: word.exe rebuilds word.w with -win, byte-identical to
  #    word.exe.
  #
  # The rebuild is written under a different name. A PE's bytes don't depend on
  # the file it's written to, which lets the release asset,
  # word-windows-x64.exe, match a word.exe built anywhere else.
  if pe_run 300 "$tmp/word.exe" build -win compiler/word.w -o "$(pe_path "$tmp/word-windows-x64.exe")" 2>/dev/null \
     && cmp -s "$tmp/word.exe" "$tmp/word-windows-x64.exe"; then
    echo "  ok: word.exe rebuilds word.exe byte-identically (Windows fixed point)"
  else
    echo "  FAIL: word.exe self-rebuild not byte-identical"; fail=1
  fi
  # ...so a renamed word.exe is still in step with its source. It used to report
  # out of step, because `word version` rebuilt under the name word.exe and
  # compared that with an image built under another name. Under WSL interop
  # argv[0] is a Linux path the process can't open, so it can't read its own
  # image and the check skips. windows.yml makes the same check natively.
  vout=""
  [ -f "$tmp/word-windows-x64.exe" ] && { vout=$(pe_run 300 "$tmp/word-windows-x64.exe" version 2>&1) || :; }
  case "$vout" in
    *"in step"*yes*) echo "  ok: word-windows-x64.exe version says in step" ;;
    *"cannot read it back"*) echo "  SKIP: word-windows-x64.exe cannot read its own image under $R" ;;
    *) echo "  FAIL: word-windows-x64.exe version did not say in step: $(printf '%s' "$vout" | tail -3)"; fail=1 ;;
  esac
  # 4) word.exe with no -win or -linux builds for its own host (Windows), so
  #    `build hello.w` gives a runnable PE.
  build_and_run "word.exe build (no flag) defaults to the Windows target" "$tmp/nd.exe" build examples/hello/hello.w
  # 5) word run on Windows: build for the host, then spawn via CreateProcessA.
  if [ "$(pe_run 120 "$tmp/word.exe" run examples/hello/hello.w 2>/dev/null)" = "Hello, word!" ]; then
    echo "  ok: word.exe run executes the program (CreateProcessA + wait)"
  else
    echo "  FAIL: word.exe run did not print 'Hello, word!'"; fail=1
  fi
  # 6) word run forwards args (child argv via the rebuilt command line).
  if [ "$(pe_run 120 "$tmp/word.exe" run examples/greet/greet.w Ada 2>/dev/null)" = "Hello, Ada!" ]; then
    echo "  ok: word.exe run forwards args (greet Ada -> 'Hello, Ada!')"
  else
    echo "  FAIL: word.exe run did not forward args"; fail=1
  fi
  # 7) console input with CRLF line endings: rpg must accept a piped '2' choice
  #    (the child inherits word.exe's stdin via forwarded std handles).
  crlf=$(printf '2\r\n2\r\n2\r\n2\r\n2\r\n' | pe_run 120 "$tmp/word.exe" run examples/rpg/rpg.w 2>/dev/null | grep -c "Rogue draws a blade")
  if [ "$crlf" -ge 1 ] 2>/dev/null; then
    echo "  ok: CRLF console input reads correctly (rpg accepts a piped '2' choice)"
  else
    echo "  FAIL: CRLF console input not handled (rpg rejected the choice)"; fail=1
  fi
else
  echo "  SKIP: no way to run a PE here (wine absent, not WSL); structural check only"
fi

echo "test_selfhost_win: FAIL=$fail"
[ "$fail" = 0 ]
