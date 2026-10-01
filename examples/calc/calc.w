// RECKON: a little calculator language, written in word.
//
// RECKON tokenizes a line, parses it with a hand-written recursive-descent
// parser, and evaluates it. It uses most of what word programs are made of:
//
//   - text is a region of Unicode code points, scanned one character at a time
//   - word's own numbers: an answer is an integer while it can be one and a
//     float when it can't, so `6 / 3` is 2 and `7 / 2` is 3.5, which is what
//     someone typing into a calculator means by division
//   - regions used both as strings (a name, an operator) and as arrays (the
//     token stream, the variable table)
//   - recursion, for a grammar with real operator precedence
//   - a contract that checks an internal invariant
//
// Grammar (precedence low to high):
//
//   line   := name '=' expr        (assignment)  |  expr
//   expr   := term (('+' | '-') term)*
//   term   := factor (('*' | '/' | '%') factor)*
//   factor := '-' factor | '(' expr ')' | number | name
//
// Session commands:  help   vars   quit
//
// Run:
//   word run calc.w
//
// Then type expressions:
//   2 + 3 * 4          -> 14
//   (2 + 3) * 4        -> 20
//   x = 10             -> x = 10
//   x * x - 1          -> 99
//   ans + 1            -> 100        (ans is always the last result)

// ------------------------------------------------------------
// Character classes. A line is a region of code points, so each
// character is just a number we compare against ASCII values.
// ------------------------------------------------------------

is_space(c)
    if c == 32
        return true
    if c == 9
        return true
    return false

is_digit(c)
    if c >= 48
        if c <= 57
            return true
    return false

is_alpha(c)
    if c >= 97
        if c <= 122
            return true
    if c >= 65
        if c <= 90
            return true
    if c == 95
        return true
    return false

is_alnum(c)
    if is_alpha(c)
        return true
    return is_digit(c)

// ------------------------------------------------------------
// Tokens. The token stream is one region used as an array: T[0] is
// the count, and T[1..count] each hold a two-cell token [kind, value].
//   kind 1 = number   value = the integer
//   kind 2 = name      value = the text
//   kind 3 = operator  value = the one-character operator text
// ------------------------------------------------------------

tokenize(line)
    T = text(256)
    n = 0
    i = 0

    loop i < len(line)
        c = line[i]

        if is_space(c)
            i = i + 1

        else if is_digit(c)
            value = 0
            loop i < len(line) && is_digit(line[i])
                value = value * 10 + (line[i] - 48)
                i = i + 1
            tok = text(2)
            tok[0] = 1
            tok[1] = value
            n = n + 1
            T[n] = tok

        else if is_alpha(c)
            start = i
            loop i < len(line) && is_alnum(line[i])
                i = i + 1
            tok = text(2)
            tok[0] = 2
            tok[1] = copy(line, start, i)
            n = n + 1
            T[n] = tok

        else
            tok = text(2)
            tok[0] = 3
            tok[1] = copy(line, i, i + 1)
            n = n + 1
            T[n] = tok
            i = i + 1

    T[0] = n
    return T

// ------------------------------------------------------------
// The variable table, another region-as-array: env[0] is the count,
// env[1..count] each hold a [name, value] pair.
// ------------------------------------------------------------

new_env()
    env = text(128)
    env[0] = 0
    return env

lookup(env, name)
    i = 0
    loop i < env[0]
        pair = env[i + 1]
        if pair[0] == name
            found = text(2)
            found[0] = 1
            found[1] = pair[1]
            return found
        i = i + 1
    miss = text(2)
    miss[0] = 0
    miss[1] = 0
    return miss

assign(env, name, value)
    i = 0
    loop i < env[0]
        pair = env[i + 1]
        if pair[0] == name
            pair[1] = value
            return 0
        i = i + 1
    pair = text(2)
    pair[0] = name
    pair[1] = value
    n = env[0]
    env[n + 1] = pair
    env[0] = n + 1
    return 1

// ------------------------------------------------------------
// The arithmetic core. A contract guards `apply`: the parser only
// ever emits operator codes 1 to 5, so any other code would be a bug
// in the parser, and the :before hook stops the program there instead
// of letting a wrong answer through. It never fires in correct
// operation.
// ------------------------------------------------------------

apply(op, a, b)
    if op == 1
        return a + b
    if op == 2
        return a - b
    if op == 3
        return a * b
    if op == 4
        return a / b
    return a % b

apply:before
    if op < 1
        return false
    if op > 5
        return false
    return true

// ------------------------------------------------------------
// The parser and evaluator. Parser state P is [tokens, pos, err,
// message], and pos and the error fields change in place as we descend.
// Every level stops as soon as an error is set, so one bad token gives
// one message instead of a cascade.
// ------------------------------------------------------------

cur(P)
    T = P[0]
    if P[1] >= T[0]
        return 0
    return T[P[1] + 1]

advance(P)
    P[1] = P[1] + 1

fail(P, message)
    if P[2] == 0
        P[2] = 1
        P[3] = message

// current token is the operator `sym`?
at_op(P, sym)
    t = cur(P)
    if t == 0
        return 0
    if t[0] != 3
        return 0
    if t[1] == sym
        return 1
    return 0

parse_factor(P, env)
    if P[2] != 0
        return 0

    t = cur(P)
    if t == 0
        fail(P, "expected a number, name, or '(' but the line ended")
        return 0

    if t[0] == 1
        advance(P)
        return t[1]

    if t[0] == 2
        advance(P)
        found = lookup(env, t[1])
        if found[0] == 0
            fail(P, "unknown variable '" . t[1] . "'")
            return 0
        return found[1]

    if at_op(P, "-") == 1
        advance(P)
        return 0 - parse_factor(P, env)

    if at_op(P, "(") == 1
        advance(P)
        value = parse_expr(P, env)
        if at_op(P, ")") == 0
            fail(P, "expected ')'")
            return 0
        advance(P)
        return value

    fail(P, "unexpected '" . t[1] . "'")
    return 0

parse_term(P, env)
    left = parse_factor(P, env)

    loop true
        if P[2] != 0
            return 0

        if at_op(P, "*") == 1
            advance(P)
            left = apply(3, left, parse_factor(P, env))

        else if at_op(P, "/") == 1
            advance(P)
            right = parse_factor(P, env)
            if P[2] != 0
                return 0
            if right == 0
                fail(P, "division by zero")
                return 0
            left = apply(4, left, right)

        else if at_op(P, "%") == 1
            advance(P)
            right = parse_factor(P, env)
            if P[2] != 0
                return 0
            if right == 0
                fail(P, "division by zero")
                return 0
            left = apply(5, left, right)

        else
            break

    return left

parse_expr(P, env)
    left = parse_term(P, env)

    loop true
        if P[2] != 0
            return 0

        if at_op(P, "+") == 1
            advance(P)
            left = apply(1, left, parse_term(P, env))

        else if at_op(P, "-") == 1
            advance(P)
            left = apply(2, left, parse_term(P, env))

        else
            break

    return left

// ------------------------------------------------------------
// A whole line: an assignment, or an expression to evaluate. In both
// cases we insist every token was consumed, so "2 3" or "x = " is an
// error rather than a half-read line.
// ------------------------------------------------------------

evaluate(T, env)
    P = text(4)
    P[0] = T
    P[1] = 0
    P[2] = 0
    P[3] = ""

    // Assignment? name '=' expr
    target = ""
    if T[0] >= 2
        first = T[1]
        second = T[2]
        if first[0] == 2 && second[0] == 3
            if second[1] == "="
                target = first[1]
                P[1] = 2

    value = parse_expr(P, env)

    if P[2] != 0
        out("  error: " . P[3])
        return 0

    if P[1] < T[0]
        out("  error: unexpected extra input")
        return 0

    if len(target) > 0
        assign(env, target, value)
        assign(env, "ans", value)
        out("  " . target . " = " . value)
        return 1

    assign(env, "ans", value)
    out("  " . value)
    return 1

// ------------------------------------------------------------
// Session commands and help.
// ------------------------------------------------------------

show_help()
    out("")
    out("RECKON, a small calculator.")
    out("  + - * / %   and parentheses, with the usual precedence")
    out("  name = expr assigns a variable; 'ans' is the last result")
    out("  commands:   help   vars   quit")
    out("")

show_vars(env)
    if env[0] == 0
        out("  (no variables yet)")
        return 0
    i = 0
    loop i < env[0]
        pair = env[i + 1]
        out("  " . pair[0] . " = " . pair[1])
        i = i + 1
    return env[0]

// A command is a single bare name: quit / help / vars.
command_of(T)
    if T[0] != 1
        return ""
    only = T[1]
    if only[0] != 2
        return ""
    return only[1]

// ------------------------------------------------------------
// Main: the read, evaluate, print loop.
// ------------------------------------------------------------

out("======================================")
out("            R E C K O N               ")
out("     a little calculator language     ")
out("======================================")
out("Type 'help' for help, 'quit' to leave.")

env = new_env()
running = 1

loop running == 1
    out("")
    out("reckon>")

    if ended()
        running = 0

    else
        line = "" . in()
        T = tokenize(line)

        // A blank line has no tokens; only act when there is something to read.
        if T[0] > 0
            cmd = command_of(T)

            if cmd == "quit"
                running = 0
            else if cmd == "exit"
                running = 0
            else if cmd == "help"
                show_help()
            else if cmd == "vars"
                show_vars(env)
            else
                evaluate(T, env)

out("")
out("Goodbye.")
