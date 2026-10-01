// jsonq: read a JSON file and pull one value out of it by path.
//
// Run:
//   word run jsonq.w data.json                    print the whole document
//   word run jsonq.w data.json user.name          a nested field
//   word run jsonq.w data.json items.2.id         an array element, by index
//   word run jsonq.w data.json -keys user         just the keys of an object
//
// A JSON object is a map here (SPEC 3.7), so there's no object model to
// marshal into and no schema: parse gives a map, and printing one gives JSON
// back. Most of the tool is the path walk. A path that isn't there prints 0.

// Is every code point of `s` a digit? A path step is an array index only if it
// is. (number() would also take "-1" and "1.5", and neither is an index.)
all_digits(s)
    if len(s) == 0
        return 0
    i = 0
    loop i < len(s)
        if s[i] < 48 || s[i] > 57
            return 0
        i = i + 1
    return 1

// Walk one step, asking kind() what cur is. A map is looked up by key, and a
// region by index when the step is all digits. Anything else answers 0.
step(cur, part)
    k = kind(cur)
    if k == "number"
        return 0
    if k == "map"
        if has(cur, part)
            return cur[part]
        return 0
    if all_digits(part) == 1
        i = number(part)
        if i < len(cur)
            return cur[i]
        return 0
    return 0

// -keys lists the keys of a map. keys() faults on anything that isn't a map,
// so kind() has to be checked first.
show_keys(v)
    k = kind(v)
    if k != "map"
        out(v)
        return 0
    ks = keys(v)
    i = 0
    loop i < len(ks)
        out(ks[i])
        i = i + 1

a = args()
path = ""
if len(a) > 1
    path = a[1]
if len(path) == 0
    err("usage: jsonq <file.json> [-keys] [path]")
else
    raw = read(path)
    if raw == none
        err("jsonq: cannot read " . path)
    else
        doc = parse(raw)
        keys_only = 0
        q = ""
        if len(a) > 2
            q = a[2]
        if q == "-keys"
            keys_only = 1
            q = ""
            if len(a) > 3
                q = a[3]
        cur = doc
        if len(q) > 0
            parts = split(q, ".")
            i = 0
            loop i < len(parts)
                cur = step(cur, parts[i])
                i = i + 1
        if keys_only == 1
            show_keys(cur)
        else
            out(cur)
