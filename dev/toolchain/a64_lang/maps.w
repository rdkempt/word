o = {}
o["a"] = 1
o["b"] = "two"
o["c"] = 3
out(o)
out(len(o))
out(has(o, "a"))
out(has(o, "z"))
out(o["a"])
out(o["b"])
out(o["z"])
ks = keys(o)
out(len(ks))
out(ks[0])
out(ks[1])
p = {"x": 1, "y": {"z": 2}}
out(p)
out(p["y"]["z"])
q = copy(o)
q["a"] = 99
out(o["a"])
out(q["a"])
out(o == q)
r = {}
r["a"] = 1
r["b"] = "two"
r["c"] = 3
out(o == r)
out(kind(1))
out(kind("hi"))
out(kind(o))
out(kind(array(2)))
a = array(3)
a[0] = 1
a[1] = "x"
a[2] = 3
out(a)
out(stringify(a))
out(stringify(o))
out("m=" . stringify(o))
big = {}
i = 0
loop i < 300
    big["k" . i] = i * i
    i = i + 1
out(len(big))
out(big["k299"])
out(big["k150"])
// A map or an array joined with `.` renders as JSON, not as a walk over
// region pointers that faults on the first one.
t = array(2)
t[0] = "brass"
t[1] = "small"
out("tags: " . t)
out("obj: " . o)
out("" . array(0))
n = {}
n["k"] = t
out("nested: " . n)
