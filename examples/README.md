# `examples/`

Every program here is one folder holding one file, with no dependencies, and you can run any of them
with `word run examples/<name>/<name>.w`. `dev/toolchain/test_examples.sh` builds and checks all of
them except `https`, which needs the network and is run by `dev/toolchain/test_net.sh`. For `fetch`
it only checks that it builds, and how big the binary is.

They come in two kinds. Most show a feature or two: `hello`, `fib`, `fizzbuzz`, `arrays`, `greet`,
`contracts` and `https`, and the longer `rpg`, `calc`, `store`, `life`, `sqrt` and `inventory`.
`README.md` builds its fib, fizzbuzz, contracts and greet examples from four of them.

Five were written to be used: `wc`, `find` (a grep), `hexdump`, `jsonq` (a JSON path query) and
`fetch` (an HTTP client). They're tested like tools, against a fixture with a known answer. Where
the standard tool is installed, `test_examples.sh` also compares `wc`'s three counts with GNU `wc`
and `hexdump`'s hex columns with `hexdump -C`.

```sh
word run examples/wc/wc.w notes.txt
word run examples/find/find.w -i pattern notes.txt
word run examples/hexdump/hexdump.w image.png
word run examples/jsonq/jsonq.w data.json user.tags.0
word run examples/fetch/fetch.w https://ryankempt.com/
```

Here's where they differ from the real tools, from my own runs against GNU coreutils 9.7, GNU grep
3.12 and util-linux 2.41's `hexdump`:

- `wc` gives the same line, word and byte counts on ordinary text, CRLF files, binary files and a
  file with no final newline. It counts words differently when the input has a vertical tab, a form
  feed or a Unicode space (no-break, em or ideographic), because GNU `wc` treats those as separators
  and `wc.w` only splits on space, tab, newline and CR. It also pads every column to 8, the way BSD
  `wc` does, where GNU sizes the columns to fit.
- `find` prints the same lines as `grep -F -n` (the pattern is taken literally), but it always exits
  0, and `-i` only folds ASCII letters. A line holding invalid UTF-8 or a control character comes out
  differently too. `grep` just says the binary file matches. `find` decodes the file first, so an
  invalid byte prints as the character with that number (0xE9 prints as é), and a line with a NUL or
  another control character in it prints as a list of numbers (SPEC 9.1).
- `hexdump` matches `hexdump -C` line for line, except that it prints every line where `hexdump -C`
  collapses a run of identical lines to `*` (so it matches `hexdump -C -v`), and for an empty file it
  prints `00000000` where `hexdump -C` prints nothing.

Writing real programs finds problems that reading a spec doesn't, and the five `txt` functions
(SPEC 12.4) cover gaps programs like these run into. Keep adding to them, and keep them running.

What they show about the language:

- A map prints as JSON, and `parse` gives maps back. `jsonq` is 87 lines, comments included, with no
  marshalling step and no schema.
- `find` is a builtin, so "does this line contain that substring" is one call, and the same call
  finds a byte pattern in binary data, since text and bytes are both regions and elements match by
  value.
- `fetch` builds to 430,080 bytes on Linux x86-64 (428,032 on Windows, 471,040 on arm64). That's a
  working HTTPS client (DNS, TCP, HTTP/1.1, TLS 1.3 and certificate checks against the OS trust
  store) in one binary with nothing to install, from 26 lines of program. It exits 0 even when the
  fetch fails, since `err()` doesn't set the exit status, so check stderr or the output, not `$?`.
