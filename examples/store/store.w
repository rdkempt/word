
// KEEP: a little key/value store that lives in a file.
//
// KEEP loads a set of key -> value pairs from a text file when it starts and
// writes them back when you save. It parses its own file format by hand, with
// no parser library, so the file stays easy to read. The example uses:
//
//   - the `fs` module: read() a whole file as bytes, write() it back
//   - regions used both as text (keys, values, whole lines) and as arrays
//     (the table of pairs)
//   - scanning and slicing text: splitting a command line into words, and a
//     stored line on its first '='
//   - one value model: whatever in() gives back (a number, for a line of
//     digits) is turned into text with `.`
//
// The file format is one entry per line:
//
//   key=value
//   key=value
//
// Keys are single words, and a value is the rest of the line, spaces included
// (but not a newline). The file is decoded as UTF-8 when it's loaded, so a
// value holding non-ASCII text comes back the way it was saved.
// Commands at the prompt are separated by spaces:
//
//   set <key> <value...>   create or replace an entry
//   get <key>              show one value
//   del <key>              remove an entry
//   list                   show every entry
//   keys                   show just the keys
//   find <text>            show entries whose key or value contains <text>
//   save                   write the file now
//   help                   show this list
//   quit                   save if needed, then exit (exit works too)
//
// Run (the file name is optional and defaults to keep.db):
//
//   word run store.w
//   word run store.w contacts.db

// ------------------------------------------------------------
// Text helpers
// ------------------------------------------------------------

// index of the first occurrence of code point `ch` in `s`, or -1.
index_of(s, ch)
    i = 0
    loop i < len(s)
        if s[i] == ch
            return i
        i = i + 1
    return 0 - 1

// contains: does `hay` contain `needle` as a run of characters?
contains(hay, needle)
    if len(needle) == 0
        return 1
    if len(needle) > len(hay)
        return 0
    limit = len(hay) - len(needle)
    i = 0
    loop i <= limit
        if copy(hay, i, i + (len(needle))) == needle
            return 1
        i = i + 1
    return 0

// split off the first whitespace-delimited word: returns [word, rest], with
// `rest` left untrimmed of its own internal spacing beyond the one separator.
split_first(s)
    i = 0
    loop i < len(s) && s[i] == 32
        i = i + 1
    start = i
    loop i < len(s) && s[i] != 32
        i = i + 1
    word = copy(s, start, i)
    loop i < len(s) && s[i] == 32
        i = i + 1
    rest = copy(s, i, len(s))
    pair = text(2)
    pair[0] = word
    pair[1] = rest
    return pair

// ------------------------------------------------------------
// The table: db[0] is the count, db[1..count] are [key, value] pairs.
// ------------------------------------------------------------

new_db()
    db = text(512)
    db[0] = 0
    return db

find_slot(db, key)
    i = 0
    loop i < db[0]
        pair = db[i + 1]
        if pair[0] == key
            return i
        i = i + 1
    return 0 - 1

kv_get(db, key)
    slot = find_slot(db, key)
    result = text(2)
    if slot < 0
        result[0] = 0
        result[1] = ""
        return result
    pair = db[slot + 1]
    result[0] = 1
    result[1] = pair[1]
    return result

// returns 1 if a new key was created, 2 if an existing one was updated.
kv_set(db, key, value)
    slot = find_slot(db, key)
    if slot >= 0
        pair = db[slot + 1]
        pair[1] = value
        return 2
    n = db[0]
    pair = text(2)
    pair[0] = key
    pair[1] = value
    db[n + 1] = pair
    db[0] = n + 1
    return 1

kv_del(db, key)
    slot = find_slot(db, key)
    if slot < 0
        return 0
    // shift the following pairs down one, so the table stays contiguous.
    i = slot
    loop i < db[0] - 1
        db[i + 1] = db[i + 2]
        i = i + 1
    db[0] = db[0] - 1
    return 1

// ------------------------------------------------------------
// Persistence: loading and saving the file by hand.
// ------------------------------------------------------------

parse_line(db, line)
    eq = index_of(line, 61)
    if eq <= 0
        return 0
    key = copy(line, 0, eq)
    value = copy(line, eq + 1, eq + 1 + (len(line) - eq - 1))
    kv_set(db, key, value)
    return 1

load_db(db, filename)
    raw = read(filename)
    if raw == none
        return 0
    // The file holds UTF-8, so decode it once and non-ASCII values come back
    // as the text that was saved.
    raw = decode(raw)
    start = 0
    i = 0
    loop i < len(raw)
        if raw[i] == 10
            if i > start
                parse_line(db, copy(raw, start, i))
            start = i + 1
        i = i + 1
    if start < len(raw)
        parse_line(db, copy(raw, start, len(raw)))
    return 1

serialize(db)
    data = ""
    i = 0
    loop i < db[0]
        pair = db[i + 1]
        data = data . pair[0] . "=" . pair[1] . "\n"
        i = i + 1
    return data

save_db(db, filename)
    return write(filename, serialize(db))

// ------------------------------------------------------------
// Commands
// ------------------------------------------------------------

do_set(db, args)
    parts = split_first(args)
    key = parts[0]
    value = parts[1]
    if len(key) == 0
        out("  usage: set <key> <value>")
        return 0
    status = kv_set(db, key, value)
    if status == 1
        out("  created " . key)
    else
        out("  updated " . key)
    return 1

do_get(db, args)
    parts = split_first(args)
    key = parts[0]
    if len(key) == 0
        out("  usage: get <key>")
        return 0
    found = kv_get(db, key)
    if found[0] == 0
        out("  no such key: " . key)
        return 0
    out("  " . key . " = " . found[1])
    return 1

do_del(db, args)
    parts = split_first(args)
    key = parts[0]
    if len(key) == 0
        out("  usage: del <key>")
        return 0
    if kv_del(db, key) == 0
        out("  no such key: " . key)
        return 0
    out("  deleted " . key)
    return 1

do_list(db)
    if db[0] == 0
        out("  (empty)")
        return 0
    i = 0
    loop i < db[0]
        pair = db[i + 1]
        out("  " . pair[0] . " = " . pair[1])
        i = i + 1
    out("  " . db[0] . " entr" . plural(db[0]))
    return db[0]

do_keys(db)
    if db[0] == 0
        out("  (empty)")
        return 0
    i = 0
    loop i < db[0]
        pair = db[i + 1]
        out("  " . pair[0])
        i = i + 1
    return db[0]

do_find(db, args)
    parts = split_first(args)
    needle = parts[0]
    if len(needle) == 0
        out("  usage: find <text>")
        return 0
    hits = 0
    i = 0
    loop i < db[0]
        pair = db[i + 1]
        if contains(pair[1], needle) == 1 || contains(pair[0], needle) == 1
            out("  " . pair[0] . " = " . pair[1])
            hits = hits + 1
        i = i + 1
    if hits == 0
        out("  no matches")
    return hits

// "y" for one entry, "ies" for zero or many.
plural(n)
    if n == 1
        return "y"
    return "ies"

// ------------------------------------------------------------
// Main: load, run the prompt loop, save on the way out.
// ------------------------------------------------------------

out("======================================")
out("               K E E P                ")
out("       a file-backed key/value store  ")
out("======================================")

a = args()
filename = "keep.db"
if len(a) > 1
    filename = a[1]

db = new_db()
if load_db(db, filename) == 1
    out("Loaded " . db[0] . " entr" . plural(db[0]) . " from " . filename . ".")
else
    out("New store: " . filename)
out("Type 'help' for commands.")

dirty = 0
running = 1

loop running == 1
    out("")
    out("keep>")

    if ended()
        running = 0

    else
        line = "" . in()
        parts = split_first(line)
        cmd = parts[0]
        args = parts[1]

        // A blank line has no command; only dispatch when one was typed.
        if len(cmd) > 0
            if cmd == "quit"
                running = 0
            else if cmd == "exit"
                running = 0
            else if cmd == "help"
                show_help()
            else if cmd == "list"
                do_list(db)
            else if cmd == "keys"
                do_keys(db)
            else if cmd == "find"
                do_find(db, args)
            else if cmd == "get"
                do_get(db, args)
            else if cmd == "set"
                if do_set(db, args) == 1
                    dirty = 1
            else if cmd == "del"
                if do_del(db, args) == 1
                    dirty = 1
            else if cmd == "save"
                if save_db(db, filename)
                    out("  saved " . db[0] . " to " . filename)
                    dirty = 0
                else
                    out("  could not write " . filename)
            else
                out("  unknown command: " . cmd)
                out("  type 'help' for the list")

out("")
if dirty == 1
    if save_db(db, filename)
        out("Saved changes to " . filename . ".")
    else
        out("WARNING: could not save to " . filename . ".")
out("Goodbye.")

show_help()
    out("")
    out("COMMANDS")
    out("  set <key> <value>   create or replace an entry")
    out("  get <key>           show one value")
    out("  del <key>           remove an entry")
    out("  list                show every entry")
    out("  keys                show just the keys")
    out("  find <text>         entries whose key or value contains <text>")
    out("  save                write the file now")
    out("  help                show this list")
    out("  quit                save if needed, then exit")
    out("")
