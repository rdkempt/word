// want: hello
import txt
s = encode(copy("hello world"))
t = copy(s, 0, 5)
u = decode(t)
t = copy(s, 6, 11)
out(u)
