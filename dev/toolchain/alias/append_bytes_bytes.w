// want: 97 98 99 100|101 102|bytes|7877|true
// `b = b . e` with both sides byte-backed stays byte-backed, so b[i] reads the
// bytes that were appended. arm64 used to hand back a word-backed region here
// while the code indexing it loaded bytes, and every b[i] read part of a word.
// The first append copies (no spare room), the second fits in the doubled
// capacity, and the loop crosses several regrowths.
b = encode("ab")
b = b . encode("cd")
r = b[0] . " " . b[1] . " " . b[2] . " " . b[3]
b = b . encode("ef")
r = r . "|" . b[4] . " " . b[5] . "|" . kind(b)
i = 0
loop i < 20
    b = b . encode("é")
    i = i + 1
s = 0
j = 0
loop j < len(b)
    s = s + b[j]
    j = j + 1
out(r . "|" . s . "|" . (decode(b) == "abcdef" . "éééééééééééééééééééé"))
