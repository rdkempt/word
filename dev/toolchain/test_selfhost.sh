#!/bin/sh
# test_selfhost.sh: the self-hosting fixed point.
#
# `word verify` has the committed ./word rebuild itself from compiler/word.w
# (compile, assemble and link, all in word, with no Python and no as/ld) and
# checks that the result is byte-identical to ./word. The compiler is the
# largest program word compiles, and this proves the binary reproduces from its
# own source.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
cd "$root"
[ -x ./word ] || { echo "FAIL: no ./word binary (see docs/BOOTSTRAP.md)"; exit 1; }
./word verify
