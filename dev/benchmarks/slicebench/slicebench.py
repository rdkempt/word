n, w = 200000, 32
s = [(i * 48271) % 251 for i in range(n)]
total = 0
for _ in range(8):
    for j in range(n - w):
        t = s[j:j + w]
        total += t[0] + t[w - 1]
print(total)
