// Build one big region by repeated append, then measure it. This is the path
// word optimises with the capacity header and uniqueness analysis (SPEC §3.4):
// `s = s . x` grows in place when s is provably unaliased, so each append is
// amortised O(1) and the loop is O(n) instead of O(n^2).
n = 200000
s = ""
i = 0
loop i < n
    s = s . "ab"
    i = i + 1
sum = 0
j = 0
loop j < len(s)
    sum = sum + s[j]
    j = j + 1
out(len(s) . " " . sum)
