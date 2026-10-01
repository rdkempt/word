# word

[![language: word](https://img.shields.io/badge/language-word-d2a25c)](SPEC.md)
[![license: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

word is a small programming language for single-file tools and other self-contained programs. It
compiles to native executables that carry their own runtime, with no libc and no third-party
libraries. There's a short tour of it at [word.ryankempt.com](https://word.ryankempt.com).

```javascript
// fetch a URL over TLS 1.3 and read the JSON back
body = get("api.github.com/rate_limit")
data = parse(body)
out(data["rate"]["limit"])
```

That's a complete program, and it compiles to a standalone binary with the HTTPS client, the TLS 1.3
handshake, the X.509 verification and the JSON parser inside. None of it comes from another library:
the network code is written in word, and the JSON parser is part of the runtime word emits. There's
no `import` line because nothing needs importing.

Three things shape the rest of the language:

- **One value type.** Every value is a 64-bit machine word. A number is a 63-bit signed integer or
  an IEEE-754 double; strings, arrays and byte buffers are all one thing, called a *region*; and
  maps are JSON. There are no type declarations, no generics and no boxing you can see.
- **Checked at run time.** Array bounds, integer overflow in arithmetic, division by zero and shift
  counts are all checked. A failed check stops the program with the file and line, so a bad index
  can't corrupt memory. Functions can carry `:before` and `:after` contracts.
- **It compiles itself.** `compiler/word.w` is about 39,000 lines of word: the compiler, the x86-64
  and AArch64 assemblers, and the ELF, PE and Mach-O linkers. The same file also carries the `net`
  library as text, which the compiler bundles into programs that use it, so the file is longer than
  that. `word verify` rebuilds the Linux x86-64 binary from that source and checks it's
  byte-identical to the committed `./word`.

---

## Getting started

On Linux x86-64 there's nothing to install and nothing to build first. The `word` binary at the root
of the repository is committed with its executable bit set, so it runs straight from a fresh clone:

```sh
git clone https://github.com/rdkempt/word && cd word

printf 'out("Hello, word!")\n' > hello.w
./word run hello.w
# -> Hello, word!
```

`./word build hello.w -o hello` writes a standalone executable instead of running it. With
`word run`, anything after the file name is passed to the program.

The committed `word` is a Linux x86-64 binary, so it won't run on Windows, macOS or arm64 Linux.
There, take the binary for your platform from a release, or build one with the Linux `word` (in WSL,
for example): `./word build -win compiler/word.w -o word.exe` makes a Windows `word.exe`, and
`-arm64` or `-mac` in place of `-win` build the arm64 Linux and macOS ones. A fresh clone has no
`word.exe`, since it's in `.gitignore`.

A [release](https://github.com/rdkempt/word/releases) has one download per target. For Linux and
macOS it's a `.tar.gz` holding a single `word`:

```sh
tar xzf word-linux-x64.tar.gz   # or word-linux-arm64 / word-macos-arm64
./word run hello.w
```

Those are archives because tar records the executable bit and restores it. A bare release asset
can't carry the bit (GitHub stores no file mode), so a direct download always arrives
non-executable. On macOS, extracting with command-line `tar` also skips the Gatekeeper step, because
`tar` doesn't pass the quarantine flag on to what it extracts. Windows has no executable bit, so the
Windows download is a bare `word-windows-x64.exe`. It isn't code-signed, so SmartScreen will warn
about it: choose "More info", then "Run anyway".

The downloads are reproducible: the same seed always gives the same `SHA256SUMS` line. The `word`
inside `word-linux-x64.tar.gz` is byte-for-byte the committed seed, which is the binary
[`docs/BOOTSTRAP.md`](docs/BOOTSTRAP.md) audits.

### The CLI

```
word build [-win|-linux|-arm64|-mac] app.w [-o out]   compile, assemble and link an executable
word build -asm app.w [-o app.s]                      print the emitted assembly, or save it with -o
word run app.w [args...]                              build for this host to a temp file and run it
word asm [-win|-linux|-arm64|-mac] in.s [...] out     assemble and link hand-written .s files
word format app.w                                     rewrite app.w in the canonical layout
word verify                                           rebuild the Linux seed, compare it to ./word
word bootstrap [-win|-linux|-arm64|-mac] [-o out]     rebuild word from compiler/word.w
word version                                          this binary, and whether it reproduces itself
```

`build`, `asm` and `bootstrap` target the host by default, and `run` always does (it accepts a
target flag only when the flag names the host). One source builds for every target: `-win` gives a
Windows PE, `-linux` a Linux x86-64 ELF, `-arm64` a Linux arm64 ELF and `-mac` an Apple Silicon
Mach-O, and `build -asm` takes the same flags. None of it needs MinGW, Xcode, binutils or LLVM,
because the whole toolchain is the one binary. Without `-o`, `build` names the output after the
source file. The flags can go anywhere on the line, and an unknown flag, two different targets or a
second `-o` is refused with the usage line. A build never writes over its own source:
`word build noext`, or an `-o` that names a source file, stops with a message instead.

`word run` leaves its temporary binary behind, in `$TMPDIR` (or `/tmp`), or in `%TEMP%` on Windows.

---

## The language

Every example on this page is tested: `dev/toolchain/test_doc_examples.sh` builds each one, runs
every one that doesn't need the network, and checks it prints what the page says it prints. Each
folder in `examples/` is a program you can run with `./word run examples/<name>/<name>.w`, and the
blocks below that start with a path are based on one of them.

### Output

`out(x)` writes its argument and a newline, in the form that suits its kind: an integer as digits, a
float with a decimal point (`2.0`, never `2`), a text region as UTF-8, a byte region as the bytes it
holds, a map or an array as JSON, and `null`, `true`, `false` and `none` as those words. `.` renders
a value the same way when it joins it onto text, with one exception: it widens a byte region one
code point per byte, so `decode` one first to join its text. `err(x)` is the same as `out(x)` but
writes to standard error, which keeps a program's diagnostics out of its data.

```javascript
out("Hello, word!")
err("warning: falling back to defaults")
```

Every `out` ends the line, so to print several values on one line, build one piece of text and print
it once.

### Numbers

A number is either a signed 63-bit integer, from `-2^62` to `2^62 - 1`, or an IEEE-754 double.
`kind(x)` calls both `"number"`, because most of the time the difference doesn't come up. Where it
does is `/`. The operators are `+ - * / % & | ^ ~ << >>`, the comparisons, and `&& || !`.

```javascript
out(2 + 2)          // 4
out(6 / 3)          // 2      divides evenly, so the answer is an integer
out(7 / 2)          // 3.5    it does not, so the answer is a float
out((7 - 7 % 2) / 2) // 3     the whole part, always an integer
out(7 % 2)          // 1      and % is the remainder it leaves
out(7.0 / 2)        // 3.5    a float operand makes it float arithmetic
```

`/` gives you the exact answer: an integer when the division comes out even, and a float when it
doesn't. So `1 / 2` is `0.5`, where C, Go, Java and Rust give you `0`. There's only one division
operator. When you want the whole part, write `(a - a % b) / b`, which is always an integer and
rounds toward zero. `a >> 1` halves, but it rounds down, so the two differ for a negative odd `a`:
`-7 >> 1` is `-4`, and `(-7 - -7 % 2) / 2` is `-3`.

Division by zero, overflow past the integer range and a shift count outside 0 to 63 all stop the
program. `<<` only checks its shift count, so bits shifted off the top are lost: `1 << 62` is
`-4611686018427387904`. Floats follow IEEE 754 instead, so `1.0 / 0.0` is `inf`, and `%` and the bit
operators stop the program if you hand them a float. A float prints to about fifteen significant
digits, so it doesn't always come back the same from text or JSON: `0.1 + 0.2` prints `0.3`.

### `true`, `false`, `null`, `none`

These four are values of their own, separate from numbers, text and maps. A program can say yes, say
no, say "the JSON field was null" and say "there was no answer" without borrowing `0` for any of
them.

```javascript
out(1 == 1)                   // true    a comparison answers true or false
out(kind(1 == 1))             // boolean
out(has({a: 1}, "b"))         // false

out(number("42"))             // 42
out(number("wat"))            // none    so it can't be mistaken for 0
out(number("0") == none)      // false
```

Only `true` and `false` can be conditions. Anything else in an `if`, a `loop`, `&&`, `||` or `!` is
an error, and the message tells you to compare it instead. Where the compiler can see the value is a
number (`0` included), text, a float, an array or a map, it's a compile error. `null`, `none` and
values the compiler can't see, like a parameter or what `number(s)` returns, stop the program when
they're reached. So `if n` becomes `if n != 0`, `if len(s)` becomes `if len(s) > 0`, and
`if number(s)` becomes `if number(s) != none`, which asks whether it parsed. `true`, `false`, `null`
and `none` are reserved words, so `true = 1` is a parse error.

### Functions and control flow

A function is a name, its parameters and an indented body. `=` declares a name the first time and
assigns to it after that, and it's the only assignment operator. `loop` is the only loop:
`loop cond` runs while the condition is true, a bare `loop` runs until something breaks out of it,
and `break` leaves it.

```javascript
// examples/fib/fib.w
fib(n)
    a = 0
    b = 1
    i = 0
    loop i < n
        t = a + b
        a = b
        b = t
        i = i + 1
    return a

out(fib(30))        // 832040
```

`if`, `else if` and `else` work the way you'd expect:

```javascript
// examples/fizzbuzz/fizzbuzz.w
i = 1
loop i <= 15
    if i % 15 == 0
        out("FizzBuzz")
    else if i % 3 == 0
        out("Fizz")
    else if i % 5 == 0
        out("Buzz")
    else
        out(i)
    i = i + 1
```

### Regions: strings and arrays

Strings and arrays are both **regions**. A string literal is a region of code points, and `array(n)`
is a region of `n` zeros. `p[i]` indexes one (bounds-checked: an index out of range stops the
program), `len(p)` measures it, `copy(p, start, end)` takes the elements from `start` up to but not
including `end`, and `.` joins text.

```javascript
squares = array(5)
i = 0
loop i < 5
    squares[i] = i * i
    i = i + 1

out(copy("regionally", 2, 6))    // gion
```

`loop x in y` walks the elements without an index:

```javascript
total = 0
loop n in squares
    total = total + n            // 30
```

Walking text gives you numbers, which surprises most people. A character is its code point, so
`loop c in "abc"` with `out(c)` inside prints `97`, `98` and `99`. Use `out(char(c))` to print the
letters. There's no separate character type: `'a'` is the integer `97` (SPEC.md §2.7), and text is a
region of those numbers (§3.4).

Giving a region a second name doesn't copy it. After `t = s`, both names refer to the same region,
the way arrays work in most languages, and `t[0] = 120` changes `s` too. Use `copy(s)` when you want
your own. A string literal is read-only, so writing into one (`s = "hello"` then `s[0] = 120`) stops
the program with `write to a literal`. Copy it first.

### Maps and JSON

The other aggregate is the **map**. `{}` is a store of keys and values, written with braces because
blocks are indentation and the braces were free. Keys are text, and values can be anything.

```javascript
person = {name: "Ada", age: 36}
person["email"] = "ada@example.com"

out(person["name"])           // Ada
out(person)                   // {"name":"Ada","age":36,"email":"ada@example.com"}

out(person["phone"])          // none   an absent key has no value to give
out(person["phone"] == none)  // true   "was there a value?"
out(has(person, "phone"))     // false  the same question when a value could be none
```

A map prints as JSON, and `==` compares two maps by content, so `parse(stringify(o)) == o` holds for
a map of integers, text, booleans, `null`, arrays and other maps. A float may not survive the trip,
since it prints to about fifteen significant digits, and `stringify` stops the program on a map
holding `none`, which has no JSON form. `keys(o)` gives the keys in insertion order as an array, so
`out(keys(person))` prints `["name","age","email"]`. To take them one at a time, walk them:

```javascript
loop k in keys(person)
    out(k . " = " . person[k])
```

Maps have no methods, no inheritance and no `o.field` syntax.

### Contracts

A function can have a `:before` hook that checks its arguments and an `:after` hook that checks its
result, which the hook sees as `result`. A hook answers `true` or `false`, like any condition. An
answer of `false` is a **contract violation**: the program stops, naming the function.

```javascript
// examples/contracts/contracts.w
divide(a, b)
    return a / b

divide:before
    if b == 0
        return false    // divide(x, 0) is a contract violation
    return true
```

### Arguments, input and kinds

`args()` is the command line as an array of text, so `out(args())` prints it as JSON, like
`["./greet","Ada"]`. `args()[0]` is the path the program was started as (under `word run`, that's
the temporary binary), so the first thing the user typed is `args()[1]`. Every argument is text,
even `42`, and `number(a[1])` converts one.

```javascript
// examples/greet/greet.w
a = args()
who = "stranger"
if len(a) > 1
    who = a[1]
out("Hello, " . who . "!")
```

`in()` reads a line from standard input. A line that's an integer comes back as a number and any
other line comes back as text, so a program can check `kind(x)` and branch instead of stopping:

```javascript
n = in()
if kind(n) == "number"
    out("got the number " . n)
else
    out("that was not a number")
```

`kind(x)` answers one of eight names: `"number"`, `"text"`, `"bytes"`, `"array"`, `"map"`,
`"boolean"`, `"null"` or `"none"`. Comparing it with one of those names is the language's only kind
test, and the compiler turns the comparison into a check of the value's tag. A name `kind()` never
answers, such as `"string"`, is a compile error.

---

## The standard library

Four modules are there for programs to use: `fs` (5 functions), `json` (2), `net` (5) and `txt` (5).
None of them needs an `import`. The compiler knows which module each name is in, so calling `read`
is what brings in `fs`. A function you define yourself wins over a module's, and a module is only
compiled into a program that calls it.

### `fs`: files

```javascript
data = read("notes.txt")         // whole file as bytes, or none on failure
write("out.txt", data)           // true on success, false on failure
append("log.txt", "line\n")
rename("old.txt", "new.txt")
dir(".")                         // the names in a directory, or none
```

`dir` gives the names one per line, as bytes. On macOS it answers `none` for now, so a `word`
running on a Mac can only build single-file programs (SPEC §12.1).

### `json`: parse and print

```javascript
data = parse(body)               // objects -> maps, arrays -> arrays, none if malformed
out(stringify(data))
```

### `txt`: text helpers

```javascript
out(char(72))                    // H     a computed code point
t = decode(read("notes.txt"))    // file bytes -> code points
out(len(encode(t)))              // bytes, not code points: a Content-Length
out(split("a,b,c", ","))         // ["a","b","c"]
out(pad("7", 4, ' ') . "|")      //    7|   a negative width left-aligns
```

`char(n)` gives a code point its spelling: `"s" . 72` renders the number and gives `s72`, where
`"s" . char(72)` gives `sH`. `decode` and `encode` convert between a file's bytes and its code
points, so `len(encode(t))` is the byte count a `Content-Length` wants, where `len(t)` counts code
points. `split` and `pad` are the two jobs every text tool otherwise writes by hand. The five live
in a module to keep the list of always-available builtins short: it's 20 names, and I've set myself
a ceiling of 25.

### `net`: HTTP and HTTPS

```javascript
body = get("api.github.com/rate_limit")   // scheme defaults to https
if body == none
    out("request failed")
```

`get`, `post`, `put`, `delete` and `head` take `[scheme://]host[:port][/path][?query][#fragment]`,
and the scheme defaults to `https`. A URL holding a control character or a space is refused before
anything is sent, and the fragment is never sent.

Behind those five is a TLS 1.3 stack written in word (the `net` library, carried in
`compiler/word.w`): DNS, TCP, the handshake, X25519 key exchange with P-256 and P-384 as fallbacks,
ChaCha20-Poly1305 and AES-128-GCM for the record layer, and X.509 chain verification for RSA (PKCS#1
v1.5 and PSS) and ECDSA (P-256, P-384 and P-521). The trust anchors come from the host's own store
at run time, so none are built in, and a host with no readable store trusts nothing. A fetch is
limited to 30 s idle, 120 s in total and 64 MiB of response, and a body that ends before the length
it declared counts as a failure.

`net` works on Linux (x86-64 and arm64) and on Windows. A program that uses it builds for macOS too,
but in 1.0.0 every net verb answers `none` there.

A program that calls one of the five verbs gets the library compiled in with it, and the library
travels inside the `word` binary. So a directory holding nothing but `word` and one `.w` file builds
an HTTPS client, and cross-compiles it for all four targets.

There's one copy of the library, and it's ordinary word source. It lives in `compiler/word.w`, in a
region fenced off from the compiler's own code, and that's where you read it and change it. Nothing
is generated from it: when the compiler builds itself, it lifts that region out and carries the text
in the binary. So a `word` you just built always carries the library you just edited, and
`word verify` covers the library as well.

What the verifier accepts is a written-out profile of RFC 5280 for one job, authenticating a TLS
server (SPEC §12.2). It has eight rules. Two of them are the easiest to leave out of a from-scratch
verifier: a critical extension the verifier can't process means the certificate is refused, and an
`extendedKeyUsage`, where present, must allow `serverAuth`. A leaf's `keyUsage`, where present, must
also let its key sign, since signing is how a TLS 1.3 server proves who it is. In six places word
gives a different answer from openssl or Go's `crypto/x509`, and SPEC §12.2 lists them. In five it's
stricter. In the sixth, a certificate you put in the trust store counts as an anchor even when it
isn't self-signed, as it does in Go (openssl needs `-partial_chain` for that).
`dev/toolchain/test_x509_profile.sh` puts every rule and every divergence to word, openssl and Go on
the same bytes, and fails if any of them gives a different verdict from the one recorded for it.

The fixture suites check that each rule is enforced, but they can't tell you how much of the real
web word can fetch. `dev/toolchain/test_top_sites.sh` does that: it fetches the top 100 domains (all
1,000 on the list with `TOP_SITES=1000`) and gates on the count. Every failure is classified against
openssl, so a host that fails because it wants a cipher word doesn't offer is told apart from a host
that fails because word is wrong. It finds bugs a fixture suite can't, such as a trust store that
drops its SHA-1 self-signed anchors.

> **This TLS stack is written from scratch and hasn't been audited.** It's fine for fetching data.
> Don't use it to protect anything that matters. Three specifics: there's no certificate revocation
> checking, the same as Go's standard library and Chrome since 2012 (`docs/SECURITY.md` §5 explains
> why I left it out). Name constraints and policy constraints aren't implemented, so a certificate
> carrying one is refused. And AES-GCM is table-driven software on every CPU, which leaves it open
> to cache-timing attacks from a local attacker. ChaCha20-Poly1305 has no such tables and is offered
> first. `docs/SECURITY.md` has the full threat model. Read it before you rely on this.

---

## Self-hosting

```sh
./word verify
# -> word verify: OK - rebuilt word is byte-identical to the committed binary
```

`word verify` compiles `compiler/word.w` for Linux x86-64 (compile, assemble and link, all in word)
and checks the result is byte-for-byte the committed `./word`. It does that whatever host runs it,
so `word.exe verify` on Windows checks the Linux seed too. `word version` is the check for the
binary you're running: it rebuilds `compiler/word.w` for its own target and tells you whether that
gives back the same bytes. This fixed point is the project's main safety check, and `ci.yml` runs it
on pushes to main and on pull requests that aren't drafts.

So you don't have to take the committed binary on trust: it proves it matches the source beside it.
A tampered binary could reproduce its own tampered self, though, so there's a second implementation
in `bootstrap/`, about 5,600 lines of Python that share no code with word. On a Linux x86-64 host it
rebuilds the committed binary from source in two commands (the Python compiler only emits Linux
x86-64, so on anything else run them in a Linux x86-64 VM or container):

```sh
python3 bootstrap/wordc.py compiler/word.w -o /tmp/word_A
/tmp/word_A build compiler/word.w -o /tmp/word_B && cmp /tmp/word_B word
```

`ci.yml` runs that too. `docs/BOOTSTRAP.md` explains what it does and doesn't settle.

word self-hosts on Linux x86-64, Linux arm64, macOS on Apple Silicon and Windows x64. On each of
them, rebuilding `compiler/word.w` gives the same bytes as the cross-build from any other host, and
a Windows build comes out the same whatever file name it's written to.

---

## Performance

The numbers are in [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md): word beside C, C++, Rust, Go,
Python and Node on the same machine in the same run, plus compile speed and the scaling guards. The
page is generated. A workflow (`bench.yml`) re-measures and rewrites it on merges to main, and the
page's header names the commit and date the numbers were measured at, which can be older than the
commit you're reading.

Read the ratios, since the milliseconds depend on the machine. Absolute times move from run to run,
while word's time next to a `gcc -O2` binary measured beside it stays much steadier. Each row gives
the median, minimum, p95, standard deviation and first of ten runs, so you can see when a difference
sits inside the run-to-run spread, and the page lists the machine and the version of every compiler
it compares against. To reproduce the page, run what `bench.yml` runs:

```sh
sh dev/benchmarks/bench.sh
sh dev/benchmarks/compilespeed.sh > dev/benchmarks/compilespeed.txt
sh dev/benchmarks/scaling.sh > dev/benchmarks/scaling.txt
sh dev/benchmarks/mkperf.sh
```

The comparison toolchains are optional (a missing one is skipped), and none of them is needed to
build or run word.

---

## Where things are

| Path | What it is |
|---|---|
| **`SPEC.md`** | The language specification, and the source of truth for syntax and semantics. |
| **`compiler/word.w`** | The whole toolchain, in word: lexer, parser, analyzer, code generator, two assemblers, three linkers, the formatter and the runtime it emits. It also carries the `net` library as text (hashes, AEADs, curves, signatures, X.509, TLS 1.3, DNS, HTTP/1.1), which it bundles into any program that uses it. |
| **`bootstrap/`** | A second implementation, in Python. Its only job is to rebuild the committed binary from source, so you don't have to take it on trust. It's frozen at 1.0; see `docs/BOOTSTRAP.md`. |
| **`examples/`** | Runnable programs, one per folder. Most show a feature or two. Five of them are tools meant to be used: `wc`, `find` (a grep), `hexdump`, `jsonq` and `fetch`. The tests check `wc` against GNU `wc` and `hexdump` against `hexdump -C`, where those are installed. |
| **`docs/`** | `BOOTSTRAP.md` (how the binary is seeded and audited), `SECURITY.md` (the threat model), `LEARNABILITY.md` (whether a beginner can still read it), `VALUE_MODEL.md` (the tagged word) and `PERFORMANCE.md` (generated). |
| **`dev/`** | Test suites and benchmarks. The suites use `gcc`, `as`, `qemu`, `llvm-mc`, `openssl`, Go and the comparison languages as oracles, and none of them takes part in a build. |
| **`editors/`** | A VS Code extension and a language server with no dependencies: highlighting, diagnostics, go to definition, find references, completion, formatting, outline, hover and rename. Diagnostics are `word build`'s own errors and formatting is `word format`'s own output, so the server can't disagree with the compiler about either. |

---

## Status

**Version 1.0.** The specification is frozen for all of 1.x: a program that compiles today will
compile and behave the same on every 1.x release. Additions are allowed, like new builtins, new
crypto or new targets. Removals and changes in behaviour aren't.

1.x doesn't freeze performance, the exact wording of diagnostics and run-time faults, the emitted
code, the compiler's internal structure, or anything under `dev/`.

What's unfinished in 1.0.0:

- `net` doesn't work on macOS. Programs that use it build for macOS, but every net verb answers
  `none` there.
- `dir` answers `none` on macOS, so a `word` running on a Mac can only build single-file programs
  (SPEC §12.1).
- The editor tooling has no tree-sitter grammar, and the language server re-runs the compiler
  instead of working incrementally (SPEC §15).

The other open questions are design choices, and `SPEC.md` §15 and `docs/SECURITY.md` cover them
where they apply. If you hit a rough edge, check `SPEC.md` first. The language is small, and most
surprises are documented there.

---

## License

Apache License 2.0 (see `LICENSE`). You can use word for anything, including commercially. Keep the
copyright notice and the license with it.

**Programs you compile with word are yours.** word puts a runtime into every binary it builds, and
bundles its `net` library into any program that calls a network verb. `NOTICE` gives you an extra
permission so that none of that puts a licensing obligation on the binaries you build. It covers
compiled output in binary form, so the assembly `word build -asm` prints isn't included. Compiling
with word doesn't make your program a derivative work of word.
