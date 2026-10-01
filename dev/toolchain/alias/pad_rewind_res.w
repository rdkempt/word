// want: hello
import txt
s = copy("hello world")
t = copy(s, 0, 5)
u = pad(t, 5, 32)
u = copy(s, 6, 11)
out(t)
