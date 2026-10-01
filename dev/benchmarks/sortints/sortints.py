n = 50000
a = [0] * n
x = 12345
for i in range(n):
    x = (x * 48271) % 2147483647
    a[i] = x
a.sort()
print(a[0], a[n // 2], a[n - 1], sum(a))
