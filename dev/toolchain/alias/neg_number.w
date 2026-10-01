// want: P1[none] P2[none] P3[abc] P4[hello]
import txt
import json
p1()
    s = copy("hello world")
    t = copy(s, 0, 5)
    u = number(t)
    t = copy(s, 6, 11)
    return u
p2()
    t = copy("a")
    t = t . "b"
    t = t . "c"
    u = number(t)
    t = t . "d"
    return u
p3()
    t = copy("a")
    t = t . "b"
    t = t . "c"
    u = number(t)
    u = u . "d"
    return t
p4()
    s = copy("hello world")
    t = copy(s, 0, 5)
    u = number(t)
    u = copy(s, 6, 11)
    return t
out("P1[" . p1() . "] P2[" . p2() . "] P3[" . p3() . "] P4[" . p4() . "]")
