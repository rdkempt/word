// want: hello
import txt
m = {}
m["a"] = 0
s = copy("hello world")
t = copy(s, 0, 5)
m["a"] = decode(t)
t = copy(s, 6, 11)
out(m["a"])
