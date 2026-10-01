n = 500000
m = {}
for i in range(n):
    m["k" + str(i)] = i
total = 0
for j in range(n):
    total += m["k" + str(j)]
print(len(m), total)
