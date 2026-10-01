// want: 6 6
// The keys are added through a second name for the same map.
m = {x: 0}
n = m
i = 0
loop i < len(m)
    if i < 5
        n["k" . i] = i
    i = i + 1
out(i . " " . len(m))
