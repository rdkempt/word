// wc: count the lines, words and bytes in files, like the Unix tool.
//
// Run:
//   word run wc.w file.txt              one file
//   word run wc.w a.txt b.txt c.txt     several, with a total
//
// read() hands back a byte-backed region (SPEC 12.1), one byte per element, so
// a 10 MB file costs 10 MB of memory instead of 80. The code below indexes it
// like any other region and gets each byte as an integer.
//
// The counts match GNU wc's, except the word count when the input holds a
// vertical tab, a form feed or a Unicode space, which GNU wc treats as a
// separator. The columns are padded to 8, the way BSD wc lays them out, and it
// exits 0 even when a file can't be read.

// A word is a run of anything that isn't a space, a tab, a newline or a CR.
is_space(c)
    if c == 32 || c == 9 || c == 10 || c == 13
        return 1
    return 0

count(data, out3)
    lines = 0
    words = 0
    inword = 0
    i = 0
    loop i < len(data)
        c = data[i]
        if c == 10
            lines = lines + 1
        if is_space(c) == 1
            inword = 0
        else
            if inword == 0
                words = words + 1
            inword = 1
        i = i + 1
    out3[0] = lines
    out3[1] = words
    out3[2] = len(data)

// Right-align each count in a column 8 wide so the rows line up.
// txt.pad: a positive width right-aligns, a negative one left-aligns.
report(c3, name)
    out(pad("" . c3[0], 8, ' ') . pad("" . c3[1], 8, ' ') . pad("" . c3[2], 8, ' ') . " " . name)

a = args()
n = 1
files = 0
tl = 0
tw = 0
tb = 0
one = text(3)
loop n < len(a)
    path = a[n]
    data = read(path)
    if data == none
        err("wc: cannot read " . path)
    else
        count(data, one)
        report(one, path)
        tl = tl + one[0]
        tw = tw + one[1]
        tb = tb + one[2]
        files = files + 1
    n = n + 1

if files == 0
    err("usage: wc <file> [file ...]")
else
    if files > 1
        one[0] = tl
        one[1] = tw
        one[2] = tb
        report(one, "total")
