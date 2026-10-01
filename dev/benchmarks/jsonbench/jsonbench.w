
// Parse a 1.5 MB JSON document, walk every record, and re-serialise it.
// json.parse / json.stringify are built into the language (SPEC §12.3).
text = read("data.json")
if text == none
    err("run gen.w first")
    return 1
docs = parse(text)
if docs == none
    err("parse failed")
    return 1
sum = 0
active = 0
loop rec in docs
    sum = sum + rec["score"]
    active = active + rec["active"]
out(len(docs) . " " . sum . " " . active . " " . len(stringify(docs)))
