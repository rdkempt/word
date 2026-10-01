// fuzz_json.w: the driver for test_fuzz_json.sh.
//
// Reads one file and puts it through json.parse. What's tested is SPEC 12.3's
// promise: malformed text (a syntax error, trailing junk, or nesting deeper
// than 1000) returns `none`. It doesn't fault, it doesn't hang, and it doesn't
// answer a half-built document.
//
// For input that does parse, it also checks the round trip is stable:
// stringify(v) must parse again to something that stringifies the same way.
// That catches a renderer writing text its own parser won't take back, which
// is how `{"a":none}` was found.
fuzz_json_main()
    args = args()
    if len(args) < 2
        err("usage: fuzz_json <file>")
        return 1
    raw = read(args[1])
    if raw == none
        err("cannot read " . args[1])
        return 1
    v = parse(decode(raw))
    if v == none
        out("none")
        return 0
    // It parsed. Say what it is, then check the round trip.
    out(kind(v))
    s1 = stringify(v)
    v2 = parse(s1)
    if v2 == none
        err("ROUNDTRIP: stringify produced text parse rejects")
        return 1
    if stringify(v2) != s1
        err("ROUNDTRIP: a second pass rendered differently")
        return 1
    return 0

return fuzz_json_main()
