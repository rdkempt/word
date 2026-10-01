# The same scalar algorithm as every other language here, so the languages are
# compared on the same work, not on their idioms. (Idiomatic Python would
# vectorise the inner loop with a slice assignment; see README.md.)
N = 10000000
flags = bytearray(N + 1)
count = 0
for i in range(2, N + 1):
    if not flags[i]:
        count += 1
        for j in range(i * i, N + 1, i):
            flags[j] = 1
print(count)
