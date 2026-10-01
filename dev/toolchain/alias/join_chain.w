// want: joins 134367611
// A chain of three or more joins is joined in one go (rt_joinn) when no part
// from the third on makes a call: every part is measured, the result is
// allocated once, then each part is copied in. A chain with a call in its tail
// is joined pair by pair. Every kind of part, the byte-backed rule and the
// order a call inside the chain sees have to give what joining pair by pair
// gave. The digest folds every result's elements, length and kind, so one
// wrong element anywhere changes the line.
dig(h, s)
    i = 0
    loop i < len(s)
        h = (h * 31 + s[i] + 7) % 1000000007
        i = i + 1
    return (h * 131 + len(s)) % 1000000007

f(x)
    return x . "!"

bump(r)
    r[0] = 88
    return "b"

bb = bytes(6)
bb[0] = 104
bb[1] = 105
bb[2] = 32
bb[3] = 0
bb[4] = 255
bb[5] = 10
w = "wörd"
m = {k: 1, s: "x"}
a = array(2)
a[0] = 7
a[1] = 8
hi = 2305843009213693951
lo = 0 - hi - 1
top = hi * 2 + 1
bot = lo * 2
h = 0
h = dig(h, "a" . "b" . "c")
h = dig(h, "" . "" . "")
h = dig(h, 1 . 2 . 3)
h = dig(h, 0 . -5 . hi . lo . top . bot)
h = dig(h, "a" . -7 . "b" . 0 . "c")
h = dig(h, "x=" . 1.5 . " y=" . (0 - 0.25) . " z=" . 1e300)
h = dig(h, "m=" . m . " a=" . a . " t=" . true . " n=" . none . " nl=" . null)
h = dig(h, bb . bb . bb)
h = dig(h, kind(bb . bb . bb) . " " . len(bb . bb . bb))
h = dig(h, bb . w . bb)
h = dig(h, kind(bb . w . bb) . " " . len(bb . w . bb))
h = dig(h, bb . 12 . bb)
h = dig(h, kind(bb . 12 . bb))
h = dig(h, w . w . w . w . w . w . w . w)
h = dig(h, f("p") . "q" . "r")
h = dig(h, "p" . f("q") . "r")
h = dig(h, "p" . "q" . f("r"))
h = dig(h, ("a" . "b") . ("c" . "d") . ("e" . "f"))
h = dig(h, "a" . ("b" . "c" . "d") . "e")
t = "t" . 1 . "u"
h = dig(h, t)
if t == "t1u"
    h = dig(h, "eq")
s = ""
i = 0
loop i < 5
    s = s . "<" . i . ">"
    i = i + 1
h = dig(h, s)
r = copy("abc")
x = "[" . r . "]" . bump(r)
h = dig(h, x)
h = dig(h, r)
r2 = copy("abc")
y = r2 . bump(r2) . "]"
h = dig(h, y)
c = 0
k = 0
loop k < 300
    c = c + len("n" . k . "," . (k * 2) . ";")
    k = k + 1
h = dig(h, "" . c)
h = dig(h, "" . 1 . 2 . 3 . 4 . 5 . 6 . 7 . 8 . 9 . 10 . 11 . 12 . 13 . 14 . 15 . 16 . 17 . 18 . 19 . 20)
h = dig(h, "é" . 1 . "ü")
h = dig(h, kind("a" . 1 . "b"))
h = dig(h, copy("a" . "b" . "c", 1, 1))
h = dig(h, "[" . a . "]" . bb)
out("joins " . h)
