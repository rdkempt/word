// want: args:true env:true keys:["k"] char:A read:true dir:true in:0 argsout:true
import txt
import fs
f1()
    a = args()
    a[0] = 0
    b = args()
    return kind(b[0]) == "text"
f2()
    n = copy("PATH")
    a = env(n)
    a[0] = 0
    b = env(n)
    return b[0] != 0
f3()
    m = {}
    m["k"] = 1
    a = keys(m)
    a[0] = 0
    return keys(m)
f4()
    a = char(65)
    a[0] = 66
    return char(65)
f5()
    a = read("neg_cache_calls.w")
    a[0] = 0
    b = read("neg_cache_calls.w")
    return b[0] == 47
f6()
    a = dir(".")
    a[0] = 0
    b = dir(".")
    return b[0] != 0
f7()
    a = in()
    a = a . "x"
    b = in()
    return len(b)
f8()
    s = copy("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")
    a = args()
    a = copy(s)
    k = len(args())
    k = len(args())
    b = args()
    return kind(b[0]) == "text"
out("args:" . f1() . " env:" . f2() . " keys:" . f3() . " char:" . f4() . " read:" . f5() . " dir:" . f6() . " in:" . f7() . " argsout:" . f8())
