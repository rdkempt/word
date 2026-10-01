
// Generates the shared input document for the json benchmark: 20,000 records.
// Written in word so the benchmark needs no other language to produce its data.
//
// Each record is built on its own and then added with `s = s . rec`, which
// appends in place instead of copying the whole document every pass.
n = 20000
s = "["
i = 0
loop i < n
    rec = "{\"id\":" . i . ",\"name\":\"user" . i . "\",\"score\":" . (i % 997) . ",\"active\":" . (i % 2) . ",\"tags\":[\"a\",\"b\",\"c\"]}"
    if i > 0
        rec = "," . rec
    s = s . rec
    i = i + 1
s = s . "]"
if !write("data.json", s)
    err("cannot write data.json")
    return 1
out(len(s))
