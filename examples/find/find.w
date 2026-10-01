// find: print the lines of a file that contain a pattern, like grep -F -n.
//
// Run:
//   word run find.w PATTERN file.txt         matching lines, with numbers
//   word run find.w -i PATTERN file.txt      ignore case (ASCII letters only)
//   word run find.w -c PATTERN file.txt      just the count
//
// find() is a builtin (SPEC 9) that looks for a run of elements inside a
// region, so "does this line contain that substring" is one call instead of a
// loop. Text and bytes are both regions, so the same call finds a byte pattern
// in binary data.
//
// It could split the file into lines with split(), but it walks the file
// instead, so it can count line numbers as it goes and never holds a list of
// every line. It exits 0 whether or not anything matched.

lower(s)
    r = text(len(s))
    i = 0
    loop i < len(s)
        c = s[i]
        if c >= 65 && c <= 90
            c = c + 32
        r[i] = c
        i = i + 1
    return r

// The file is decoded once, up front, so everything below works in code points.
// read() gives bytes, and joining a byte region to text ("1:" . line) turns each
// byte into a code point of its own, which garbles multi-byte UTF-8 as soon as
// a line number goes in front. decode() is the runtime's own UTF-8 decoder, the
// one in(), args(), env() and net.get use.

main_run(pat, path, ignore, only_count)
    raw = read(path)
    if raw == none
        err("find: cannot read " . path)
        return 1
    data = decode(raw)
    needle = pat
    if ignore == 1
        needle = lower(pat)
    n = 0
    lineno = 0
    start = 0
    i = 0
    loop i <= len(data)
        if i == len(data) || data[i] == 10
            lineno = lineno + 1
            line = copy(data, start, i)
            hay = line
            if ignore == 1
                hay = lower(line)
            if find(hay, needle) != none
                n = n + 1
                if only_count == 0
                    out(lineno . ":" . line)
            start = i + 1
        i = i + 1
    if only_count == 1
        out(n)
    return 0

// ---- arguments: flags first, then PATTERN, then the file -------------------
ignore = 0
only_count = 0
av = args()
ai = 1
loop ai < len(av)
    a = av[ai]
    if a == "-i"
        ignore = 1
        ai = ai + 1
    else if a == "-c"
        only_count = 1
        ai = ai + 1
    else
        break

pat = ""
if ai < len(av)
    pat = av[ai]
path = ""
if ai + 1 < len(av)
    path = av[ai + 1]
if len(pat) == 0 || len(path) == 0
    err("usage: find [-i] [-c] <pattern> <file>")
else
    main_run(pat, path, ignore, only_count)
