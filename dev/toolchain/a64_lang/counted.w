// Counted walks over a region: the shape whose bounds check the x86-64 backend
// drops because the loop guard already made it. The arm64 backend doesn't (it
// has no hoisted length yet), so this program has the two of them answering
// the same question with different code.
sum(a)
    i = 0
    s = 0
    loop i < len(a)
        s = s + a[i]
        i = i + 1
    return s

fill(a, v)
    i = 0
    loop i < len(a)
        a[i] = v + i
        i = i + 1
    return a

pairs(a)
    i = 0
    t = 0
    loop i < len(a)
        j = 0
        loop j < len(a)
            t = t + a[i] * a[j]
            j = j + 1
        i = i + 1
    return t

a = fill(array(6), 3)
out(sum(a))
out(pairs(a))
b = bytes(5)
b = fill(b, 200)
out(sum(b))
out(sum(array(0)))
c = "hello"
out(sum(c))
