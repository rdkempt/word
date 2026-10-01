#!/bin/sh
# test_readall.sh: read() returns the whole file, including one whose size the
# kernel reports as zero.
#
# Files under /proc, like /proc/version, report 0 bytes and still have content.
# SPEC 12.1 gives read() two outcomes, the whole file or none, and an empty
# region for a file that opened fine is neither. read() used to return one on
# both targets. The suite also checks that reading a directory is none on both.
#
# READALL_PAD makes the growth path deterministic. A zero-size file starts with
# a 4 KB buffer, so 30 KB of padding in the environment makes /proc/self/environ
# outgrow it at least three times. The padding is all one byte, so the program
# can check every byte that was copied into a bigger buffer, not just the count.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

PAD=$(awk 'BEGIN{ s=""; while (length(s) < 30000) s = s "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"; print s }')
export READALL_PAD="$PAD"

fail=0
if ! "$WORD" build "$here/readall_test.w" -o "$tmp/readall" >"$tmp/err" 2>&1; then
  echo "  FAIL: x86-64 build"; sed 's/^/    /' "$tmp/err"; fail=1
else
  rc=0; (cd "$tmp" && ./readall) || rc=$?; [ "$rc" = 0 ] || fail=1
fi

QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
if [ -n "$QEMU" ]; then
  if ! "$WORD" build -arm64 "$here/readall_test.w" -o "$tmp/readall.a64" >"$tmp/err" 2>&1; then
    echo "  FAIL: arm64 build"; sed 's/^/    /' "$tmp/err"; fail=1
  else
    rc=0; (cd "$tmp" && $QEMU ./readall.a64 > a64.txt 2>&1) || rc=$?
    sed 's/^/  arm64: /' "$tmp/a64.txt"
    [ "$rc" = 0 ] || fail=1
  fi
else
  echo "  skip: no qemu-aarch64, arm64 rt_read not exercised"
fi

[ "$fail" = 0 ] || { echo "read(): FAILED"; exit 1; }
echo "read(): whole-file reads OK on every target checked"
