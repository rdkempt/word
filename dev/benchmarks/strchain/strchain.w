// Build a string with a multi-part join chain, `s = s . a . b . c`, the way
// people write it. This shape has to hit the in-place append path, and it used
// to miss it (the chain associates left, so the outer join's left operand is a
// temporary, not s), which made it O(n^2) in time and memory. It's lowered to
// one append per operand now.
n = 200000
s = "" . ""
i = 0
loop i < n
    s = s . "<" . i . ">"
    i = i + 1
sum = 0
j = 0
loop j < len(s)
    sum = sum + s[j]
    j = j + 1
out(len(s) . " " . sum)
