fib(n)
    if n < 2
        return n
    return fib(n - 1) + fib(n - 2)
gcd(a, b)
    loop b != 0
        t = b
        b = a % b
        a = t
    return a
count(n)
    i = 0
    s = 0
    loop true
        if i >= n
            break
        s = s + i
        i = i + 1
    return s
out(fib(22))
out(gcd(1071, 462))
out(count(1000))
i = 0
loop i < 5
    if i % 2 == 0
        out("even")
    else
        out("odd")
    i = i + 1
depth(n)
    if n == 0
        return 0
    return 1 + depth(n - 1)
out(depth(500))

// A one-line accessor is substituted into its callers before any analysis runs
// (infer_inlines / inline_program). Both backends have to agree on the value,
// and on which calls are declined: a substitution made on one target and not
// the other makes two different programs.
ilcount(l)
    return l[0]
ilat(l, i)
    return l[i + 1]
ilignore(x)
    return 7
ilsq(x)
    return x * x
iltwo(x)
    y = x + 4
    return y
ilinner(x)
    return x + 2
ilouter(x)
    return ilinner(x) * 2
ilv = array(4)
ilv[0] = 3
ilv[1] = 10
ilv[2] = 20
ilv[3] = 30
out(ilcount(ilv))
out(ilat(ilv, 2))
out(ilat(ilv, 0) + ilat(ilv, 1))
out(ilat(ilv, ilcount(ilv) - 2))
out(ilignore(5))
out(ilsq(7))
out(iltwo(5))
out(ilouter(19))
ilj = 0
ilsum = 0
loop ilj < 3
    ilsum = ilsum + ilat(ilv, ilj + 1)
    ilj = ilj + 1
out(ilsum)
