// want: 6 6
// len(m) of a map grows with each new key, so the loop reads it every time.
m = {x: 0}
i = 0
loop i < len(m)
    if i < 5
        m["k" . i] = i
    i = i + 1
out(i . " " . len(m))
