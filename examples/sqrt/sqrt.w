// SQRT: square roots by Newton's method, in floating point.
//
// word's numbers are integers until they can't be, and its floats are IEEE-754
// doubles. A literal with a decimal point is a float, and + - * / give a float
// whenever one is involved. `/` gives one on its own too when two integers
// don't divide evenly, so the halving below would give fractions even if every
// literal here were whole. It's an iterative method that only works with
// fractions.
//
// Newton's method for sqrt(n) refines a guess x with
//
//     x  <-  (x + n/x) / 2
//
// which roughly doubles the number of correct digits each step, so a handful
// of iterations reaches the full precision of a double.
//
// Run:  word run sqrt.w

// One Newton step. `n` and `x` are floats, so n/x is float division and the
// whole expression stays in floating point.
newton_step(n, x)
    return (x + n / x) / 2.0

// Approximate sqrt(n) from a starting guess, printing each iteration so the
// convergence is visible.
sqrt_of(n)
    out("")
    out("sqrt(" . n . "):")
    x = n
    if n < 1.0
        x = 1.0
    i = 0
    loop i < 7
        x = newton_step(n, x)
        out("  step " . (i + 1) . ": " . x)
        i = i + 1
    out("  -> " . x)
    return x

// A tiny check that the result squares back to (about) the input. Because
// floats are inexact we compare against a small tolerance, not with ==.
close_enough(a, b)
    d = a - b
    if d < 0.0
        d = 0.0 - d
    if d < 0.0001
        return 1
    return 0

report(n)
    r = sqrt_of(n)
    if close_enough(r * r, n) == 1
        out("  (checks out: r * r is within 0.0001 of n)")
    else
        out("  (did not converge)")

out("======================================")
out("   S Q R T   -   Newton's method      ")
out("======================================")

report(2.0)
report(3.0)
report(9.0)
report(1000.0)
report(0.25)

out("")
out("Each step roughly doubles the correct digits - that is quadratic")
out("convergence, and it only works because these are real fractions.")
