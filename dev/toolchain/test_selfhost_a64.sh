#!/bin/sh
# test_selfhost_a64.sh: word self-hosting on AArch64. The x86-64 word
# cross-compiles compiler/word.w to an arm64 word, that binary rebuilds itself
# from the same source, and the result must be byte-identical. It's the fixed
# point test_selfhost.sh checks for the native binary, and it's what "word runs
# on arm64" has to mean: the compiler compiles itself there.
#
# qemu-user is a dev/CI oracle only, like GNU as and llvm-mc elsewhere: nothing
# in a word build needs it. On an arm64 host the binaries run directly.
#
# Under qemu-user, `word run` can build but can't start what it built: its
# execve hands an arm64 ELF to an x86-64 kernel, which fails with ENOEXEC unless
# binfmt_misc is registered for arm64. That's down to the machine running the
# test, so the run case at the end takes "exec failed" as well as the output.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
cd "$root"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

"$WORD" build -arm64 compiler/word.w -o "$tmp/word.a64" || { echo "FAIL: cross-compile to arm64"; exit 1; }
chmod +x "$tmp/word.a64"

mach=$(od -An -tu1 -j18 -N1 "$tmp/word.a64" | tr -d ' \n')
[ "$mach" = "183" ] || { echo "FAIL: e_machine is $mach, want 183 (EM_AARCH64)"; exit 1; }

# The -asm round trip (SPEC 14) for the largest program there is. word.w's text
# is several times the +/-1 MB a conditional branch reaches, so hundreds of
# its branches have to be relaxed. `word asm -arm64` used to assemble once and
# leave each of those as a branch to itself, so the result differed from the
# direct build and hung where that one ran.
"$WORD" build -arm64 -asm compiler/word.w > "$tmp/word.s" \
  && "$WORD" asm -arm64 "$tmp/word.s" "$tmp/word.via" \
  || { echo "FAIL: build -arm64 -asm then asm -arm64 errored"; exit 1; }
cmp -s "$tmp/word.a64" "$tmp/word.via" \
  || { echo "FAIL: word.w through -asm and asm -arm64 differs from the direct arm64 build"; exit 1; }
echo "arm64 -asm round trip: word.w reassembles to the direct build, relaxed branches included"

QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
if [ -z "$QEMU" ]; then
  echo "SKIP: cross-compiled a $(wc -c < "$tmp/word.a64")-byte arm64 word; no qemu-aarch64 to run it"
  exit 0
fi

$QEMU "$tmp/word.a64" build -arm64 compiler/word.w -o "$tmp/word.a64.2" \
  || { echo "FAIL: the arm64 word could not rebuild itself"; exit 1; }

if cmp -s "$tmp/word.a64" "$tmp/word.a64.2"; then
  echo "arm64 self-hosting: the arm64 word rebuilds itself byte-identically ($(wc -c < "$tmp/word.a64") bytes)"
else
  echo "FAIL: the arm64 word rebuilt itself into DIFFERENT bytes"
  ls -l "$tmp/word.a64" "$tmp/word.a64.2"
  exit 1
fi

# `version` runs its own fixed-point check. The arm64 word must report itself in
# step, with linux arm64 as its host target.
$QEMU "$tmp/word.a64" version > "$tmp/ver.txt" 2>&1 || true
grep -q "in step          yes" "$tmp/ver.txt" || {
  echo "FAIL: the arm64 word does not report itself in step"; cat "$tmp/ver.txt"; exit 1; }
grep -q "host target      linux arm64" "$tmp/ver.txt" || {
  echo "FAIL: the arm64 word does not default to the arm64 target"; cat "$tmp/ver.txt"; exit 1; }
echo "arm64 self-hosting: it reports itself in step, and defaults to the arm64 target"

# `run` takes a target flag only when it names this host: here that is -arm64,
# and -linux (x86-64, as it is for build) is refused. -arm64 used to be read as
# the source ("cannot read -arm64"), and -linux built and ran arm64. Without
# binfmt_misc for arm64 the accepted run ends in "exec failed" (see the top).
printf 'out("hi")\n' > "$tmp/hi.w"
rc=0; got=$($QEMU "$tmp/word.a64" run -linux "$tmp/hi.w" 2>&1) || rc=$?
case "$got" in
  *"-linux builds for linux x86-64, and this host is linux arm64"*) [ "$rc" = 1 ] || {
    echo "FAIL: run -linux on arm64 exits $rc, want 1"; exit 1; } ;;
  *) echo "FAIL: run -linux on arm64 was not refused: $got"; exit 1 ;;
esac
rc=0; got=$($QEMU "$tmp/word.a64" run -arm64 "$tmp/hi.w" 2>&1) || rc=$?
case "$got" in
  hi|*"exec failed: "*) ;;
  *) echo "FAIL: run -arm64 on arm64 was not taken as this host: $got"; exit 1 ;;
esac
echo "arm64 run: -arm64 names this host, and -linux is refused"
