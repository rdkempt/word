// fspath_test.w: a path reaches the OS as written, or not at all, on whichever
// target this was built for (run by test_fsdir.sh, which passes a scratch
// directory holding an empty `sub/` as the one argument). The listings dir()
// returns are bytes, so each check compares the name the OS stored.
import fs

// Is `name` one of the newline-separated entries in `buf`?
has_line(buf, name)
    if buf == none
        return 0
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

// How many entries a listing holds.
entries(buf)
    k = 0
    i = 0
    loop i < len(buf)
        if buf[i] == 10
            k = k + 1
        i = i + 1
    return k

check(n, ok, what)
    if ok
        out("  " . what . ": ok")
        return n + 1
    err("  FAIL: " . what)
    return n

d = args()[1]
n = 0

// Text is written as UTF-8: the listing holds C3 A9, not the Latin-1 E9 that
// keeping each code point's low byte used to produce.
cafe = bytes(5)
cafe[0] = 99
cafe[1] = 97
cafe[2] = 102
cafe[3] = 195
cafe[4] = 169
w = write(d . "/caf" . char(233), "x")
n = check(n, w && has_line(dir(d), cafe) == 1, "a text name is stored as its UTF-8")
n = check(n, read(d . "/caf" . char(233)) != none, "and read back by the same text")

// U+012E and U+012F end in the bytes of '.' and '/', so as low bytes this was
// sub/../esc, a file outside the directory the program named.
esc = bytes(9)
esc[0] = 196
esc[1] = 174
esc[2] = 196
esc[3] = 174
esc[4] = 196
esc[5] = 175
esc[6] = 101
esc[7] = 115
esc[8] = 99
w = write(d . "/sub/" . char(302) . char(302) . char(303) . "esc", "x")
n = check(n, w && has_line(dir(d . "/sub"), esc) == 1, "U+012E U+012F stay inside sub/, as UTF-8")
n = check(n, has_line(dir(d), "esc") == 0, "and nothing escapes it")

// A NUL can't be in a name, and a path longer than the OS takes isn't cut down
// to one it would take. Both fail, and neither creates a file.
before = entries(dir(d))
n = check(n, write(d . "/nul" . char(0) . "tail", "x") == false, "a path with a NUL does not write")
q = d . "/"
i = 0
loop i < 2100
    q = q . "./"
    i = i + 1
q = q . "long"
n = check(n, write(q, "x") == false, "a path past 4095 bytes does not write")
n = check(n, read(q) == none && dir(q) == none, "and does not read or list")
n = check(n, rename(d . "/caf" . char(233), d . "/re" . char(0)) == false, "rename to a NUL path fails")
n = check(n, entries(dir(d)) == before, "no file came of any of them")

// A byte-backed path is its bytes.
write(d . "/p.txt", d . "/fromb")
n = check(n, write(read(d . "/p.txt"), "y"), "a path read from a file names that file")
n = check(n, has_line(dir(d), "fromb") == 1, "and the file is there")

out("fs paths: " . n . " of 11 checks pass")
if n == 11
    return 0
return 1
