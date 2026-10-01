// hexdump: the classic offset, hex and printable-ASCII dump of a file, laid
// out like hexdump -C.
//
// Run:
//   word run hexdump.w file.bin
//   word run hexdump.w file.bin 256      stop after 256 bytes
//
// Byte-backed regions exist for programs like this one. read() gives one
// element per byte (SPEC 12.1), so a 100 MB file costs 100 MB here, and the
// indexing below is the same as on any other region.
//
// Unlike hexdump -C, it prints every line (hexdump -C collapses a run of
// identical lines to "*"), and it prints 00000000 for an empty file.

hexdigit(v)
    if v < 10
        return 48 + v
    return 87 + v

// A number as `w` hex digits, zero-padded. It's built as a region of code
// points instead of by joining, because each join would allocate. Filling all w
// positions is what zero-pads it, so there's nothing left for txt.pad to do.
hex(n, w)
    r = text(w)
    i = w - 1
    v = n
    loop i >= 0
        r[i] = hexdigit(v % 16)
        v = (v >> 4)
        i = i - 1
    return r

// The printable column is a region of code points too, filled by index.
// Joining a number to text renders it in decimal ("" . 72 is "72", not "H"), so
// the other way to write it is line . char(b), and char() allocates a new
// region for every byte. One region for the whole column allocates once.
dump(data, limit)
    n = len(data)
    if limit > 0 && limit < n
        n = limit
    off = 0
    printable = text(16)
    loop off < n
        line = hex(off, 8) . "  "
        got = 0
        j = 0
        loop j < 16
            if off + j < n
                b = data[off + j]
                line = line . hex(b, 2) . " "
                if b >= 32 && b < 127
                    printable[j] = b
                else
                    printable[j] = 46
                got = got + 1
            else
                line = line . "   "
            if j == 7
                line = line . " "
            j = j + 1
        out(line . " |" . copy(printable, 0, got) . "|")
        off = off + 16
    out(hex(n, 8))

a = args()
path = ""
if len(a) > 1
    path = a[1]
if len(path) == 0
    err("usage: hexdump <file> [limit]")
else
    data = read(path)
    if data == none
        err("hexdump: cannot read " . path)
    else
        limit = 0
        if len(a) > 2
            limit = number(a[2])
        dump(data, limit)
