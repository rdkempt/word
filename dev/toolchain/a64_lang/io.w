// args(), env() and stdin. The harness passes no arguments and no stdin, so
// both backends see the same empty input, and what's compared is that they
// agree about it, and about the program name in args()[0].
a = args()
out(len(a))
out(kind(a) == "number")
out(kind(a))
out(env("NO_SUCH_VARIABLE_ANYWHERE") == none)
out(kind(env("NO_SUCH_VARIABLE_ANYWHERE")))
n = 0
loop true
    if ended()
        break
    l = in()
    n = n + 1
    if n > 100
        break
out(n)
out(ended())
