// vecmath: float arithmetic inside a called function, 3,000,000 times.
// Every other float benchmark here keeps its work in one frame, so nothing
// measured what a float costs when it crosses a call, which is the case a
// parameter's representation decides. The answer is a count, not a float, so
// every language prints the same text without depending on its float
// formatting.
dist(x, y)
    return x * x + y * y

n = 3000000
i = 0
c = 0
loop i < n
    a = i * 0.5
    b = a + 1.5
    if dist(a, b) > 1000000.0
        c = c + 1
    i = i + 1
out(c)
