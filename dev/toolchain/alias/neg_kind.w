// want: P1[text] P2[text] P3[abc] P4[hello]
import txt
import json
p1()
    s = copy("hello world")
    t = copy(s, 0, 5)
    u = kind(t)
    t = copy(s, 6, 11)
    return u
p2()
    t = copy("a")
    t = t . "b"
    t = t . "c"
    u = kind(t)
    t = t . "d"
    return u
p3()
    t = copy("a")
    t = t . "b"
    t = t . "c"
    u = kind(t)
    u = u . "d"
    return t
p4()
    s = copy("hello world")
    t = copy(s, 0, 5)
    u = kind(t)
    u = copy(s, 6, 11)
    return t
out("P1[" . p1() . "] P2[" . p2() . "] P3[" . p3() . "] P4[" . p4() . "]")
