// `&&`, `||` and `!` as conditions: each side runs only when the other hasn't
// already decided, a side that isn't a condition faults, and both targets
// print the same, down to the fault on the last line.
f(x)
    out("f" . x)
    return x > 2

g(x)
    out("g" . x)
    return x < 5

i = 0
loop i < 7
    if f(i) && g(i)
        out("both " . i)
    if f(i) || g(i)
        out("either " . i)
    if !(f(i) || g(i)) && i != 3
        out("neither " . i)
    i = i + 1
t = true
k = 0
loop t && k < 3
    k = k + 1
    if k == 2 || false
        t = true
out(k)
v = null
if k > 100 && v
    out("no")
out("guarded")
if k < 100 || v
    out("short")
if v || k < 100
    out("unreached")
