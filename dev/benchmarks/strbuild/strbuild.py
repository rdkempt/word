n = 200000
parts = []
for i in range(n):
    parts.append("ab")
s = "".join(parts)
total = 0
for ch in s:
    total += ord(ch)
print(len(s), total)
