#!/bin/sh
# test_doc_examples.sh: the programs in README.md and SPEC.md section 13 run and
# print what the text around them says they print.
#
# Every ```javascript block in README.md and in SPEC 13 is taken from the
# document as it is now, built, and run on x86-64 and on arm64 (under qemu), or
# natively when WORD is a Windows word.exe. A line such as
#
#     out(7 / 2)          // 3.5    it does not, so the answer is a float
#
# states its output, and that value is read from the comment: the text after
# `// ` up to two spaces or a ` -- `. Where the output is stated in prose
# instead (FizzBuzz, a sort, a contract that stops the program, a file that is
# not there), the table below pins it, along with the stdin, arguments and
# files a run needs. A block the table does not know about fails the suite, so
# a new example can't be added without saying what it should do. The table can
# also name a SPEC example outside section 13, as it does for 8.3.
#
# SPEC 13.10 tested a failed read with `text == 0` for a long time after a
# failed read became `none`. Nothing ran the section, so nothing noticed.
#
# python3 reads the documents and drives the runs. It is a dev/CI oracle here,
# the same as in test_suites.sh; word itself never needs it.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
. "$here/hostpath.sh"; root=$(hostpath "$root")
WORD=$(wordbin "${WORD:-$root/word}")
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
WORD=$(hostpath "$WORD")
PY=$(command -v python3 || command -v python || true)
[ -n "$PY" ] || { echo "test_doc_examples: SKIP (no python3)"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=native;; esac
case "$WORD" in *.exe|*.EXE) QEMU="";; esac

PYTHONIOENCODING=utf-8 DOC_ROOT="$root" DOC_WORD="$WORD" DOC_TMP="$(hostpath "$tmp")" DOC_QEMU="$QEMU" \
  "$PY" - <<'PY'
import os, re, subprocess, sys

root = os.environ["DOC_ROOT"]; word = os.environ["DOC_WORD"]
tmp = os.environ["DOC_TMP"]; qemu = os.environ.get("DOC_QEMU", "")
windows = word.lower().endswith(".exe")

def fizzbuzz(n):
    r = []
    for i in range(1, n + 1):
        r.append("FizzBuzz" if i % 15 == 0 else "Fizz" if i % 3 == 0 else "Buzz" if i % 5 == 0 else str(i))
    return "\n".join(r)

# What each block needs to run, and the output it has to give where the block
# does not state all of it in `// value` comments.
#
#   stdout  the whole of stdout, one string; absent means "the values in the
#           comments, in order"
#   stderr  a substring stderr must hold
#   exit    the exit status (0 when absent)
#   stdin, args, files  what the run is given; a file whose content is None is
#           created as a directory
#   after   files that must hold this content after the run (None: must not exist)
#   after_block  run the named block first, in the same program
#   before  code put in front of the block
#   append  code added after the block, to observe what it computes
#   prose   comments on out() lines that describe rather than state a value
#   build_only  the reason the block is built but not run
#
# SPEC 13 blocks are named by section. README blocks are named by their first
# line (its code, or the whole line when it is a comment), since the README has
# no section numbers.
SPEC_CASES = {
    "13.1": {"runs": [{"stdout": "hello"}]},
    # The SPEC doesn't state it: 1 + 2 + ... + 10 is 55, which is more than 50.
    "13.2": {"runs": [{"stdout": "55"}]},
    "13.3": {"runs": [{"stdout": fizzbuzz(20)}]},
    "13.4": {"runs": [{"exit": 70, "stderr": "contract violation in divide"}]},
    "13.5": {"runs": [{"exit": 70, "stderr": "contract violation in withdraw"}]},
    "13.6": {"runs": [{"stdout": "apple\nbanana\ncherry"}]},
    "13.7": {},
    "13.8": {"prose": ["the prompt is its own line", "a non-numeric line comes back"],
             "runs": [{"stdin": "42\nBob\n", "stdout": "How old are you?\nadult\nHi Bob"},
                      {"stdin": "17\nAl\n", "stdout": "How old are you?\nminor\nHi Al"}]},
    "13.9": {"runs": [{"stdin": "one\ntwo\n", "stdout": "got: one\ngot: two"},
                      {"stdin": "", "stdout": ""}]},
    "13.10": {"runs": [
        {"stdout": "cannot read notes.txt", "exit": 1},
        {"files": {"notes.txt": "abc\n"}, "stdout": "copied 4 bytes", "after": {"copy.txt": "abc\n"}},
        {"files": {"notes.txt": ""}, "stdout": "copied 0 bytes", "after": {"copy.txt": ""}},
        {"files": {"notes.txt": "abc\n", "copy.txt": None}, "stdout": "cannot write copy.txt", "exit": 1}]},
    "13.11": {"runs": [{"stdout": "\n".join([
        '{"name":"Ada","langs":["word","analytical engine"]}', "2", "none", "true", "false",
        "name = Ada", 'langs = ["word","analytical engine"]', "true"])}]},
    "13.12": {"prose": ["shout() is visible"], "runs": [{"stdout": "hey!"}]},
    # Outside section 13, a fragment: 8.3's shared hook on the three functions
    # of 13.5. A hook answers true or false (8.2), and it used to say `return 0`,
    # which does not compile.
    "8.3": {"before": "withdraw(amount)\n    return 0 - amount\ndeposit(amount)\n    return amount\n"
                      "transfer(amount)\n    return amount\n",
            "append": "out(deposit(100))\nout(withdraw(0))\n",
            "runs": [{"stdout": "100", "stderr": "contract violation in withdraw", "exit": 70}]},
}
README_CASES = {
    "// fetch a URL over TLS 1.3 and read the JSON back":
        {"build_only": "it needs the network; test_net.sh fetches over HTTPS"},
    'out("Hello, word!")':
        {"runs": [{"stdout": "Hello, word!", "stderr": "warning: falling back to defaults"}]},
    "out(2 + 2)": {},
    "out(1 == 1)": {},
    "// examples/fib/fib.w": {},
    "// examples/fizzbuzz/fizzbuzz.w": {"runs": [{"stdout": fizzbuzz(15)}]},
    "squares = array(5)": {},
    # `total = total + n  // 30` states the sum on a line that prints nothing.
    "total = 0": {"after_block": "squares = array(5)", "append": "out(total)\n",
                  "runs": [{"stdout": "gion\n30"}]},
    'person = {name: "Ada", age: 36}': {},
    "loop k in keys(person)": {"after_block": 'person = {name: "Ada", age: 36}',
        "runs": [{"stdout": "\n".join([
            "Ada", '{"name":"Ada","age":36,"email":"ada@example.com"}', "none", "true", "false",
            "name = Ada", "age = 36", "email = ada@example.com"])}]},
    "// examples/contracts/contracts.w": {"append": "out(divide(10, 2))\nout(divide(1, 0))\n",
        "runs": [{"stdout": "5", "stderr": "contract violation in divide", "exit": 70}]},
    "// examples/greet/greet.w": {"runs": [{"stdout": "Hello, stranger!"},
                                           {"args": ["Ada"], "stdout": "Hello, Ada!"}]},
    "n = in()": {"runs": [{"stdin": "42\n", "stdout": "got the number 42"},
                          {"stdin": "forty-two\n", "stdout": "that was not a number"}]},
    'data = read("notes.txt")': {
        "runs": [{"files": {"notes.txt": "abc\n", "old.txt": "x"}, "stdout": "",
                  "after": {"out.txt": "abc\n", "log.txt": "line\n", "new.txt": "x", "old.txt": None}}]},
    "data = parse(body)": {
        "after_block": 'body = get("api.github.com/rate_limit")',
        "build_only": "body comes from the net example above it, which needs the network"},
    "out(char(72))": {
        "prose": ["bytes, not code points"],
        "runs": [{"files": {"notes.txt": "caf" + chr(0xe9) + "\n"}, "stdout": 'H\n6\n["a","b","c"]\n   7|'}]},
    'body = get("api.github.com/rate_limit")':
        {"build_only": "it needs the network; test_net.sh fetches over HTTPS"},
}

def blocks(path):
    """(heading, file label, first line, code) for every ```javascript block."""
    lines = open(os.path.join(root, path), encoding="utf-8").read().split("\n")
    res = []; head = ""; i = 0
    while i < len(lines):
        m = re.match(r"^#{2,3} (.*)$", lines[i])
        if m:
            head = m.group(1)
        if lines[i].strip() == "```javascript":
            j = i + 1
            while j < len(lines) and lines[j].strip() != "```":
                j += 1
            code = "\n".join(lines[i + 1:j]) + "\n"
            label = None
            for k in (i - 1, i - 2):
                m = re.match(r"^`([A-Za-z0-9_]+\.w)`:$", lines[k].strip()) if k >= 0 else None
                if m:
                    label = m.group(1); break
            first = lines[i + 1].strip() if i + 1 < j else ""
            if not first.startswith("//"):
                first = re.sub(r"\s+//.*$", "", first)
            res.append((head, label, first, code))
            i = j
        i += 1
    return res

FAULT = ("never prints", "dies")

def stated(code, prose):
    """The values a block's out() lines state in their comments, and whether
    every out() in it is a top-level line that states one."""
    vals = []; whole = True; faults = 0
    for line in code.split("\n"):
        if not re.search(r"\b(out|err)\(", line):
            continue
        m = re.search(r"\s//", line)
        if not line.startswith("out(") or not m:
            whole = False; continue
        c = line[m.end():]
        if c.startswith(" "):
            c = c[1:]
        if c.startswith(FAULT):
            faults += 1; continue
        if any(c.lstrip().startswith(p) for p in prose):
            whole = False; continue
        cut = re.search(r"(?<=\S)( {2,}| -- )", c)
        vals.append((c[:cut.start()] if cut else c).rstrip())
    return vals, whole, faults

bad = 0; ok = 0
def fail(msg):
    global bad; bad += 1; print("  FAIL " + msg)
def good(msg):
    global ok; ok += 1; print("  OK   " + msg)

cases = []   # (name, files {name: code}, spec dict)
spec_seen = {}
for head, label, first, code in blocks("SPEC.md"):
    m = re.match(r"^(\d+(?:\.\d+)?)\.? ", head)
    num = m.group(1) if m else ""
    if num == "13" or num.startswith("13.") or num in SPEC_CASES:
        f = label or "app.w"
        if f in spec_seen.setdefault(num, {}):
            fail("SPEC %s has two examples for %s; the suite can check one" % (num, f)); continue
        spec_seen[num][f] = code
readme = {}
for head, label, first, code in blocks("README.md"):
    readme.setdefault(first, []).append(code)

for num, files in spec_seen.items():
    if num not in SPEC_CASES:
        fail("SPEC %s has an example this suite does not check; add it to SPEC_CASES" % num); continue
    spec = SPEC_CASES[num]
    if "before" in spec or "append" in spec:
        files["app.w"] = spec.get("before", "") + files["app.w"] + spec.get("append", "")
    cases.append(("SPEC " + num, files, spec))
for num in SPEC_CASES:
    if num not in spec_seen:
        fail("SPEC_CASES names %s, which has no example in the SPEC" % num)
for first, codes in readme.items():
    if len(codes) > 1:
        fail("README has %d examples starting %r; the suite names them by first line" % (len(codes), first)); continue
    if first not in README_CASES:
        fail("README example starting %r is not checked; add it to README_CASES" % first); continue
    spec = README_CASES[first]; code = codes[0]
    if "after_block" in spec:
        if spec["after_block"] not in readme:
            fail("README example %r follows %r, which is gone" % (first, spec["after_block"])); continue
        code = readme[spec["after_block"]][0] + code
    code += spec.get("append", "")
    cases.append(("README " + first[:40], {"app.w": code}, spec))
for first in README_CASES:
    if first not in readme:
        fail("README_CASES names %r, which no README example starts with" % first)

targets = [("windows" if windows else "x86-64", [], None)]
if qemu == "native":
    targets = [("arm64", [], None)]
elif qemu:
    targets.append(("arm64", ["-arm64"], qemu))
else:
    print("  (arm64 not run: %s)" % ("WORD is a Windows word.exe" if windows else "no qemu-aarch64 here"))

def run1(exe, runner, run, d):
    os.makedirs(d)
    for n, c in run.get("files", {}).items():
        if c is None:
            os.makedirs(os.path.join(d, n))
        else:
            open(os.path.join(d, n), "w", encoding="utf-8", newline="").write(c)
    argv = ([runner] if runner else []) + [exe] + run.get("args", [])
    try:
        p = subprocess.run(argv, cwd=d, input=run.get("stdin", "").encode(), capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        return None, "", "timed out after 60 s"
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")

n = 0
for name, files, spec in cases:
    n += 1
    code = "".join(files.values())
    vals, whole, faults = stated(code, spec.get("prose", []))
    runs = spec.get("runs") or [{}]
    if "stdout" not in runs[0] and not spec.get("build_only") and not whole:
        fail("%s prints more than its comments state; give its output in the table" % name); continue
    # The comments are the document's claim. Each value they state has to be a
    # line of the output the table expects, in the same order.
    for run in runs:
        want = run.get("stdout", "\n".join(vals))
        lines = want.split("\n"); k = 0
        for v in vals:
            while k < len(lines) and lines[k] != v:
                k += 1
            if k == len(lines):
                fail("%s: the comment says %r, and the expected output has no such line after the ones before it" % (name, v)); break
            k += 1
        if faults and run.get("exit", 0) == 0:
            fail("%s: a comment says the program stops, and the run expects exit 0" % name)
    for tname, flags, runner in targets:
        d = os.path.join(tmp, "c%d_%s" % (n, tname)); os.makedirs(d)
        for f, c in files.items():
            open(os.path.join(d, f), "w", encoding="utf-8", newline="\n").write(c)
        exe = os.path.join(d, "prog.exe" if windows else "prog")
        b = subprocess.run([word, "build"] + flags + [os.path.join(d, "app.w"), "-o", exe], capture_output=True)
        if b.returncode != 0:
            fail("%s (%s): does not build: %s" % (name, tname, (b.stdout + b.stderr).decode("utf-8", "replace").strip()[:300])); continue
        if spec.get("build_only"):
            good("%s (%s): builds; not run, %s" % (name, tname, spec["build_only"])); continue
        for r, run in enumerate(runs):
            rc, out, err = run1(exe, runner, run, os.path.join(d, "run%d" % r))
            want = run.get("stdout", "\n".join(vals))
            want = want + "\n" if want else ""
            werr = run.get("stderr", ""); wrc = run.get("exit", 0)
            why = []
            if out != want: why.append("stdout %r, want %r" % (out, want))
            if rc != wrc: why.append("exit %s, want %d" % (rc, wrc))
            if werr not in err or (not werr and err): why.append("stderr %r, want %r" % (err.strip()[:200], werr))
            for f, c in run.get("after", {}).items():
                p = os.path.join(d, "run%d" % r, f)
                if c is None:
                    if os.path.exists(p): why.append("%s still exists" % f)
                elif not os.path.isfile(p) or open(p, encoding="utf-8", newline="").read() != c:
                    why.append("%s does not hold %r" % (f, c))
            label = "%s (%s)%s" % (name, tname, " run %d" % (r + 1) if len(runs) > 1 else "")
            if why: fail(label + ": " + "; ".join(why))
            else: good(label)

print("test_doc_examples: %d passed, %d failed" % (ok, bad))
sys.exit(1 if bad else 0)
PY
