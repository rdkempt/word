// INVENTORY: a tiny catalogue kept as JSON, in word.
//
// This one shows off `{}`. A brace literal is a map, an insertion-ordered store
// from text keys to any value. JSON is what a map prints as, so `out(item)` is
// already the wire format, and json.parse turns the wire format back into maps
// you index with item["name"]. There's no schema and no to_json step.
//
// Everything here is in the language: {} for records, array() for JSON arrays,
// keys(), has() and len() to walk them, and == to compare two catalogues by
// content.
//
// Run:  word run inventory.w

// A record is just a literal. A trailing comma is fine, and a literal can span
// lines, because inside braces a newline doesn't end the statement.
make_item(name, price, tags)
    return {
        name: name,
        price: price,
        tags: tags,
        "in-stock": true,
    }

// array(n) is text(n) plus a mark saying it's a JSON array. Without the mark,
// a region of small numbers can print as a string.
two_tags(a, b)
    t = array(2)
    t[0] = a
    t[1] = b
    return t

// Sum a field across a catalogue. `c["items"]` is an ordinary region, so this
// is an ordinary loop. A map is data, with no methods.
total_value(c)
    sum = 0
    loop item in c["items"]
        sum = sum + item["price"]
    return sum

// Print every field of one record. keys() gives them back in insertion order,
// and `loop k in ...` walks them without an index.
describe(item)
    loop k in keys(item)
        out("  " . k . ": " . item[k])

catalogue = {shop: "Ada's Parts", items: array(3)}
catalogue["items"][0] = make_item("gear", 12, two_tags("brass", "small"))
catalogue["items"][1] = make_item("spring", 3, two_tags("steel", "small"))
catalogue["items"][2] = make_item("crank", 40, two_tags("iron", "large"))

out("catalogue: " . catalogue["shop"])
out("items: " . len(catalogue["items"]))
out("total value: " . total_value(catalogue))
out("")

out("first item, field by field:")
describe(catalogue["items"][0])
out("")

// A missing key reads as none, and none isn't a condition, so the test for an
// optional field has to say what it's asking. `!= none` asks whether there's a
// value. has() asks whether the key is there, which only differs when the value
// itself is none.
first = catalogue["items"][0]
if first["colour"] != none
    out("colour: " . first["colour"])
else
    out("no colour recorded")
out("has 'in-stock': " . has(first, "in-stock"))
out("has 'colour': " . has(first, "colour"))
out("")

// stringify gives the same JSON text out() would print, ready to send or store.
wire = stringify(catalogue)
out("as JSON:")
out(wire)
out("")

// Parsing it gives maps back. Maps compare by content, all the way down, so the
// round trip compares equal to the original.
back = parse(wire)
out("round trip equal: " . (back == catalogue))
out("second item name: " . back["items"][1]["name"])

// Malformed JSON parses to none, which equals nothing else (not 0, not "", not
// an empty map). That matters, because parsing the text "0" succeeds and gives
// 0, so a failure that answered 0 couldn't be told apart from a document that
// said 0.
broken = parse("{\"items\": [1, 2")
if broken == none
    out("broken payload rejected")
