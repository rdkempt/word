// Contracts: a :before hook checks the arguments, an :after hook checks the
// result. A hook that answers false stops the program with a contract violation.
divide(a, b)
    return a / b

divide:before
    if b == 0
        return false
    return true

out(divide(20, 4))
out("safe so far")
