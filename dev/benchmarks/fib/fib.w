// Naive recursive Fibonacci: measures function-call overhead and integer math.
fib(n)
    if n < 2
        return n
    return fib(n - 1) + fib(n - 2)

out(fib(32))
