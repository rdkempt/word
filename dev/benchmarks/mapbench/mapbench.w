// Map throughput: insert 500,000 text keys, then read every one back.
// word's {} is an open-addressing index over an insertion-ordered pair region
// (SPEC §3.7), so this measures hashing, probing and the key comparison path.
n = 500000
m = {}
i = 0
loop i < n
    m["k" . i] = i
    i = i + 1
sum = 0
j = 0
loop j < n
    sum = sum + m["k" . j]
    j = j + 1
out(len(m) . " " . sum)
