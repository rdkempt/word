// want: 2 abxx
t = copy("ab")
n = 0
loop c in t
    t = t . "x"
    n = n + 1
    if n > 10
        break
out(n . " " . t)
