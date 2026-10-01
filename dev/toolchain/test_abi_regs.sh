#!/bin/sh
# test_abi_regs.sh: no runtime function may clobber a callee-saved register.
#
# The register-pinning pass keeps a function's hottest integers in rbx and
# r12-r15 on x86-64 (callee-saved in the System V ABI), across every call the
# function makes. The arm64 code generator pins nothing, but the runtime's own
# helpers keep values in x19-x28 (callee-saved in the AArch64 ABI) across the
# helpers they call. A runtime helper that overwrites one of them gives a
# wrong answer.
#
# A helper that only runs on a path your CPU never takes, like a software
# fallback behind a feature check or an error branch, can clobber a register
# for years without anyone seeing it, and then be wrong on someone else's
# processor.
#
# dump_runtime.sh generates the assembly on each run, so the check sees what
# the compiler emits now.
#
# The check is textual and blunt: inside every top-level function, an
# instruction whose destination is a callee-saved register must come after a
# save of that register in the same function. Reads, compares and restores
# don't count. A false positive is fixed by saving the register.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
cd "$root"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not on PATH"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

sh "$here/dump_runtime.sh" "$tmp/x86.s"
sh "$here/dump_runtime.sh" -arm64 "$tmp/a64.s"

python3 - "$tmp/x86.s" "$tmp/a64.s" <<'PYEOF'
import re, sys

def norm_x86(r):
    if r in ('ebx', 'bx', 'bl'): return 'rbx'
    if re.match(r'^r1[2-5][dwb]$', r): return r[:-1]
    return r

def norm_a64(r):
    if re.match(r'^w(19|2[0-8])$', r): return 'x' + r[1:]
    return r

X86 = dict(
    cs={'rbx', 'r12', 'r13', 'r14', 'r15'},
    norm=norm_x86,
    skip={'cmp', 'test', 'push', 'pop', 'call', 'ret', 'jmp'},
    # push rbx / pop rbx
    save=re.compile(r'^push\s+(\w+)$'),
    saves=lambda m: [m.group(1)],
)
A64 = dict(
    cs={'x%d' % n for n in range(19, 29)},
    norm=norm_a64,
    # cmp/cmn/tst write only flags; b*/cb*/tb* are branches; str/stp/ret read.
    skip={'cmp', 'cmn', 'tst', 'str', 'strb', 'strh', 'stp', 'stur', 'sturb', 'ret', 'b', 'bl', 'br', 'blr', 'svc', 'nop'},
    # stp x19, x20, [sp, #-16]!  /  str x19, [sp, #-16]!
    save=re.compile(r'^st[pr]\s+(\w+)(?:,\s*(\w+))?,\s*\[sp'),
    saves=lambda m: [g for g in m.groups() if g],
)

bad = []
for path, spec in ((sys.argv[1], X86), (sys.argv[2], A64)):
    fn = None
    saved = set()
    for ln, raw in enumerate(open(path).read().split('\n'), 1):
        t = raw.split('#')[0].split('//')[0].strip()
        if not t:
            continue
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):\s*$', t)
        if m:
            fn = m.group(1); saved = set(); continue
        if t.startswith('.'):
            continue
        ms = spec['save'].match(t)
        if ms:
            for g in spec['saves'](ms):
                g = spec['norm'](g)
                if g in spec['cs']:
                    saved.add(g)
            continue
        mi = re.match(r'^(\w+)\s+(\w+)\s*(,|$)', t)
        if not mi:
            continue
        op, dst = mi.group(1), mi.group(2)
        if op in spec['skip'] or op.startswith('j') or op.startswith('b.'):
            continue
        d = spec['norm'](dst)
        if d in spec['cs'] and d not in saved:
            bad.append("%s:%d  %s clobbers %s  ->  %s" % (path, ln, fn, d, t))

# If the dump changed shape and the scrape found almost nothing, the suite
# would pass without checking anything.
lines = sum(len(open(p).read().split('\n')) for p in sys.argv[1:])
if lines < 1000:
    print("test_abi_regs: FAIL (scraped only %d lines of runtime)" % lines)
    raise SystemExit(1)

if bad:
    print("test_abi_regs: FAIL -- %d callee-saved clobber(s)" % len(bad))
    for b in bad:
        print("  " + b)
    raise SystemExit(1)
print("test_abi_regs: PASS (%d lines; no runtime function clobbers rbx/r12-r15 or x19-x28)" % lines)
PYEOF
