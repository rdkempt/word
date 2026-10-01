// Take a 32-element window out of a 200k-element region, 1.6M times, look at it
// and drop it. This is the shape a scanner or a parser has: `copy` produces a
// value that's read once and never kept.
//
// It measures two things at once. The obvious one is copy throughput. The one
// that matters more is whether the short-lived copy is charged to peak memory:
// 1.6M windows are 51M elements of copying, and a run that can't tell the dead
// ones from the live ones commits 400 MB to hold windows nobody reads twice.
n = 200000
s = text(n)
i = 0
loop i < n
    s[i] = (i * 48271) % 251
    i = i + 1
w = 32
sum = 0
r = 0
loop r < 8
    j = 0
    loop j < n - w
        t = copy(s, j, j + w)
        sum = sum + t[0] + t[w - 1]
        j = j + 1
    r = r + 1
out(sum)
