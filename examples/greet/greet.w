// Functions, string join with `.`, and a command-line argument.
// out() adds the trailing newline, so greet() returns a bare line.
greet(name)
    return "Hello, " . name . "!"

// args() is the whole command line as an array. args()[0] is the program
// itself, so the first thing you typed is at 1. Reading past the end faults
// instead of giving an empty string, so check len() first.
a = args()
who = "stranger"
if len(a) > 1
    who = a[1]
out(greet(who))
