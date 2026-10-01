#!/bin/sh
# test_bootstrap_seed.sh: diverse double-compilation. The Python seed rebuilds
# the committed binary.
#
# `word verify` checks that the committed binary reproduces itself from its own
# source. It can't show the binary is what that source says, because the binary
# is the one doing the checking. This test checks from outside: a compiler
# written in Python (bootstrap/), sharing no code with word, compiles
# compiler/word.w into word_A, word_A compiles compiler/word.w into word_B, and
# word_B has to be byte-identical to the committed ./word.
#
# word_A isn't byte-identical to ./word and isn't meant to be: it's the same
# compiler built by a different one, so its own bytes differ. What has to match
# is what it emits, and that's word_B.
#
# Two independent assemblers are used on the way: the Python one in
# bootstrap/asm_link.py and, when GNU as and ld are on PATH, those. A bug would
# have to be in both to get through.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
cd "$root"
[ -x ./word ] || { echo "FAIL: no ./word binary (see docs/BOOTSTRAP.md)"; exit 1; }
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 0; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

echo "seed: python3 bootstrap/wordc.py compiler/word.w -o word_A"
python3 bootstrap/wordc.py compiler/word.w -o "$tmp/word_A"

echo "word_A build compiler/word.w -o word_B"
"$tmp/word_A" build compiler/word.w -o "$tmp/word_B"

cmp "$tmp/word_B" ./word || { echo "FAIL: word_B != committed ./word"; exit 1; }
echo "OK: the Python seed reproduces the committed ./word byte for byte"

# The same emitted assembly, assembled by GNU as/ld instead. Only the seed's
# own bytes change, and what it emits mustn't.
if command -v as >/dev/null && command -v ld >/dev/null; then
    echo "second opinion: same seed via GNU as/ld"
    python3 bootstrap/wordc.py compiler/word.w --binutils -o "$tmp/word_A_gnu"
    "$tmp/word_A_gnu" build compiler/word.w -o "$tmp/word_B_gnu"
    cmp "$tmp/word_B_gnu" ./word || { echo "FAIL: GNU-assembled seed did not reproduce ./word"; exit 1; }
    echo "OK: GNU-assembled seed reproduces the committed ./word too"
else
    echo "skip: GNU as/ld not on PATH"
fi
