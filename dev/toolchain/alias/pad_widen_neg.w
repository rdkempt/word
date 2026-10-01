// want: [  abc]
import txt
t = copy("a")
t = t . "b"
t = t . "c"
u = pad(t, 5, 32)
t = t . "d"
out("[" . u . "]")
