// A function and a loop. Prints the first 10 Fibonacci numbers on one line.
// out() ends every call with a newline, so the line is built first and printed
// once.
fib(n)
    a = 0
    b = 1
    i = 0
    loop i < n
        t = a + b
        a = b
        b = t
        i = i + 1
    return a

line = ""
i = 0
loop i < 10
    line = line . fib(i) . " "
    i = i + 1
out(line)
