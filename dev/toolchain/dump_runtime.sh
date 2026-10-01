#!/bin/sh
# dump_runtime.sh: print the runtime the compiler embeds in programs, as
# assembly.
#
# The runtime lives in compiler/word.w as asmput("...") strings. That's the
# right place for it (it's emitted, not linked), but a wall of quoted
# instructions is hard to read. This builds a probe program and slices the
# runtime block out of its assembly, so you can read the code itself.
#
# It writes to stdout by default, or to a file given as the first argument. No
# copy of the output is kept in the tree: it's derived from compiler/word.w, and
# a committed copy goes stale (the last one was several generations behind and
# had none of the float paths).
#
#     sh dev/toolchain/dump_runtime.sh                    # x86-64, to stdout
#     sh dev/toolchain/dump_runtime.sh -arm64             # arm64, to stdout
#     sh dev/toolchain/dump_runtime.sh rt.s               # x86-64, to a file
#     sh dev/toolchain/dump_runtime.sh -arm64 rt.s
#
# The probe below reaches floats, fs reads, stdin and the map/JSON runtime. A
# real build emits only the blocks its program reaches, so the probe has to
# keep up with the gates: when maps went in, the probe didn't reach the new
# map/JSON gate, and rt_map_*, rt_json_* and friends were missing from the dump
# without anyone noticing. It doesn't reach the file writer (write, append,
# rename), the sys pieces (emit buffer, writex, exec, sockets) or anything net
# uses, so those aren't in the dump. The Windows layer is target-specific and
# isn't part of it either.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
cd "$root"
arch=""
if [ "$1" = "-arm64" ]; then arch="-arm64"; shift; fi
out_rt="$1"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/probe.w" <<'WEOF'
import fs
import json
f = 1.5
out(f)
out(len(read("/etc/hostname")))
out(in())
o = {k: 1}
o["k"] = len(keys(o)) + len(array(1))
out(has(o, "k"))
out(stringify(parse(stringify(o))))
WEOF

./word build -asm $arch "$tmp/probe.w" > "$tmp/probe.s"

python3 - "$tmp/probe.s" "$tmp/rt.s" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split('\n')
def find(pred, start=0):
    for i in range(start, len(lines)):
        if pred(lines[i]): return i
    raise SystemExit("dump_runtime: marker not found")
rt_s = find(lambda l: l.startswith('rt_init:'))
rt_e = find(lambda l: l.startswith('fn_'), rt_s)
open(dst, 'w').write('\n'.join(lines[rt_s:rt_e]).rstrip('\n') + '\n')
PYEOF

if [ -n "$out_rt" ]; then cp "$tmp/rt.s" "$out_rt"; else cat "$tmp/rt.s"; fi
