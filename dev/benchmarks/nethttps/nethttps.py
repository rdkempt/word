import ssl
import urllib.request

ctx = ssl._create_unverified_context()
total = 0
for _ in range(20):
    with urllib.request.urlopen("https://127.0.0.1:4492/p", context=ctx) as r:
        total += len(r.read())
print(total)
