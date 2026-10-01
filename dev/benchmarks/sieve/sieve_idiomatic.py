# Idiomatic Python: the inner loop becomes one slice assignment in C.
N = 10000000
flags = bytearray(N + 1)
count = 0
for i in range(2, N + 1):
    if not flags[i]:
        count += 1
        span = len(range(i * i, N + 1, i))
        if span:
            flags[i * i :: i] = b"\x01" * span
print(count)
