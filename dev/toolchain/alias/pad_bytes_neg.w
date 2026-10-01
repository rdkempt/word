// want: hello
import txt
s = encode(copy("hello world"))
t = copy(s, 0, 5)
u = pad(t, 1, 32)
t = copy(s, 6, 11)
out(u)
