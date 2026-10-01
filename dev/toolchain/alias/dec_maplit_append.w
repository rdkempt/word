// want: {"a":"abc"}
import txt
t = copy("a")
t = t . "b"
t = t . "c"
m = {a: decode(t)}
t = t . "d"
out(m)
