// Sort 300,000 pseudo-random integers with the built-in sort() and check the
// result. The generator is a plain LCG so every language sorts the identical
// sequence.
n = 50000
a = text(n)
x = 12345
i = 0
loop i < n
    x = (x * 48271) % 2147483647
    a[i] = x
    i = i + 1
s = sort(a)
sum = 0
j = 0
loop j < n
    sum = sum + s[j]
    j = j + 1
out(s[0] . " " . s[(n >> 1)] . " " . s[n - 1] . " " . sum)
