import urllib.request

total = 0
for _ in range(200):
    with urllib.request.urlopen("http://127.0.0.1:4491/p") as r:
        total += len(r.read())
print(total)
