// Strings and arrays are the same thing in word, a region. text(n) allocates
// one, p[i] indexes it (bounds-checked), copy(p, start, end) copies part of it,
// and len() measures it.
squares = text(5)
i = 0
loop i < 5
    squares[i] = i * i
    i = i + 1

// Build the row as one region, then print it (out() adds the newline).
line = "squares: "
i = 0
loop i < len(squares)
    line = line . squares[i] . " "
    i = i + 1
out(line)

word = "regionally"
out("copy(2,6): " . copy(word, 2, 6))
