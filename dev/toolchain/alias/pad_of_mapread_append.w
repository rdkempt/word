// want: abc
import txt
m = {}
t = copy("a")
t = t . "b"
t = t . "c"
m["k"] = t
u = pad(m["k"], 1, 32)
u = u . "d"
out(m["k"])
