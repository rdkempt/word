// if / else if / else, and the modulo operator.
// Each out() prints one token and the newline that ends its line.
i = 1
loop i <= 15
    if i % 15 == 0
        out("FizzBuzz")
    else if i % 3 == 0
        out("Fizz")
    else if i % 5 == 0
        out("Buzz")
    else
        out(i)
    i = i + 1
