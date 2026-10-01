divide(a, b)
    return a / b
divide:before
    if b == 0
        return false
    return true
scale(n)
    return n * 2
scale:after
    if result < 0
        return false
    return true
both(x)
    return x + 1
both:before
    if x > 100
        return false
    return true
both:after
    if result > 100
        return false
    return true
out(divide(20, 4))
out(scale(21))
out(both(5))
tally(xs)
    t = 0
    loop v in xs
        t = t + v
    return t
tally:before
    if len(xs) == 0
        return false
    return true
a = text(3)
a[0] = 1
a[1] = 2
a[2] = 3
out(tally(a))
out("done")
