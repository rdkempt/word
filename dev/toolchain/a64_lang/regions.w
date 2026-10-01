xs = text(6)
i = 0
loop i < 6
    xs[i] = i * i
    i = i + 1
out(xs)
out(len(xs))
out(xs[5])
t = 0
loop v in xs
    t = t + v
out(t)
b = bytes(4)
b[0] = 119
b[1] = 111
b[2] = 114
b[3] = 100
out(b)
out(len(b))
out(b[2])
tb = 0
loop c in b
    tb = tb + c
out(tb)
s = "hello"
out(s)
out(len(s))
out(s[1])
out(s . " " . "world")
out(1 . 2 . 3)
out("n=" . 42)
out("" . (0 - 17))
acc = ""
k = 0
loop k < 200
    acc = acc . "ab" . k
    k = k + 1
out(len(acc))
sum = 0
j = 0
loop j < len(acc)
    sum = sum + acc[j]
    j = j + 1
out(sum)
// An unwritten cell reads as the number 0, not as a raw zero word. A raw zero
// has a region pointer's low bits, so reading one would fault or, worse, not.
// text(), array() and bytes() all fill.
z = text(4)
out(z)
out(z[0])
out(z[0] + 1)
out(kind(z[3]) == "number")
zb = bytes(4)
out(zb[2])
out(zb[2] + 1)
za = array(2)
out(za)
out(za[1] + 5)
out(len(text(0)))

// A join of two byte-backed regions stays byte-backed, and both backends have
// to agree on that. They once didn't: one side promoted both operands and
// handed back a word-backed region, while the subkind pass (shared by both
// backends) had already proved the join byte-backed and emitted a raw byte load
// where it was used, so `j[0]` read the low byte of a tagged word (65 on x86-64,
// 131 on arm64) with no fault.
// Every line below goes through a function so the shape can't be folded at
// compile time; a shape the compiler could infer wouldn't have caught it.
mkbytes(n, first)
    b = bytes(n)
    b[0] = first
    return b
ba = mkbytes(2, 65)
bb = mkbytes(3, 70)
bj = ba . bb
out(kind(bj))
out(len(bj))
out(bj[0])
out(bj[2])
out(bj)
// and the mixed pair still promotes, which is the other half of the rule
bm = ba . "xy"
out(kind(bm))
out(len(bm))
out(bm[0])
// appending bytes to bytes follows the join
bap = mkbytes(2, 90)
bap = bap . bb
out(kind(bap))
out(bap[0])
out(len(bap))

// A join of two byte-backed literals is byte-backed too, and the subkind pass
// has to say so. Its "both sides byte-backed" test used to check for subkind 1
// (byte-backed and fresh) and miss subkind 4 (byte-backed and a literal), which
// is what bytes("hex") is. The pair then counted as word-backed, the use site
// emitted a word-backed element load against a byte-backed region, and x86-64
// printed 572629280 for a byte while arm64 faulted with "number expected, got
// a region".
bl1 = bytes("4142")
bl2 = bytes("4344")
blj = bl1 . bl2
out(kind(blj))
out(len(blj))
out(blj[0])
out(blj[1])
out(blj[2])
out(blj[3])
out(blj)
// a byte literal joined with a fresh byte region, both directions
blf = bytes(2)
blf[0] = 90
blf[1] = 91
out(kind(bl1 . blf))
out((bl1 . blf)[2])
out(kind(blf . bl1))
out((blf . bl1)[0])
// and mixed with text, which must promote
out(kind(bl1 . "xy"))
out((bl1 . "xy")[0])
out(len(bl1 . "xy"))

// `s = s . "lit"` is emitted inline on x86-64, as a capacity test and one store
// per character, instead of a call into rt_append. arm64 still makes the call,
// so every line below checks that fast path against the slow one: the same
// program on two backends, and this corpus requires the output to match.
ap = ""
ap = ap . "a"
out(ap)
ap = ap . "bc"
out(ap)
out(len(ap))
// the literal the variable started as is in the read-only pool, so the first
// append of all has to take the out-of-line path and allocate
lit0 = ""
lit0 = lit0 . "z"
out(lit0)
out(len(lit0))
// a chain, which is one append per operand
ch = "" . ""
ch = ch . "<" . "-" . ">"
out(ch)
out(len(ch))
// eight characters is the unroll bound, nine is past it and takes the call
e8 = "" . ""
e8 = e8 . "12345678"
out(e8)
out(len(e8))
n9 = "" . ""
n9 = n9 . "123456789"
out(n9)
out(len(n9))
// escapes must store the decoded character, and non-ASCII must survive being
// stored as a tagged code point instead of a byte
esc = "" . ""
esc = esc . "a\tb\\c\n"
out(len(esc))
out(esc[1])
out(esc[3])
out(esc[5])
uni = "" . ""
uni = uni . "wörd"
out(uni)
out(len(uni))
out(uni[1])
// growing across the capacity boundary many times, mixed with a non-literal
// operand so the two paths interleave
mix = "" . ""
k = 0
loop k < 40
    mix = mix . "ab"
    mix = mix . k
    k = k + 1
out(len(mix))
sum = 0
k = 0
loop k < len(mix)
    sum = sum + mix[k]
    k = k + 1
out(sum)

// A callee that only reads its argument doesn't block the dead-store rewind
// (infer_retention). The shapes that do keep the region must still be blocked,
// and both backends have to agree: a rewind that fires on one and not the other
// hands the same region out twice on one of them.
rk_keep(box, i, t)
    box[i] = t
    return 0
rk_map(m, k, t)
    m[k] = t
    return 0
rk_back(t)
    return t
rk_via(box, i, t)
    rk_keep(box, i, t)
    return 0
rk_read(t)
    return t[0] + t[1]
rk_show(r)
    return r[0] . "," . r[1] . "," . r[2] . "," . r[3]
ry = bytes(64)
ri = 0
loop ri < 64
    ry[ri] = ri + 1
    ri = ri + 1
rbox = array(16)
rmap = {}
rn = 0
loop rn < 16
    rt = copy(ry, rn, rn + 4)
    rk_keep(rbox, rn, rt)
    rn = rn + 1
out(rk_show(rbox[0]))
out(rk_show(rbox[7]))
out(rk_show(rbox[15]))
rn = 0
loop rn < 16
    rt = copy(ry, rn, rn + 4)
    rk_map(rmap, "k" . rn, rt)
    rn = rn + 1
out(rk_show(rmap["k0"]))
out(rk_show(rmap["k15"]))
rr = 0
rn = 0
loop rn < 16
    rt = copy(ry, rn, rn + 4)
    if rn == 0
        rr = rk_back(rt)
    rn = rn + 1
out(rk_show(rr))
rn = 0
loop rn < 16
    rt = copy(ry, rn, rn + 4)
    rk_via(rbox, rn, rt)
    rn = rn + 1
out(rk_show(rbox[0]))
out(rk_show(rbox[15]))
racc = 0
rn = 0
loop rn < 200
    rt = copy(ry, rn % 8, rn % 8 + 4)
    racc = racc + rk_read(rt)
    rn = rn + 1
out(racc)
