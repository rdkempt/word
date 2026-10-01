import json
import sys

try:
    with open("data.json", "rb") as fh:
        text = fh.read()
except OSError:
    print("run gen.w first", file=sys.stderr)
    sys.exit(1)
docs = json.loads(text)
total = 0
active = 0
for rec in docs:
    total += rec["score"]
    active += rec["active"]
out = json.dumps(docs, separators=(",", ":"))
print(len(docs), total, active, len(out))
