// want: 3 abcxxx
t = copy("a")
t = t . "b"
t = t . "c"
n = 0
loop c in t
    t = t . "x"
    n = n + 1
    if n > 10
        break
out(n . " " . t)
