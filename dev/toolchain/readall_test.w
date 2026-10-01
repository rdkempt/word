// readall_test.w: read() has to return the whole file, including a file whose
// size the kernel reports as zero. Run by test_readall.sh, which exports
// READALL_PAD and runs this from a scratch directory.
//
// Every /proc and /sys entry is such a file: `stat` says 0 bytes, and reading
// it gives content anyway. A reader that trusts the reported size hands back an
// empty region for a file it opened successfully. That's a wrong answer instead
// of a failure, the kind of bug word is meant not to have. SPEC 12.1 says read()
// returns the whole file or `none`, and an empty region for a file with content
// is neither.
//
// x86-64 and, under qemu, arm64: the two runtimes have separate copies of
// rt_read, so a fix to one proves nothing about the other.
import fs

check(name, cond)
    if cond
        out("  ok   " . name)
        return 0
    err("  FAIL " . name)
    return 1

bad = 0

// A regular file, where the reported size is exact: the control. If this is
// wrong, nothing below means anything.
body = "the whole file, and not one byte of it less\n"
write("readall_ctl.txt", body)
ctl = read("readall_ctl.txt")
bad = bad + check("regular file reads as bytes", kind(ctl) == "bytes")
bad = bad + check("regular file has the right length", len(ctl) == len(body))
bad = bad + check("regular file has the right content", ctl == body)

// A missing file is a failure (none), and has to stay distinguishable from a
// file that's really empty.
bad = bad + check("missing file reports failure", read("readall_none.txt") == none)

// A directory opens fine on Linux and then fails on the first read with EISDIR.
// That's a failed read, so it's none. It used to come back as an empty region,
// while Windows (where the open itself fails) said none.
bad = bad + check("a directory reports failure", read(".") == none)
write("readall_empty.txt", "")
e = read("readall_empty.txt")
bad = bad + check("empty file succeeds", kind(e) == "bytes")
bad = bad + check("empty file has length 0", len(e) == 0)

// A pseudo-file: stat reports 0, content exists. This is the bug.
v = read("/proc/version")
bad = bad + check("/proc/version succeeds", kind(v) == "bytes")
bad = bad + check("/proc/version is not empty", len(v) > 0)

// A pseudo-file past the fallback allocation, so the growth path runs several
// times. test_readall.sh exports READALL_PAD to guarantee the size.
en = read("/proc/self/environ")
bad = bad + check("/proc/self/environ succeeds", kind(en) == "bytes")
bad = bad + check("/proc/self/environ outgrows the fallback", len(en) > 20000)

// Length isn't enough: the bytes have to survive being copied into each larger
// buffer. The padding is one repeated character, so a bad copy shows up as a
// wrong byte instead of a wrong count. The run of z's is checked in what read()
// returned, and its length against what env() says the variable holds.
pad = env("READALL_PAD")
bad = bad + check("READALL_PAD is set", len(pad) > 20000)
k = find(en, "READALL_PAD=")
bad = bad + check("READALL_PAD is in what read() returned", k != none)
same = false
if k != none
    i = k + 12
    n = 0
    same = true
    loop i < len(en)
        if en[i] == 0
            break
        if en[i] != 122
            same = false
        n = n + 1
        i = i + 1
    if n != len(pad)
        same = false
bad = bad + check("READALL_PAD survives the growth intact", same)

if bad == 0
    out("readall: every check passed")
    return 0
err("readall: " . bad . " FAILED")
return 1
