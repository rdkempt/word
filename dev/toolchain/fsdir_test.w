// fsdir_test.w: fs.dir on the repo tree (run by test_fsdir.sh from the
// repository root). It lists compiler/ and checks a known file is there, and
// that a regular file and a missing path both answer none.
//
// test_fsdir.sh passes up to four arguments: a FIFO (or "-" when it couldn't
// make one), a directory, and how many entries and bytes `ls -a` lists for that
// directory. dir() of the FIFO has to answer none at once: opening a FIFO to
// read waits for a writer, so a dir() that opened it before refusing it never
// came back. The directory's names add up to more than a megabyte, and dir()
// has to hand back every one of them.
import fs

// Is `name` one of the newline-separated tokens in `buf`?
has_line(buf, name)
    n = len(buf)
    m = len(name)
    start = 0
    i = 0
    loop i <= n
        cut = 0
        if i == n
            cut = 1
        else if buf[i] == 10
            cut = 1
        if cut == 1
            if i - start == m
                j = 0
                eq = 1
                loop j < m
                    if buf[start + j] != name[j]
                        eq = 0
                    j = j + 1
                if eq == 1
                    return 1
            start = i + 1
        i = i + 1
    return 0

n = 0
names = dir("compiler")
if names != none && has_line(names, "word.w") == 1
    n = n + 1
    out("  dir lists a directory and finds word.w: ok")
else
    err("  FAIL: dir(compiler) did not list word.w")
if dir("compiler/word.w") == none
    n = n + 1
    out("  dir on a regular file answers none: ok")
else
    err("  FAIL: dir on a regular file did not answer none")
if dir("no_such_directory_zzz") == none
    n = n + 1
    out("  dir on a missing path answers none: ok")
else
    err("  FAIL: dir on a missing path did not answer none")

want = 3
a = args()
if len(a) > 1
    if a[1] != "-"
        want = want + 1
        if dir(a[1]) == none
            n = n + 1
            out("  dir on a FIFO answers none without waiting for a writer: ok")
        else
            err("  FAIL: dir on a FIFO did not answer none")

// dir() used to collect the names in a 1 MB buffer and stop at 1,040,000
// bytes, dropping every later entry and still answering a listing.
if len(a) > 4
    want = want + 1
    big = dir(a[2])
    lines = 0
    if big != none
        i = 0
        loop i < len(big)
            if big[i] == 10
                lines = lines + 1
            i = i + 1
    if big != none && lines == number(a[3]) && len(big) == number(a[4])
        n = n + 1
        out("  dir lists all " . lines . " entries of a listing over 1 MB: ok")
    else if big == none
        err("  FAIL: dir of the large directory answered none")
    else
        err("  FAIL: dir of the large directory gave " . lines . " entries, " . len(big) . " bytes; ls -a has " . a[3] . " and " . a[4])

out("fs.dir: " . n . " of " . want . " checks pass")
if n == want
    return 0
return 1
