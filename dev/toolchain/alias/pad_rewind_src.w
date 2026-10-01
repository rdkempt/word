// want: hello
import txt
s = copy("hello world")
t = copy(s, 0, 5)
u = pad(t, 3, 32)
t = copy(s, 6, 11)
out(u)
