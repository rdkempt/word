x = 1.5
y = 2.25
out(x + y)
out(x - y)
out(x * y)
out(x / y)
out(x + 1)
out(1 + x)
out(2 * y)
out(y / 2)
out(0 - x)
out(0 - 0.0)
out(x < y)
out(y < x)
out(x == 1.5)
out(x == 1)
out(1.0 == 1)
out(x != y)
out(x >= 1.5)
out(round(x))
out(round(2.5))
out(round(0 - 2.5))
out(round(7))
out(round(0.4))
out(kind(x) == "number")
out(kind(1) == "number")
out(0.1 + 0.2)
out(1.0 / 3.0)
out(100.0)
out(0.5)
out(1000000.5)
out("v=" . x)
out(x . "")
sq(n)
    g = n / 2.0
    i = 0
    loop i < 40
        g = (g + n / g) / 2.0
        i = i + 1
    return g
out(sq(2.0))
out(sq(9.0))
t = 0.0
k = 0
loop k < 100
    t = t + 0.25
    k = k + 1
out(t)

// NaN is ordered against nothing (SPEC 2.6): every ordering comparison with one
// is false, `==` is false and `!=` true, both where the kinds are known (x86-64
// then compares raw doubles inline, arm64 doesn't) and where they aren't (both
// ask rt_order_float). The targets used to disagree: x86-64 read the unordered
// pair as `less` at run time, arm64 as `equal` everywhere.
zn = 0.0
nv = zn / zn
one = 1.0
out((nv < one) . " " . (nv <= one) . " " . (nv > one) . " " . (nv >= one) . " " . (nv == nv) . " " . (nv != nv))
bx = array(3)
bx[0] = nv
bx[1] = one
bx[2] = 1
N = bx[0]
F = bx[1]
I = bx[2]
out((N < F) . " " . (N <= F) . " " . (N > F) . " " . (N >= F) . " " . (N == N) . " " . (N != N))
out((F < N) . " " . (F <= N) . " " . (F > N) . " " . (F >= N))
out((N < I) . " " . (N <= I) . " " . (N > I) . " " . (N >= I) . " " . (I > N) . " " . (I >= N))
seen = ""
if N < F
    seen = seen . "lt "
if N <= F
    seen = seen . "le "
if N > F
    seen = seen . "gt "
if N >= F
    seen = seen . "ge "
if N == N
    seen = seen . "eq "
if N != N
    seen = seen . "ne "
out("[" . seen . "]")
// A sort that meets a NaN takes the left element whenever the right one isn't
// strictly below it, on both targets, so the run merges the same way on each.
ns = array(6)
ns[0] = 2.5
ns[1] = nv
ns[2] = 0.5
ns[3] = 1
ns[4] = nv
ns[5] = 0 - 3
sorted = ""
loop e in sort(ns)
    sorted = sorted . e . " "
out(sorted)
