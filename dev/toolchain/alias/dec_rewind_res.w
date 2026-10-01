// want: hello
import txt
s = copy("hello world")
t = copy(s, 0, 5)
u = decode(t)
u = copy(s, 6, 11)
out(t)
