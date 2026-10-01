def dist(x, y):
    return x * x + y * y

n = 3000000
c = 0
for i in range(n):
    a = i * 0.5
    b = a + 1.5
    if dist(a, b) > 1000000.0:
        c += 1
print(c)
