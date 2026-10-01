out(1 < 2)
out(2 < 1)
out(1 <= 1)
out(3 > 2)
out(3 >= 4)
out(5 == 5)
out(5 != 5)
out("abc" == "abc")
out("abc" == "abd")
out("abc" != "abc")
out("abc" < "abd")
out("abc" < "ab")
out("ab" < "abc")
out("b" > "a")
xs = text(2)
ys = text(2)
xs[0] = 1
xs[1] = 2
ys[0] = 1
ys[1] = 2
out(xs == ys)
ys[1] = 3
out(xs == ys)
out(1 == "1")

// Equality across the two region backings. rt_eq used to promote a byte-backed
// operand into a fresh word-backed copy before comparing, which made
// `line == "quit"` allocate on every line. Now it reads each side with the load
// its own backing wants. Three loops replaced one, so all four combinations
// need running, in both directions, and the answers have to be identical on
// x86-64 and arm64 or one of the loops is wrong.
bw = "abc"
bb = bytes("616263")
bb2 = bytes("616263")
bd = bytes("616264")
out(bw == bb)
out(bb == bw)
out(bb == bb2)
out(bb == bd)
out(bd == bb)
out(bw == bd)
out(bd == bw)
out(bw != bb)
out(bb != bd)
// different lengths, which is answered before the backing is even read
bl = bytes("6162")
out(bb == bl)
out(bl == bb)
out(bw == bl)
out(bl == bw)
// empty on either side
be = bytes(0)
we = ""
out(be == we)
out(we == be)
out(be == bb)
out(bb == be)
// a byte-backed element and a code point are the same value, so these are
// equal: 0xe9 is 233, and so is the one code point of "é". Byte-backing is a
// memory choice, not a different kind of content.
hi = "é"
out(hi == bytes("e9"))
out(bytes("e9") == hi)
out(len(hi))
// and a code point above 255 can't equal any byte, which is the case the
// mixed loop's `2b+1` must not match by accident
sn = "☃"
out(sn == bytes("03"))
out(bytes("03") == sn)
out(sn == bytes("e29883"))
out(len(sn))
// a nested region on the word-backed side is not equal to a byte, and asking
// must not fault
nest = array(1)
nest[0] = "x"
one = bytes("78")
out(nest == one)
out(one == nest)
// sort promotes a byte-backed region to word-backed, so the same contents have
// to answer the same way from either side of the change
srt = sort(copy(bb))
out(srt == bw)
out(srt == bb)
out(kind(srt) . " " . kind(bb))
// a slice of a byte-backed region stays byte-backed, and compares the same
sl = copy(bb, 1, 3)
out(sl == "bc")
out("bc" == sl)
out(sl == bytes("6263"))
// and inside a map, where the key path promotes separately
mp = {}
mp[bb] = 1
out(mp["abc"])
out(mp[bytes("616263")])

// One number is one number at every depth: an integer element equals a float
// element of the same value, as `1 == 1.0` does and as a map's values always
// did. Both targets, and both region backings (a byte-backed element is the
// integer b, and the word-backed side it meets may be a float box).
onev(v)
    r = array(1)
    r[0] = v
    return r
out((1 == 1.0) . " " . (onev(1) == onev(1.0)) . " " . (onev(1.0) == onev(1)))
out(({k: 1} == {k: 1.0}) . " " . (bytes("01") == onev(1.0)) . " " . (onev(1.0) == bytes("01")))
out((onev(1) == onev(2.0)) . " " . (onev(1.0) == onev("1")) . " " . (onev(1.0) == onev(none)))
out(find(onev(1), onev(1.0)) . " " . find(onev(1.0), onev(1)) . " " . find(onev(2), onev(1.0)))
// a float inside a nested array, and a longer mixed run
mixa = array(3)
mixa[0] = 1
mixa[1] = 2.5
mixa[2] = onev(3)
mixb = array(3)
mixb[0] = 1.0
mixb[1] = 2.5
mixb[2] = onev(3.0)
out((mixa == mixb) . " " . (mixb == mixa) . " " . len(mixa))

// Ordering goes all the way down too: the element pair that decides a
// lexicographic comparison is ordered by the same rules, not by its words. Both
// targets, since element addresses are what the two would most easily disagree
// about, as each allocates its own way.
out((onev("b") < onev("a")) . " " . (onev("a") < onev("b")) . " " . (onev("a") == onev("b")))
out((onev(onev("a")) < onev(onev("a"))) . " " . (onev(onev("a")) <= onev(onev("a"))))
out((onev(1) < onev(1.0)) . " " . (onev(1) <= onev(1.0)) . " " . (onev(2) < onev(1.5)))
out((onev(2.5) < onev(10)) . " " . (onev("ab") < onev("abc")) . " " . (onev("b") > onev("a")))
zf = 0.0
nf = zf / zf
out((onev(nf) < onev(1.0)) . " " . (onev(nf) >= onev(1.0)) . " " . (onev(nf) == onev(1.0)))
// sort by content: rows of text, rows by a nested number, rows of two fields
frow = array(4)
frow[0] = onev("pear")
frow[1] = onev("apple")
frow[2] = onev("fig")
frow[3] = onev("date")
out(sort(frow))
nrow = array(3)
nrow[0] = onev(30)
nrow[1] = onev(4)
nrow[2] = onev(200)
out(sort(nrow))
pair(k, v)
    r = array(2)
    r[0] = k
    r[1] = v
    return r
prow = array(3)
prow[0] = pair("b", 0)
prow[1] = pair("a", 2)
prow[2] = pair("a", 1)
out(sort(prow))
