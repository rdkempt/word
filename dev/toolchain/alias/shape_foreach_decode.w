// want: 532
import txt
s = copy("hello world")
t = copy(s, 0, 5)
sum = 0
loop c in decode(t)
    t = copy(s, 6, 11)
    sum = sum + c
out(sum)
