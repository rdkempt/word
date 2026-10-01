out(stringify(parse("{\"a\":1,\"b\":[1,2,3],\"c\":\"x\"}")))
o = parse("{\"n\": 1.5, \"e\": 1e3, \"neg\": -2.25, \"i\": 42}")
out(o["n"])
out(o["e"])
out(o["neg"])
out(o["i"])
out(parse("[]"))
out(parse("[1,[2,[3]]]"))
out(parse("\"hi\\nthere\""))
out(parse("\"\\u0041\\u00e9\\ud83d\\ude00\""))
out(parse("true"))
out(parse("false"))
out(parse("null"))
out(parse("  {  \"k\" : [ 1 , 2 ]  }  "))
out(parse("{bad}"))
out(parse("[1,"))
out(parse(""))
out(parse("1 2"))
d = parse("[[[[[[1]]]]]]")
out(stringify(d))
out(kind(parse("[1]")))
out(kind(parse("{}")))
out(parse("[1.5, 2.5e2, -0.25]"))
out(stringify(parse("{\"a\":{\"b\":{\"c\":[1,2,{\"d\":\"e\"}]}}}")))
out(stringify("plain text"))
out(stringify(42))
out(stringify(1.25))

// RFC 8259's grammar, the number range and the nesting cap, held to the same
// answers on both backends. x86-64 used to take "\uZZZZ" as U+0000, where arm64
// refused it.
bad = split("-|01|-01|00|1.|1.e5|-.5|1e|1e+|\"\\x\"|\"\\uZZZZ\"|\"a\\|1e400|[-1e400]", "|")
i = 0
loop i < len(bad)
    out(bad[i])
    out(parse(bad[i]) == none)
    i = i + 1
out(parse("\"a" . char(9) . "b\"") == none)
out(parse("\"a\\/b\\tc\""))
out(parse("-0"))
out(parse("0.25e1"))
out(parse("1e-400"))
out(parse("0e999999999"))
zeros(n)
    s = ""
    j = 0
    loop j < n
        s = s . "0"
        j = j + 1
    return s
out(parse("0." . zeros(500) . "1e500"))
out(number("0." . zeros(500) . "1e500"))
out(parse("1" . zeros(500) . "e-100") == none)
nest(n, inner)
    s = ""
    j = 0
    loop j < n
        s = s . "["
        j = j + 1
    s = s . inner
    j = 0
    loop j < n
        s = s . "]"
        j = j + 1
    return s
out(parse(nest(1000, "1")) == none)
out(parse(nest(1001, "1")) == none)
out(len(stringify(parse(nest(1000, "1")))))

// A \u escape with no hex digits is refused, and the two targets agree on a
// raw NUL inside a string, which RFC 8259 makes malformed (a control character
// has to be escaped). x86-64 used to read the bad escape as U+0000 and
// stop at the NUL, because its runtime's `mov rax, 0 - 1` assembled as 0.
out(kind(parse("\"\\uzzzz\"")))
nul = text(5)
nul[0] = 34
nul[1] = 97
nul[2] = 0
nul[3] = 98
nul[4] = 34
out(parse(nul) == none)

// A byte-backed document is UTF-8 and decodes the way decode() does, and a
// byte-backed string writes as the text its bytes spell.
jb = bytes(6)
jb[0] = 34
jb[1] = 74
jb[2] = 195
jb[3] = 169
jb[4] = 255
jb[5] = 34
jv = parse(jb)
out(len(jv) . " " . jv[1] . " " . jv[2])
out(stringify(copy(jb, 1, 4)))
out({raw: copy(jb, 1, 3)})
