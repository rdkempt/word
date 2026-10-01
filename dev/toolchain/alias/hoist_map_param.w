// want: 6 6
// The same loop in a function, where m is a parameter.
grow(m)
    i = 0
    loop i < len(m)
        if i < 5
            m["k" . i] = i
        i = i + 1
    return i

mm = {x: 0}
n = grow(mm)
out(n . " " . len(mm))
