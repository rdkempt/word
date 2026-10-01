// want: 6 6
// The keys are added by a function the map is passed to.
add(m, i)
    m["k" . i] = i
    return 0

m = {x: 0}
i = 0
loop i < len(m)
    if i < 5
        add(m, i)
    i = i + 1
out(i . " " . len(m))
