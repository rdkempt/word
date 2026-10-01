#!/bin/sh
# test_suites.sh: every suite runs the cases it has.
#
# A suite without `set -e` that calls a function before defining it just prints
# "not found" and carries on, so the case never runs and the suite stays green.
# test_float.sh had a case like that. Two things are checked about the suites
# themselves, by reading them, because neither shows up as a failure:
#
#   1. no shell function is called on a line before the line that defines it;
#   2. every dev/toolchain/test_*.sh is run by a workflow, or by a suite that is.
#
# It needs python3, which is only a test tool: nothing needs it to build or run
# word.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
cd "$root"
command -v python3 >/dev/null 2>&1 || { echo "test_suites: SKIP (no python3)"; exit 0; }

python3 - <<'PY'
import glob, os, re, sys

fail = 0
suites = sorted(glob.glob("dev/toolchain/*.sh") + glob.glob("dev/benchmarks/*.sh"))

# 1. A function used before it is defined. Heredoc bodies are skipped: they are
# programs and fixtures, not shell.
checked = 0
for f in suites:
    lines = open(f, encoding="utf-8", errors="replace").read().split("\n")
    defs = {}
    for i, l in enumerate(lines):
        m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{", l)
        if m and m.group(1) not in defs:
            defs[m.group(1)] = i
    heredoc = None
    for i, l in enumerate(lines):
        if heredoc is not None:
            if l.strip() == heredoc:
                heredoc = None
            continue
        for name, d in defs.items():
            if i < d and re.match(r"^\s*(?:(?:if|then|else|elif|do|!)\s+)*" + re.escape(name) + r"(?:\s|$)", l):
                print("  FAIL: %s:%d calls %s, which is defined at line %d" % (f, i + 1, name, d + 1))
                fail += 1
        m = re.search(r"<<-?\s*['\"]?([A-Za-z_]+)['\"]?", l)
        if m:
            heredoc = m.group(1)
    checked += 1
if fail == 0:
    print("  ok: no suite calls a function before defining it (%d files)" % checked)

# 2. Every test_*.sh is run by a workflow, or by a suite that is.
runners = ""
for w in glob.glob(".github/workflows/*.yml"):
    runners += open(w, encoding="utf-8").read()
names = [os.path.basename(f) for f in glob.glob("dev/toolchain/test_*.sh")]
# a suite also counts as run when a suite that is run invokes it
reached = {n for n in names if n in runners}
changed = True
while changed:
    changed = False
    for n in list(reached):
        body = open("dev/toolchain/" + n, encoding="utf-8", errors="replace").read()
        for m in names:
            if m not in reached and m in body:
                reached.add(m)
                changed = True
orphans = sorted(set(names) - reached)
for n in orphans:
    print("  FAIL: dev/toolchain/%s is not run by any workflow" % n)
    fail += 1
if not orphans:
    print("  ok: every one of %d suites is run by a workflow" % len(names))

print("test_suites: %s" % ("PASS" if fail == 0 else "FAIL=%d" % fail))
sys.exit(1 if fail else 0)
PY
