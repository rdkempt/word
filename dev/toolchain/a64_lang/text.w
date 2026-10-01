out(char(65))
out(char(233))
out(char(9731))
out(len(char(65)))
out(split("a,b,c", ","))
out(split("a,,b", ","))
out(split("abc", ","))
out(split("", ","))
out(split("a::b::c", "::"))
out(len(split("a,b,c", ",")))
out(split("a,b,c", ",")[1])
out(pad("x", 5, 46))
out(pad("x", 0 - 5, 46))
out(pad("hello", 3, 46))
out(pad("", 4, 45))
b = bytes(2)
b[0] = 104
b[1] = 105
out(decode(b))
out(decode("already text"))
u = bytes(4)
u[0] = 226
u[1] = 152
u[2] = 131
u[3] = 33
out(decode(u))
out(len(decode(u)))
out(kind(split("a,b", ",")))

// encode: UTF-8 bytes out of code points, and the byte length len() can't give.
// Both backends must agree on every width boundary and on the round trip, since
// the length is observable and a wrong one is a wrong Content-Length.
es = "h" . char(233) . "llo " . char(9731)
out(len(es))
out(len(encode(es)))
out(kind(encode(es)))
out(len(encode("")))
out(len(encode("abc")))
out(len(encode(char(127))))
out(len(encode(char(128))))
out(len(encode(char(2047))))
out(len(encode(char(2048))))
out(len(encode(char(65535))))
out(len(encode(char(65536))))
out(len(encode(char(1114111))))
eb = encode(es)
i = 0
loop i < len(eb)
    out(eb[i])
    i = i + 1
out(decode(eb) == es)
out(encode(decode(bytes("68c3a96c6c6f20e29883"))) == bytes("68c3a96c6c6f20e29883"))
// a byte-backed argument is re-encoded instead of handed back
out(len(encode(bytes("c3a9"))))
out(decode(encode(bytes("c3a9"))))
