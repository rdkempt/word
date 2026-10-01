# `word` language specification (golden)

> The name `word` comes from the value model: every value is one 64-bit machine word. Nothing in the
> language depends on the name.

This is the frozen specification for `word` 1.x, and the compiler is built against it: if the
implementation and this document disagree, one of them has a bug. Where a rule has a reason behind it,
the reason is given with the rule.

---

## 0. Two design decisions

Two rules do most of the work, and the rest of this document refers back to them:

- **A low tag on the word decides its kind, and a number spends one bit of it.** A number sets the
  low bit and holds a signed 63-bit value in the rest (`w >>arithmetic 1`, so `-2^62 .. 2^62 - 1`).
  Every other kind is an 8-byte-aligned pointer, and those share a 3-bit tag in the three spare low
  bits: `000` region, `010` boxed float, `100` boxed extension (the map is its only subkind so far),
  and `110` singleton, where the whole word is the value (`null`, `false`, `true`, `none`). The
  runtime tells these apart with one mask and no memory access (§3.6). Text, arrays and bytes are all
  regions, and a flag in the region's header tells them apart. The tag lives in the value's own
  alignment bits, so it travels with the word into an array cell and back. That's what makes arrays
  of strings (and arrays of arrays) work, and it means no integer, whatever its size, can be mistaken
  for a region. The tag is invisible to `word` code: `'A'` is still `65` to the program.
- **An operator's result kind never depends on its operands.** `+` always gives a number, a
  comparison always gives a boolean, and `.` (join, §3.3) always gives a region. No operator changes
  meaning because of what the user typed at a prompt. That's why `+` and `.` are separate operators:
  in JavaScript `x + 3` adds or concatenates depending on whether `x` holds a number or a string, and
  that can't happen here.

---

## 1. Philosophy

`word` is a small language built on one idea: every value is a single 64-bit machine word. The
word's low bits say what kind of value it is (§0). An integer or a character code sits in the word
itself, a region is a pointer to memory, and a float or a map is a pointer to a small boxed cell. The
compiler moves words around and the CPU does integer arithmetic on them. There's no garbage collector,
and the runtime is a set of routines the compiler writes into each program.

When the compiler can't prove a word's kind, the runtime checks the tag with a mask (§3.6). A word
stored into an array and read back is the same word that went in.

The model has costs, and I'd rather show them than hide them. Floating point and byte-packed text are
where it strains, and the sections on them (§2.6, §3.4, §3.6) say what they cost.

The syntax is meant to be readable by someone who has never programmed: indentation instead of braces,
no type annotations, one way to print, one way to join, and five keywords. I wanted a language that's
quick to write in and small enough to implement end to end.

**Design goals**

- **Small, with no gaps.** Few keywords, operators and concepts, but nothing missing that would force
  a workaround.
- **No type bookkeeping for the programmer.** There are no annotations, and no conversion call to put
  a number into text. Where a number and a region have to be told apart, the compiler or the runtime
  does it.
- **An operator's result kind never depends on its operands.** `+` always gives a number, and every
  comparison gives a boolean, `true` or `false`, never a number standing in for one. This is how the
  language can be untyped and still predictable. It also decides which operations may accept any
  kind: `out`, `.` and the comparisons can, because what they give back is the same kind whatever
  goes in.
- **Compiled to native code.** `word` emits assembly and links a native executable: a static ELF on
  Linux (x86-64 or arm64), a PE `.exe` on Windows, and a Mach-O on macOS (Apple Silicon). It isn't a
  transpiler or an interpreter.
- **Readable at a glance.** Indentation shows the structure, and the grammar avoids constructs whose
  meaning depends on the context around them.
- **Simple to implement.** Each phase of the compiler is small enough to hold in your head.

**Non-goals**

A type system, generics, classes or objects, closures or nested functions, namespaces, a module system
beyond whole-directory inclusion and a short list of built-in modules, exceptions, manual memory
management, and concurrency. I've deferred several of these, and §15 comes back to them. Floating
point (§2.6, §3.6: a boxed double on the `010` tag) and the associative array (§3.7: `{}` is a map,
and it prints as JSON) might look like they belong on that list, but both are part of the language.

---

## 2. Lexical structure

### 2.1 Source text

Source files are UTF-8, with the `.w` extension. Outside string literals, character literals and
comments, only ASCII means anything: a non-ASCII byte there is a compile error, and so is any byte that
can't start a token (`$`, for example, or a control character). A file that starts with a UTF-8 byte
order mark is refused, and the message tells you to save it without one. Inside a literal the unit is
the **Unicode scalar value** (code point), not the byte: `"café"` is four elements, and `'é'` is the
single number `233`. Only well-formed UTF-8 decodes, by the same rule as at run time (§12.4): the
shortest form, no surrogate, nothing past U+10FFFF. A byte that begins no such sequence is an element
of its own, and so is every byte after it that the sequence did not complete.

### 2.2 Newlines terminate statements; indentation defines blocks

A newline ends a statement, and there's one statement per line. This takes the place of the semicolon
most languages use. The one exception: a newline inside an unmatched `(`, `[` or `{` is ignored, so a
long call, index or map literal can wrap across lines:

```javascript
total = add(
    first,
    second           // fine: inside unmatched (
)
```

There's no line-continuation character, and no automatic semicolon insertion beyond that bracket rule.
A `\` at the end of a line is a compile error that says it isn't a line continuation, and a `;` is an
error too (§2.10).

A line ends at a newline (`\n`). A carriage return (`\r`) just before it doesn't count, so a file
saved with Unix (LF) or Windows (CRLF) line endings compiles the same.

A **block** (a function body, a loop body, the body of an `if` or `else`) is written by indenting it
further than its header, and it ends when the indentation comes back to the header's level. There are
no `{ }` around a block and no `end`, so the indentation you see is the structure the compiler reads.

```javascript
add(a, b)
    return a + b     // this line is the body of add, because it is indented under the header
```

**Spaces only.** Indentation must be spaces. A tab in a line's indentation is a compile error
(`indent with spaces, not tabs`). Languages that allow both and then complain about mixing still let a
tab and some spaces line up on screen while meaning different depths; with one indentation character
that can't happen. Tabs between tokens are fine, and so is a tab on a blank line, a comment-only line,
or a continuation line inside unmatched brackets, since none of those has indentation that counts. The
number of spaces per level is up to you: a block only has to be indented consistently, and deeper than
its header.

Precisely:

- Every line of a block has the same indentation. A deeper indent is legal only right after a block
  header, and anywhere else it's an error (`unexpected indent`).
- A header with nothing indented under it is an error, reported at the header:
  `expected an indented block after this 'if'`. There are no empty blocks and no one-line block
  forms.
- Coming back to an indentation that matches no open block is an error (`inconsistent dedentation`).
- **Blank lines and comment-only lines have no indentation.** They never open or close a block, at
  any depth.

**`word format`.** Since the width of a level is up to the writer, the same structure can be spelled
many ways. `word format app.w` rewrites the file in place to one layout: four spaces per nesting level,
trailing whitespace stripped, and every comment lined up with the code it precedes, even across a
dedent. It has no options, so every formatted file uses the same layout. It reads structure the way the
lexer does (an indent stack over leading-space counts, §4), and a continuation line inside brackets
moves with the line that opened them. A mis-nested line moves to where the compiler actually reads it,
so you can see the mistake. The formatter only changes whitespace. It lexes its own output again and
won't write the file unless the token stream, `INDENT` and `DEDENT` included, is the same one the input
produced, so formatting can't change what a program means. An input that doesn't lex, or that indents
with a tab, gets the compiler's located error, and the file is left as it was.

### 2.3 Comments

`//` begins a comment that runs to the end of the line. There are no block comments.

### 2.4 Keywords and contextual words

There are five keywords:

```
if   else   loop   return   break
```

`break` is only legal inside a loop. Four more words are reserved because they're values: `null`,
`false`, `true` and `none` (§3.8). They can't be used as names either.

Five other words are **contextual**: they mean something in one position and are ordinary identifiers
everywhere else. The lexer doesn't know them; the parser does.

| Word | Meaningful where |
|---|---|
| `before`, `after` | immediately after `:` in a contract suffix (§8.2) |
| `result` | inside an `:after` hook body (§8.2) |
| `import` | first token of a line, in `app.w`'s import prologue (§11.1) |
| `in` | between the variable and the region of a `loop x in y` header (§7.2) |

`in` is also the name of the stdin builtin `in()`. The two don't collide, because the parser recognizes
the loop form by its position (`loop NAME in`), and everywhere else `in` is an ordinary name or the
builtin call.

### 2.5 Identifiers

An identifier starts with an ASCII letter or `_` and continues with ASCII letters, digits or `_`, and
it can't be one of the five keywords or the four reserved values (§2.4). Identifiers are
case-sensitive. Builtins (§9) are ordinary identifiers the compiler recognizes, not reserved words: a
program may define a function with a builtin's name, and then the program's definition wins. One
function name is taken: `_toplevel` is the name the compiler uses for the top-level statements, and
defining a function with it is a compile error.

### 2.6 Number literals

An integer literal is a run of decimal digits: `0`, `42`, `1000000`. An underscore between two digits
is a separator and is ignored (`1_000_000`), and that works in the fraction and the exponent of a float
as well (`3.141_592`, `1e1_0`). An underscore anywhere else in a number is an error (`1000_`, `1__000`,
`1_.5`). A leading one isn't part of a number at all: `_1000` is an identifier. There are no hex, octal
or binary forms, and a digit immediately followed by an identifier character (`0x1F`, `12abc`) is an
error, not two tokens.

**Float literals.** Digits with a decimal point, an exponent, or both: `3.14`, `0.5`, `2.0`, `1e6`,
`1.2e-9`, `2.5E3`. The point needs a digit on each side, so `3.` and `.5` aren't floats, and a `.`
anywhere else is the join operator (§3.3): `a.b` joins, and `3.14` is one number. An exponent is `e`
or `E`, an optional `+` or `-`, and at least one digit. An exponent on its own makes the literal a
float, so `1e6` is a double.

A float is an IEEE-754 double (§3.6), and a float literal has its own range, separate from the integer
one. A literal past the double's range becomes `inf` or `0.0`, as IEEE says, with no diagnostic. The
integer literal limit below doesn't apply to floats, so `9000000000000000000.0`, past it, is an
ordinary double.

**A float literal is the nearest double to all of its digits.** The compiler keeps the digits as a
decimal integer and a decimal exponent, then doubles or halves that value (both exact in base ten)
until its integer part is a 53-bit significand, and rounds half to even on the digits left below the
point. No division and no floating-point arithmetic are involved, so no error can build up: `1e-300`,
`5e-324` and `1.7976931348623157e308` get the same bits `strtod` gives, and so does every literal in
between. `dev/toolchain/test_float_exact.sh` checks this against Python's `strtod`.

The value is worked out at compile time. At startup the program stores each float literal's bits into
a constant slot, with no arithmetic, and a use reads that slot.

`+ - * /` give a float when either operand is a float, and `/` also gives a float for two integers that
don't divide evenly (§3.3). `%` and the bitwise operators refuse a float.

**How a float prints.** `out`, `.` and `stringify` (§12.3) write a float in plain decimal at every
magnitude. The notation never switches to `1e-20` or `1.5e+300`, so there's no threshold to remember.
A float prints to about fifteen significant digits: `0.5` prints as `0.5`, `1.5e-20` as
`0.000000000000000000015`, and `1e308` as all three hundred and nine of its digits. The exact count
depends on the size of the value:

- below 1, 14 significant digits (`1 / 3` prints as `0.33333333333333`);
- from 1 up to 1e14, 15;
- from 1e14 up to 2^63, every digit of the whole part and one after the point (`123456789012345.7`,
  `1234567890123456768.0`);
- from 2^63 up, 15, then zeros up to the point.

The last digit printed is rounded half up from the value's exact decimal expansion. The four largest
doubles, from `1.7976931348623151e308` up, are the exception: rounded, they'd print as a number past
the largest double, which reads back as `inf`, so they're cut off at 15 digits instead.

Trailing zeros after the point are trimmed, but a float always keeps its point and at least one digit
after it, so `2.0` prints as `2.0` and never as `2`. That's how you can see in the output that a value
is a float. Fifteen digits is fewer than a double holds, so a float with a fraction, or one past 2^63,
can lose its last place when printed: `0.1 + 0.2` prints as `0.3`. A whole number below 2^63 prints
exactly. When the last bit matters, use the value, not its text.

**Non-finite floats.** Float arithmetic follows IEEE. A division by zero with a float on either side
gives `inf`, `-inf` or `nan` and doesn't fault (an integer division by zero does, §3.1). `nan == nan` is false, and so is any
ordering comparison with a `nan`: `n < 1.0`, `n <= 1.0`, `n > 1.0` and `n >= 1.0` all answer false,
whether or not the compiler can see that `n` is a float. `out` and `.` write the three as `inf`,
`-inf` and `nan`. Inside an array or a map, which print as JSON, they fault instead (§3.7). A `sort`
that meets a `nan` still finishes and orders the same way on every target, but no order puts a `nan`
in its place.

Turning a float into an integer is stricter. `round(x)` (§9) faults on `inf`, `-inf` and `nan`, and on
any finite value too large for the integer range, because there's no correct whole number to give back
(§10.2).

**Range.** Integer values are 63-bit, because the value model spends the low bit of every word on the
number tag (§3.6, `docs/VALUE_MODEL.md`). A computed value spans `-2^62 .. 2^62 - 1`, and unary `-`
reaches the negatives. An integer literal is limited to `0 .. 2^61 - 1` (`2305843009213693951`),
half the value range, and the lexer rejects anything larger with a located error. The limit comes from
the compiler: it writes a literal as the tagged word `value*2 + 1`, and it works that out in its own
63-bit arithmetic, where `(2^61 - 1)*2 + 1` is the largest that fits. A larger value takes arithmetic,
for example `n = 2305843009213693951` followed by `n = n + n`. Arithmetic can go up to the edge of the
value range, and past that it traps instead of wrapping (§3.1, §10.2). The underscore rule and the
digit-then-letter rule (`12abc`, `0x1F`) are checked by the lexer as well, each as a located
`file:line:col:` error.

### 2.7 Character literals

`'x'` is a character literal: single quotes around one character. Its value is that character's
Unicode scalar value as a full 64-bit word, so `'A'` is the integer `65` and the two can't be told
apart. A character literal must hold exactly one code point and be closed by `'`. `''` (empty), `'''`
and `'ab'` are all rejected by the lexer with a located `file:line:col:` error. Write `'\''` for a
quote.

### 2.8 String literals

`"..."` is a string literal, in double quotes. It evaluates to a word: a reference to a statically
allocated, length-prefixed region with one element per character (§3.4). A literal's region is
read-only (§3.5).

Escapes, valid in both string and character literals:

```
\n  \t  \r  \0  \\  \'  \"
```

`\0` is an ordinary element with the value zero. A region carries its length, so an embedded zero
doesn't end or cut anything. There's no `\x` or `\u` escape; type the character itself. Any other
escape, a backslash at the end of a line, and a backslash at the end of the input are located lex
errors. A raw line break can't appear inside either kind of literal: write `\n` or `\r` when you mean
that character.

The difference between `'A'` and `"A"` is central to how `word` reads: `'A'` is the number 65, and
`"A"` is a reference to a one-element region. They're two ways to *build a word*, and the compiler
doesn't treat them as two types. See §3.3.

### 2.9 The `:` rule

`:` is legal in exactly two positions:

1. as a contract suffix in a function header: `:before` / `:after` (§8), and
2. as the separator in a map literal: `{name: "Ada"}` (§3.7).

**`:` anywhere else is a syntax error.** In particular a block header doesn't end in `:`, because
indentation alone opens a block. Keeping `:` to these two places means a later feature can't give it a
meaning that overlaps them. Writing `:=` is an error that tells you to use `=` (§5).

### 2.10 Operators and punctuation

```
Arithmetic     +  -  *  /  %
Join           .
Comparison     ==  !=  <  <=  >  >=
Logical        &&  ||  !            (&& and || short-circuit)
Bitwise        &  |  ^  ~  <<  >>
Assign         =                    (declares the first time, stores after, §5)
Grouping       (  )
Indexing       [  ]
Map literal    {  }                 (a key -> value store, §3.7)
Separator      ,
```

The longest match wins, so `<=` beats `<` and `==` beats `=`. There are no compound assignment
operators like `+=`: write `i = i + 1`. There's no `;`, and blocks are indentation (§2.2), which leaves
`{ }` free to mean a map. A newline inside `( )`, `[ ]` or `{ }` doesn't end a statement, so a map
literal can span lines. The join operator is a single `.` (§3.3), and there's no `..`. A float literal
needs a digit on both sides of its point, and there's no field access or method call, so `.` has
nothing else to collide with.

---

## 3. The value and memory model

### 3.1 Everything is a word

An integer is a 63-bit signed value (the value model spends one bit of the machine word on the kind
tag, §3.6). Arithmetic traps on overflow: when `+`, `-`, `*` or unary `-` has a true result outside
`-2^62 .. 2^62 - 1`, the program stops with `integer overflow` (§10.2) instead of wrapping around to a
wrong answer. On x86-64 the check is a single `jo` after the arithmetic (§3.6); arm64 uses `b.vs`, and
an `smulh` test for `*`. `%` is the remainder, with the sign of the dividend.

These stop the program the same way: division or remainder by zero (`divide by zero`); `MIN / -1`
(`MIN` being `-2^62`), whose true result overflows, and `MIN % -1`, which stops with the same
`integer overflow` even though its answer, 0, fits; and a shift whose count is outside `0 .. 63`
(`shift out of range`). The hardware would mask a shift count to six bits, and I'd rather spend an
instruction than have `1 << 64` mean `1 << 0`. `>>` is an arithmetic shift: it copies the sign
bit, because there's one integer type and it's signed. The bitwise operators `&` `|` `^` `~` `<<` `>>`
never overflow. They work on the value's bits and can't leave the range, so `<<` checks its count and
nothing else: bits shifted off the top are lost, and `1 << 62` is `-4611686018427387904`. Their only
faults are a shift count outside `0 .. 63` and an operand that isn't a whole number (§3.3).

### 3.2 Truthiness

**A condition must be `true` or `false`.** `if`, `loop`, `&&`, `||` and `!` ask a yes-or-no question,
and only those two words answer it. A number (`0` included), a float, a region and a map aren't
conditions: used as one, each is a compile error where the compiler can see its kind, and a run-time
fault where it can't. `null` and `none` aren't conditions either, and using one is always a run-time
fault (§3.8), even when it's written as a literal. The message says what comparison to make instead.

Since a number isn't a condition, C's rule that `0` is false and anything else is true doesn't apply.
`if n` on a count, `if find(s, c)` for "was it found?" and `if o["email"]` for "is the field set?" are
all refused. If they weren't, the last two would take a miss for a yes and go wrong the day the field
holds `0`. `find` and a map lookup that misses answer `none` (§9, §3.7), which a condition refuses too.
Write the question you mean:

| to ask | you write |
|---|---|
| is this number non-zero? | `n != 0` |
| is this region empty? | `len(s) == 0` |
| was there a value? | `o["email"] != none`, or `has(o, "email")` (§9) |
| did the find hit? | `find(s, c) != none` |
| is the flag set? | `flag`, when `flag` already holds `true` or `false` |

Comparisons and the logical operators answer `true` or `false`, so `kind(1 == 1)` is `"boolean"`,
`(1 == 1) == true` is true, and a comparison's answer is what a condition takes. `!x` needs `x` to be a
boolean and answers the other one. `&&` and `||` need both operands to be booleans and answer a
boolean. The same test applies everywhere a condition appears. Where other languages answer with a
sentinel, `word` answers `none`: `find` gives `none` where C would give `-1`, and `env` gives `none` for
an unset variable instead of `""` (§9). That's what makes "compare it" possible in every case.

### 3.3 Kinds and what each operator does

Every value is a word, and its kind is one of the eight names `kind()` answers: *number*, *text*,
*bytes*, *array*, *map*, *boolean*, *null* or *none* (§3.6, §3.8). Numeric and character literals build
numbers, string literals build text, and map literals build maps. There's no array literal: arrays and
bytes come from builtins, such as `array(n)`, `split` and `parse` for arrays and `bytes(n)` and `read`
for bytes (§9, §12). `true`, `false`, `null` and `none` are the four singleton values (§3.8):

| You write | You get (a word that is...) |
|-----------|---------------------------|
| `42`      | the integer 42            |
| `'A'`     | the integer 65            |
| `"A"`     | a reference to a region holding one element |
| `{a: 1}`  | a reference to a map holding one key and its value (§3.7) |

Operators never convert a value from one kind to another. Numeric operators give numbers, `.` gives a
region, and comparisons and the logical operators give booleans. An operation that doesn't accept a
value's kind reports an error. Within *number*, arithmetic does tell an integer from a float, by the
rules below.

- **`+ - * / % & | ^ << >> ~` and unary `-` are numeric.** Both operands must be numbers, integer or
  float. Anything else is an error, at compile time when the kind is known and at run time otherwise.
  Text is never turned into a number behind your back, and `in()` already gives you a number when the
  line it reads is one (§9). Integer or float:
  - **`+ - *` and unary `-`** give an integer when both operands are integers, and a float when either
    operand is a float (the integer is promoted).
  - **`/` gives the exact answer.** Two integers that divide evenly give an integer, and otherwise
    a float, so a remainder is never thrown away: `6 / 3` is `2`, `7 / 2` is `3.5` and `1 / 2` is
    `0.5`. A float operand makes the answer a float, as usual. Which one you get depends on the
    *values*, not on the kinds, so it's decided at run time: an exact division allocates nothing and
    costs one extra test, and an inexact one boxes a double.
    There's only one division operator. With two, everyone has to learn which is which and remember it
    on every line they read. When you want the whole part, write it out: `(a - a % b) / b` is always
    exact, so it always answers an integer, and it rounds toward zero, because `a % b` takes the sign
    of `a`. `a >> 3` divides by eight and rounds down (toward minus infinity), so it matches the other
    form only when `a` isn't negative: `-7 >> 3` is `-1`, where `(-7 - -7 % 8) / 8` is `0`.
  - **`%` and the bitwise and shift operators `& | ^ << >> ~`** are integer-only. A float operand is an
    error (`operator needs whole numbers`).

- **`== != < <= > >=` compare by content and always give a boolean.** Two numbers compare numerically.
  An integer compared with a float is converted to a double first, which is exact up to 2^53, so past
  that two different values can compare equal: `9007199254740993 == 9007199254740992.0` is true.
  Two regions compare element by element, lexicographically, and when one is a prefix of the other
  the shorter one is less. A string is an array of character codes, so this gives string equality and
  ordering with nothing string-specific, and array comparison comes with it. (In the examples below,
  `[a, b]` stands for an array holding `a` and `b`. `word` has no array literal; the examples hold for
  arrays built with `array(n)` or `parse`.)

  Content means content all the way down. Two elements that aren't the same word are still equal when
  they're equal structures, so `[[1, 2]] == [[1, 2]]`, and a parsed payload equals the map literal it
  came from. Numbers keep their meaning at every depth: an integer element equals a float element of
  the same value, so `[1] == [1.0]`, just as `1 == 1.0` and as a map's values compare. On text and
  integer arrays this costs nothing extra: two integers are compared as words and nothing recurses.
  `find` matches a run by the same rules, because it answers where `==` would.

  Ordering works the same way. The element pair that decides a comparison is ordered by these rules
  too, not by its words: `[["a"]] < [["b"]]` compares the nested text, `[1] < [1.5]` compares two
  numbers, and a pair with no order (a map, a singleton, or a number against a region) is the same
  error it would be on its own (§10.2). For two integers, comparing the words already gives the right
  answer, and that covers all text and every integer array. A `nan` element (§2.6) leaves the two
  regions unordered: every ordering operator on them is false, as it is on the numbers themselves.
  `sort` uses the same comparison, so it sorts rows of text by their text. The walk is bounded by the
  stack guard every function call has, so a structure too deep to finish comparing ends with
  `comparison nests too deeply (a cycle?)` (§10.2), never a crash. How deep that is depends on the
  stack size, which is 8 MB by default on Linux and on Windows. `parse` caps nesting at 1000 levels, so
  only a program that builds a deeper structure itself can reach the limit.

  **Cycles.** A program can build a cycle (`a[0] = a` is an ordinary store), and two separately built
  cyclic structures have no finite comparison to make. `word` doesn't compare infinite structures: a
  comparison of either kind that walks into one stops at the bound above, with a message that points
  at the likely cause. Two names for the same region don't get that far, because an element that is
  the same word as the one it's compared with is equal without recursing. So `a == a` is `true` however
  `a` is tangled, unless it holds a `nan`, which never equals itself. A pair that differs before the
  walk reaches the cycle is decided where it differs. `out`, `.` and `stringify` stop on a cycle the
  same way, with `json: value nests too deeply (a cycle?)`.

  Two maps are equal when they hold the same keys with equal values. Insertion order doesn't count,
  so `{a: 1, b: 2} == {b: 2, a: 1}`. Values compare by the same rules, so nested maps and text compare
  by content. Maps have no order: `<` on a map is an error, and so is `sort` or `find` over one.

  The singletons compare only by identity. `true` and `false` are both booleans but are different
  values, and `null` and `none` each differ from every other value. They have no order. Between **mixed
  kinds** (a number and a region, a singleton and anything else, or either of those and a map), `==` is
  `false`, `!=` is `true`, and an ordering comparison is an error (§10.2 lists which). So `if x == 0`
  reliably means "x is the number zero", even when `x` came from somewhere the compiler couldn't
  analyze, and a failed conversion is tested with `x == none` (§3.8, §12). A float on one side changes
  nothing: `none == 15.0` is `false`, and `none < 1.5` is an error.

  Comparison can accept any kind for the same reason `out` can: whatever goes in, one of two words comes
  out. There's no way to ask whether two words refer to the *same* region (no identity comparison), so
  a program can't tell whether the compiler shares equal literals.

- **`.` joins, and always gives a region.** `a . b` allocates a new region holding the elements of `a`
  followed by the elements of `b`. An operand that is a map or an array-marked region is written as
  JSON first, the same text `out` would print (§3.7). A number is written as decimal text first
  (an integer as digits, a float with a decimal point: `3.14`, `2.0`), and a singleton as its name.
  So `"Age: " . age`, `n . "!"`, `"pi is " . 3.14` and even `2 . "pac"` (the region `"2pac"`) all work
  with no conversion call. Joining two unmarked regions of integers (text, or a `text(n)` buffer)
  concatenates them, because a string is an array of integers. An `array(n)`, a parsed array or a
  `split` result carries the array mark and is written as JSON, so concatenating two arrays of values
  takes a loop. `.` is kept separate from `+` because a `+` that means sum or concatenation depending
  on its operands, as it does in JavaScript, gives a different kind of answer for different input.
  With two operators, `+` is always arithmetic, `.` is always a join, and you still never write
  `str()`. `.` associates left, and a chain of three or more parts allocates its result once, when
  nothing from its third part on is a call: `"line " . i . " of text"` is one new region. From a call
  there on, the chain joins pair by pair, one region per `.` (§14). The self-append form
  `s = s . a . b` appends in place instead (§3.4).

`.` doesn't clash with a float's point, because a float literal needs a digit on both sides of the
point (§2.6): `3.14` is one number, and `a . b` (or `3 . x`) is a join. `.` has no field-access or
method meaning, since `word` has neither.

### 3.4 Regions: strings and arrays

The first aggregate is the **length-prefixed region**, a reference to a block laid out as

```
[ len ] [ elem 0 ] [ elem 1 ] ... [ elem len-1 ]
```

Every cell is one word (8 bytes), and the reference is the address of the `len` cell. Arrays and
strings use this same representation: a string is an array of character codes.

- `len(p)` reads the `len` cell, in O(1).
- `p[i]` reads element `i`, the word at offset `(i+1)*8`.
- `p[i] = v` writes element `i`.
- **Indexing is bounds-checked.** `p[i]` with `i < 0` or `i >= len(p)` stops the program. The length
  prefix makes the check cheap, and it's the reason the prefix exists.

**A header sits in front of the length.** The two cells before `len` hold the region's flags and its
allocated capacity, so the full block is `[ flags ][ cap ][ len ][ elem 0 ] ... [ elem len-1 ]`, and
the reference still points at the `len` cell. With the header at negative offsets, `len(p)` (`[p]`)
and `p[i]` (`[p + (i+1)*8]`) don't pay anything for it. The capacity is what lets `s = s . x` grow a
region in place. When the compiler can prove `s` is the only reference to its region (a small
per-function pass that checks the name is never copied to another variable, read out of a region,
stored into one, used as a map key, or passed to a function that can keep it, §3.5), it appends into
the old buffer and doubles the capacity when it fills. An append loop then costs amortized O(1) per
append instead of O(n²) in total. A region that isn't proven unique, is aliased, or is a literal falls
back to allocating a new region and copying, so `.` means the same thing either way (§3.3) and the
program can't tell which happened. A literal's capacity equals its length, so the first append to one
reallocates and never writes the read-only pool.

`s = s . x` is still `.`, so it has to give the same answer `t = s . x` would, for every `s`. Growing
in place only applies when `s` is a plain region. A map or a JSON array is written as JSON under `.`
(§3.7), so those take the ordinary join and aren't extended. The in-place path also keeps the
byte-backed subkind the way the join does (below).

**Self-append chains.** A chain associates left, so `s = s . a . b` is `s = (s . a) . b`, and its outer
left operand is a *temporary*, not `s`. The compiler lowers this form to one in-place append per
operand, so a chain and the two-operand form are both amortized O(1), and
`s = s . name . ": " . value` in a loop is fast as well as natural. A chain whose operands mention the
target (`s = s . x . s`) falls back to allocate-and-copy, because appending in sequence would append an
`s` the first append had already grown, and that's a different answer from the chain's.

**A cell can hold anything a variable can**, including a reference to another region. Arrays of
strings and arrays of arrays are ordinary: `a[i][j]` reads element `j` of the region stored in cell
`i`. This works because the kind is part of the *word* (§3.6), so the word that comes out of a cell is
the same word, bit for bit, that went in. If the kind lived in storage attached to a variable instead,
an array of strings couldn't be written this way.

**Every element is a full word**, the characters of a string included. `"hi"` is the region
`[2][104][105]`: three words, 24 bytes, not packed bytes. That's 8x the memory of packed text, which
doesn't matter for the short scripts `word` is for, and in return every region works the same way:
`s[i]` scales by 8 whether `s` is a string or an integer array. Element size is the kind of thing a
type records, so there are no element-size types; packed bytes are an internal **region subkind**,
described next.

**Byte-backed regions.** The 8x cost is real for file data: an 8 MB file would take 64 MB. So `read`
(§12.1) returns a *byte-backed* region, with one byte per element and a flag in the region header,
which costs 1x the file size. `bytes(n)` (§9) and `asmtake` (§12.5) return one too, so a program that
builds a buffer instead of reading one gets the same 1x cost. `d[i]` still gives the byte as an
ordinary integer, and `len` is still the element count. `copy`, `.`, `==`, `find`, `number` and `sort`
give the same answers they would for a region of code points; the ones that walk elements a word at a
time promote a byte-backed operand first. Four things differ:

- `kind()` answers `"bytes"` for a byte-backed region and `"text"` for a region of code points (§3.3).
- An index store into a byte-backed region keeps the low 8 bits of a whole number: `d[1] = 300` reads
  back as `44`, and `d[0] = -1` as `255`. Anything that isn't a whole number, a float included, is a
  fault (§9).
- `out` and `write` (§12.1) send a byte-backed region's bytes as they are, where a region of code
  points is written as UTF-8. The two differ for elements from 128 to 255: a byte-backed `233` is
  written as the byte `0xE9`, and a code point `233` as `0xC3 0xA9`.
- JSON reads a byte-backed region as UTF-8 text. `parse` decodes a byte-backed document before it
  parses it, and `stringify` (and `out` or `.` of a map or an array) writes a byte-backed string as
  the characters its bytes spell (§12.3), where a region of code points is written element by
  element.

**`==` and `!=` don't promote.** A comparison reads each side with the load its own backing needs,
because a byte-backed element `b` holds the same value as the word-backed `2b+1` and there's nothing
to convert. That saves more than instructions, because a promotion *allocates*: `line == "quit"` in a
loop over a file leaves no copy in the arena, so 400,000 comparisons of a three-byte slice against a
literal allocate nothing, where promoting would have allocated 48 bytes for each (about 19 MB).
Ordering (`<`, `<=`, `sort`) does still promote.

So reading a file, indexing it, printing it and writing it back are byte-exact and cheap, while string
*literals* and every other region stay word-backed code points. The memory saving is where it matters,
in I/O. A `copy` of a byte-backed region stays byte-backed (§9), so a program that reads a file and
prints parts of it pays 1x throughout, and a slice of a text file prints like the whole of it. A **join
of two byte-backed regions is byte-backed too**: `a . b` where both sides came from `read`, `bytes(n)`
or a slice of one is the bytes of each, concatenated, at 1x. Promoting both operands to a word per
element and allocating a word-backed result would cost 16x the bytes being joined. A join with anything
else (a literal, a number, an ordinary region) gives code points, because the other side may hold
values above 255. Appending follows the join, since it's the same operator: `s = s . x` with both
sides byte-backed grows `s` by a byte per element, and a mixed pair promotes the way `a . b` does. A
program that reads a file and appends to it pays 1x too, on both backends, instead of the 8x memory
and 8x copying a promoting append costs.

There's no `ord`, because a character is its code: `s[i]` already gives a number, and storing a
number into `s[i]` stores a character. The one time a code point needs turning into text is to join
it, since `s . 72` writes the number `72`; `char(n)` (§12.4) makes the one-element region for that.

### 3.5 Memory: allocate, never free

Regions made by `array`, `copy`, `.` (join), `in`, `read` and the other builtins come from one growing
arena. **There's no `free` a program can call, and nothing is collected**: the OS takes everything back
at exit. `word` programs are short-lived scripts, and this is what lets the language have no types and
no garbage collector and still be pleasant to use. An allocation that can't be satisfied stops the
program (`out of memory`, §10.2).

That doesn't mean every allocation counts toward a program's peak. A bump allocator can reclaim in one
situation, when the thing being dropped is the most recent allocation, so the bump pointer can move
back over it. The runtime does that where the compiler can prove ownership, and none of it is visible
to a program. Only the first of these applies on both targets. The other four are x86-64 only: the
arm64 backend keeps every temporary, so the same loop can grow on arm64 where its peak is flat on
x86-64.

- **An integer being joined is not allocated at all** (both targets). `"n=" . i` renders `i` into a
  static scratch region and copies it out, so no arena region is made for a value that is gone after
  the next instruction. This is for integers only; joining a float allocates every time.
- **Appending to the most recent region extends it** (x86-64 only). `s = s . x` in a loop grows `s` by
  moving the bump pointer instead of allocating a bigger buffer and copying, so the run doesn't keep
  the dead half of every doubling.
- **A temporary used as an argument and not kept is popped** (x86-64 only). `out("n=" . i)`,
  `m["k" . i]`, `has(m, "k" . i)` and `len(copy(s, 0, 3))` each build a region that the operation uses
  up and nobody keeps, and the bump pointer moves back over it. Only operations that *always* allocate
  their result qualify: `.`, and the builtins that can't hand back a region they were given.
- **A region a name is about to overwrite is given back** (x86-64 only). `t = copy(s, i, 64)` in a
  loop makes the previous window unreachable the moment the new one arrives, so it's dropped, and the
  peak of a loop that slices is one window. This needs the same proof as the in-place append (§3.4):
  the name is never copied to another variable, read out of a region or stored into one. The
  right-hand side mustn't mention the name, has to allocate every time, and has to leave its result as
  the most recent allocation: `.`, `copy`, `keys`, `array`, `text`, `bytes`, `read`, `in`, `env` and
  the net verbs qualify. `sort` and `args` don't, because each allocates something after the region it
  returns. A name that fails any of these keeps everything, which is the safe answer.
  **Passing the name to a function doesn't disqualify it by itself.** The compiler works out once per
  function whether an argument can still be reachable when the call returns (returned, stored in a
  region or a map, or passed on to another function), and only those arguments block the rewind. A
  callee that only reads through its parameter doesn't. A function the pass didn't see is assumed to
  keep everything, as everywhere else here.
- **A float that only crosses a call isn't boxed** (x86-64 only, §15). The arm64 backend boxes a float
  argument before the call and again inside the callee.

A fetch is only partly covered. The text `get()` returns is decoded into a new region, and on x86-64
the rewind above can give that region back, but the response bytes it was decoded from and the
buffers that read them stay in the arena. A loop of fetches grows with every response it reads, on
both targets (§12.2).

These are optimizations with no meaning attached: a program can't tell which of them fired, and none of
them changes when a value is valid. The guarantee stays the same: you never free anything, and nothing
you can still reach is ever taken away.

String literals live in a read-only part of region space. Writing into a literal's region with
`s[i] = v` stops the program with `write to a literal` (§10.2), because the runtime can see from the
address which part of region space it's in.

### 3.6 How a word's kind is decided

A word's kind is carried in its low bits, as a tag that goes everywhere the value goes. Numbers are
the common case, so a *number* spends a single bit. The pointer kinds are 8-byte aligned (their low 3
bits are zero), and they share a 3-bit tag in those spare bits:

```
  ...1    number    - the value is w >>arithmetic 1  (a signed 63-bit integer)
  ...000  region    - w is the pointer itself; dereference it with no adjustment
  ...010  float     - w & ~0b111 is a pointer to an 8-byte IEEE-754 double in the arena
  ...100  extension - w & ~0b111 is a boxed cell whose first word is a subkind
                      (subkind 0 = a map, §3.7; the rest are unused)
  ...110  singleton - the whole word IS the value: null=6, false=14, true=22,
                      none=30 (§3.8). No pointer, no allocation, no dereference.

is_integer(w)   ==  (w & 1) == 1                           # cheapest: a single `test`
is_region(w)    ==  (w & 0b111) == 0
is_map(w)       ==  (w & 0b111) == 0b100
is_singleton(w) ==  (w & 0b111) == 0b110

kind(w) == "number"  ==  (w & 1) == 1 || (w & 0b111) == 0b010   # an integer OR a float
```

`kind(x) == "<name>"` is the language's only kind test. The compiler recognizes the whole comparison
and compiles it to a test like the ones above, not to a call, so no name is built and none is compared
(§9). A name that isn't one of the eight (§9) is a compile error, since it would be a test that
could never be true.

A singleton is the word itself, not a pointer, so comparing against one is a single word compare. That
makes `x == none`, the test §3.8 asks you to write, cheap and exact.

A **float** is a boxed double: the value is a pointer (low bits `010`) to eight bytes of IEEE-754 in
the arena. Boxing keeps every value one 64-bit word, at the cost of an allocation per float. I think
that's affordable because `word` programs are mostly integers and floats are the rare case. On x86-64
the compiler also keeps a float as a raw double in a register or a frame slot where it can prove
nothing else needs the box, so many float results never allocate (§15); the arm64 backend boxes every
float result. `docs/VALUE_MODEL.md` ("Floats") describes the representation. The `100` tag is the boxed
**extension**: its cell's first word is a subkind, and one subkind is defined so far, the map (§3.7).
Sending every future boxed kind through one tag and a subkind word is what let `110` go to the
singletons (§3.8) without closing anything off: a new boxed kind is a new subkind, not a new tag, so
the tags don't run out.

Telling the tags apart (integer, float, region, map, singleton) takes one or two instructions and no
memory access. Telling text, an array and bytes apart takes one more step: it reads the flags word in
the region's header, at `[p - 16]`. Either test works on any word from anywhere: a parameter, a return
value, an element read out of an array, a value stored and reloaded a hundred times. The tag is inside
the value, not in a separate cell, so it survives `a[0] = "hi"`: the array element holds the tagged
region pointer, and reading it back gives a word that still says it's a region. (An address-range test
could tell regions from integers too, but a large enough integer would land in the range; a tag can't
be fooled that way, as below.)

**The compiler works out kinds statically wherever it can**, and then emits no test at all:

| Statically a number | Statically a region | Statically a map | Statically a singleton | Decided at runtime |
|---|---|---|---|---|
| integer, character and float literals | string literals | a `{}` literal | `true`, `false`, `null`, `none` | reading a parameter |
| `%` and the binary bitwise operators; `+ - *`, unary `-` and `~` on known numbers | any `.` result | | any comparison, `!`, `&&`, `\|\|` | a function call's result |
| `len`, `round`, `now`, `random` | `array`, `text`, `bytes`, `args`, `keys`, `sort`, `kind`, `split`, `char`, `pad`, `decode`, `encode` | | `has`, `ended`, `write`, `append`, `rename` | `in()`, `read()`, `parse`, `number`, `find`, `env` |
| | | | | `p[i]`, and `/` on two integers |

`copy` answers the kind it was given: a copy of a map is a map, and a copy of a region is a region. A
parameter, or a function's result, moves into one of the static columns when every call site passes
the same kind, or every `return` gives the same kind; a whole-program pass works that out before any
code is emitted.

Every operation that needs a particular kind checks it (arithmetic, indexing, conditions, `len`,
`out`, `.` and comparison), and it checks only operands in the last column. Operands whose kind is
known carry no check. Integer arithmetic compiles to plain integer instructions, with a small fixup
where the arithmetic disturbs the tag: `+` and `-` adjust by one, `*`, `/`, `%` and the shifts untag and
retag, and `&`, `|` and every comparison need nothing, because the tagged forms already give the right
answer and keep the order. On x86-64 a literal operand saves even the `+`/`-` adjustment: the
compiler doubles the constant and makes it the instruction's immediate, so `i + 1` is one `add` on the
tagged word, and `i < n` against a constant is one `cmp`, with no scratch register and no tag to strip
and put back. The arm64 backend doesn't fold literals into immediates yet; it loads the tagged constant
into a register first.

**No integer can pass for a region.** A number always has its low bit set, so it can never have a
region's `000`, whatever its size. An integer can't be read as a pointer, and that doesn't depend on
integers staying out of some address window. `'A'` is `65` to the program; the tag is a detail of the
machine word that `word` code never sees.

**What it costs.** Integers are 63-bit instead of 64, because of the tag bit. The numbers `word`
programs actually handle (byte counts, indices, hashes) are far inside that range. And `array(n)` has
to fill its cells when it's made, because the number `0` is the machine word `1`, not `0`, so a fresh
page from the OS doesn't read as zeros; a large `array` commits its pages instead of reserving them.
`docs/VALUE_MODEL.md` describes the representation the compiler emits, float tag included.

> The arena grows. It starts at 128 MiB, and `rt_grow` extends the mapping at the current top when it
> runs out, by the whole shortfall in one call (rounded up to 128 MiB), so a small program reserves
> little. The arena never spans more than 16 TiB, and an allocation it can't satisfy, including a count
> too large to be an address at all such as `array(1 << 61)`, is `out of memory` (§10.2), never a
> wrapped size. On Linux and Windows growth never replaces an existing mapping (Linux asks for
> `MAP_FIXED_NOREPLACE`). macOS has no such flag, so there the arena grows with `MAP_FIXED`, and the
> 16 TiB cap keeps it inside an address window nothing else on macOS uses. The kind test doesn't read
> the arena span, since the kind is part of the word and not of where it points, so growth and kinds
> don't affect each other. The arena's base is randomized on every run, on every target: the
> entropy comes from `getrandom` on Linux, `getentropy` on macOS and `rdrand` on Windows, each mixed
> with the stack pointer's own ASLR. Only the literal pool stays at `0x600000000000`, because literal
> addresses are built into the emitted code as absolute constants. Its pages are writable: what keeps
> a literal from changing is the runtime's address check (`write to a literal`, §10.2), not the page
> protection (`docs/SECURITY.md` §3).

### 3.7 Maps: `{}` is JSON

The second aggregate is the **map**: an insertion-ordered store from text keys to any word. It's
written with braces, which cost the grammar nothing, because blocks are indentation (§2.2) and `{` was
otherwise unused:

```javascript
person = {name: "Ada", age: 36, langs: array(2)}
person["langs"][0] = "word"
out(person["name"])                  // Ada
out(person)                          // {"name":"Ada","age":36,"langs":["word",0]}
```

A key can be written bare (`name:`) when it's a plain identifier, or quoted (`"content-type":`)
when it isn't. Both give the same key: a bare key is shorthand for the text. Values are ordinary
expressions, so a map can hold regions and other maps. A trailing comma is allowed, and a literal can
span lines, since a newline inside `{ }` doesn't end a statement.

A map has five operations:

| You write | You get |
|---|---|
| `o[k]` | the value stored under the text `k`, or `none` if there is no such key |
| `o[k] = v` | store `v` under `k`. A new key is appended, and an existing one is overwritten in place, keeping its position. The map keeps the key's region, not a copy of it, so a name used as a key is aliased the same way a stored value is (§3.4), and that region becomes read-only (below) |
| `len(o)` | how many pairs the map holds |
| `keys(o)` | a region of the keys, in insertion order |
| `has(o, k)` | `true` if the key is present, `false` if not: how you tell "absent" from "the value is `none`" |

There's no delete, since nothing a program can call reclaims memory (§3.5). The nearest thing is
setting a key to `none`: `o[k]` then answers `none` as it would for a missing key, though `has` still
answers `true` and `len` still counts it. There's no iteration form either: use `keys(o)` and an
ordinary `loop`.

**A key is read-only once it's a key.** The map keeps the key's region, not a copy, and the key's slot
in the hash index was chosen from its *contents*. Writing through another name for that region would
leave the map holding a key it can't find (`out(m)` would print `{"xbc":1}` while `m["xbc"]` answered
`none`), and two different keys could become the same text. So the region stops being writable the
moment it becomes a key:

```javascript
k = "" . "abc"
m = {}
m[k] = 1
k[0] = 'x'                           // app.w:4: write to a map key
```

It's the same kind of refusal a string literal gives (§3.5), located at the write. Only writing is
refused. Reading `k`, joining it and passing it anywhere work as before, and `k = k . "x"` still gives
`k` a new region and leaves the map's key alone (§3.4). `keys(o)` hands back those same regions, so its
elements are read-only too, and so is a key `parse` built. **`copy(k)` gives you a writable one**,
since a copy is a new region.

A key that is a string literal was never writable in the first place: writing to it stops with
`write to a literal`.

`out(o)` prints the map as JSON, and `.` writes it as JSON too, because that's the one text form a
map has. A few values have no JSON spelling, and printing a map that holds one stops the program with a
located fault (§10.2): `none`, an infinity or a `nan`, a text value holding something no character can
be (a negative number, a number past U+10FFFF, or a surrogate), and a cycle. `stringify` refuses the
same values (§3.8, §12.3). Two maps compare with `==` by content, in any order (§3.3), so
`parse(stringify(o)) == o` holds for a map of integers, text, arrays, maps, `true`, `false` and
`null`. A float comes back only as close as the fifteen or so digits it prints with (§2.6), so for a
map holding `0.1 + 0.2` or `1 / 3`, `parse(stringify(o)) == o` is false. Byte-backed text is written
as the characters its bytes spell and comes back as code points (§3.4), so a map holding a non-ASCII
byte-backed key or value doesn't come back equal either.

**JSON values.** JSON has `null`, `true` and `false`, and so does `word`: they're three of the four
singletons (§3.8), each its own word with its own `kind()`. They round-trip as themselves, so a program
can tell a field that was `null` from one that was `false` and from one that was missing, which a
mapping to `0`, `1` and `0` couldn't. A JSON number with a fraction or an exponent becomes a float
(§2.6). A whole number stays an integer unless it's outside the integer range (§3.1), and then it
becomes a float too. A JSON document is written by someone else and its numbers have no size limit, so
a number too big for a 63-bit integer is ordinary; an id from a language with 64-bit integers is the
everyday case. A float is what JSON's own number model gives, and it's what the same value written as
`9.223372036854776e18` gives. A number past the double's range makes `parse` answer `none` (§12.3).

**Arrays.** A JSON array is a region, and `array(n)` (§9) is how you build one. It allocates the same
way `text(n)` does, but marks the region so it prints as `[...]` instead of as text. That mark is the
only difference, and otherwise it's an ordinary region. Without the mark there'd be nothing to tell a
region of small numbers from a string, and `["hi"]` and `"hi"` would print the same. `parse` marks the
arrays it builds, so a parsed payload prints the way it arrived.

**Cost.** A map is a boxed cell on the extension tag (§3.6) holding a region of pairs in insertion
order plus an open-addressing index, so a lookup is a hash and a probe instead of a scan, and `keys`
gets the insertion order for free. A program that never writes `{}` and never calls `array`, `keys`,
`has`, `args`, `split`, `parse` or `stringify` carries none of this code (§12).

---

### 3.8 The four singletons: `null`, `false`, `true`, `none`

Four values that are neither numbers, regions nor maps. Each is a reserved word and a whole machine
word of its own (`null` is the word 6, `false` 14, `true` 22 and `none` 30), so it carries no pointer,
allocates nothing and compares in one instruction.

They're reserved words, not names bound to values, so `true = 1` is a parse error.

| | `kind()` | in a condition | why it exists |
|---|---|---|---|
| `true` | `"boolean"` | true | a JSON `true`, and the name for a yes |
| `false` | `"boolean"` | **false** | a JSON `false`, and the name for a no |
| `null` | `"null"` | **faults** | a JSON `null`: a field that is present and empty |
| `none` | `"none"` | **faults** | *no answer*: what a failed conversion or lookup returns |

**`null` and `none` aren't conditions.** `if x` on either stops the program with

```
a condition must be true or false; compare the value, as in 'x != 0' or 'x != none'
```

instead of picking a branch. That's a run-time fault even when the condition is a literal `null` or
`none`. Taking them as "no" would hide a failure: a `number()` that failed would look like a field that
wasn't set, and the program would carry on with the wrong answer. The fix is to say which question
you're asking: `x == none` for "did it fail", `x == null` for "was the field JSON null".

**They're different from everything, including each other.** `true == 1`, `false == 0`,
`null == none` and `null == 0` are all false. Equality on them is identity and never crosses a kind, so
a value that only looks the same can't pass the test.

**They have no order.** `null < 1`, `true > false` and every other ordering comparison on one is a
compile error where the compiler can see it, naming the operator used:

```
'<' has no meaning for true, false, null or none; compare them with '==' instead
```

Where it can't see it, the comparison is a run-time fault (§10.2):

```
'<' and '>' have no meaning for true, false, null or none
```

**They aren't numbers.** Arithmetic on one is a compile error where the compiler can see it, and
otherwise a located fault (`number expected, got true, false, null or none`). "Can see it" includes
the *answer* to a comparison, not only a literal: `1 + (a == b)` and `a < b < c` are compile errors for
the same reason `1 + true` and `true < 5` are.

**Where they come from.** They can be written as literals. `parse` answers `true`, `false` and `null`
for the JSON words of those names (§12.3). `none` is what a failed conversion or a lookup that found
nothing answers: `number("wat")`, `parse` on text that isn't JSON, a `find` with no match, a missing
map key, an unset `env`, and a `read` that failed (§9, §12).

**Printing.** `out` and `.` write each as its own name: `out(none)` prints `none`. `stringify` writes
`true`, `false` and `null` as the JSON words, so they round-trip, and it faults on `none`, because
`none` isn't a JSON value:

```
none is not a JSON value; it is what a failure answers
```

Writing it as JSON `null` would be worse than stopping. The language keeps `null` and `none` apart, and
a document mustn't claim a field was present and null when what really happened is that a conversion
failed.

**Why four.** With only `true` and `false`, a failed conversion would have no value of its own: a `0`
sentinel can't tell "the text was 0" from "the text wasn't a number". With only `null`, "the document
said null" and "there was no answer" would be the same thing. Four is the smallest set that keeps each
of those questions answerable, and they cost one tag that was spare anyway (§3.6).

---

## 4. Grammar (EBNF)

Notation: `{ x }` is zero or more, `[ x ]` is optional, `|` separates alternatives, and quoted text is
literal. Statements end at a newline and blocks are marked by indentation (§2.2). `INDENT` and
`DEDENT` are the tokens the lexer emits when the indentation goes in and when it comes back out. They
mark block boundaries the way `{` and `}` do in a braced language.

```ebnf
program      = { import-decl } { top-item } ;
import-decl  = "import" ident NEWLINE ;        (* app.w only, before any top-item (§11.1) *)
top-item     = function | hook | statement ;   (* bare statements only in app.w (§11) *)

function     = ident "(" [ params ] ")" block ;
hook         = hook-target { "," hook-target } block ;
hook-target  = ident ":" ( "before" | "after" ) ;

params       = ident { "," ident } ;

block        = INDENT { statement } DEDENT ;

statement    = assign-stmt
             | if-stmt
             | loop-stmt
             | return-stmt
             | "break"
             | call ;                          (* a bare expression is not a statement (§4.2) *)

assign-stmt  = lvalue "=" expr ;   (* a bare ident not yet bound is a declaration (§5) *)
lvalue       = ident { "[" expr "]" } | call "[" expr "]" { "[" expr "]" } ;

if-stmt      = "if" expr block [ "else" ( if-stmt | block ) ] ;
loop-stmt    = "loop" [ expr ] block            (* no expr -> infinite; expr -> while true *)
             | "loop" ident "in" expr block ;  (* for-each: bind ident to each element (§7.2) *)

return-stmt  = "return" [ expr ] ;

expr         = logic-or ;
logic-or     = logic-and  { "||" logic-and } ;
logic-and    = comparison { "&&" comparison } ;
comparison   = join { ( "==" | "!=" | "<" | "<=" | ">" | ">=" ) join } ;
join         = sum { "." sum } ;
sum          = prod { ( "+" | "-" | "|" | "^" ) prod } ;
prod         = unary { ( "*" | "/" | "%" | "<<" | ">>" | "&" ) unary } ;
unary        = ( "!" | "~" | "-" ) unary | postfix ;
postfix      = ( call | primary ) { "[" expr "]" } ;
call         = ident "(" [ args ] ")" ;
primary      = int-lit | float-lit | char-lit | string-lit | map-lit | singleton
             | ident | "(" expr ")" ;
float-lit    = digits "." digits [ exp ] | digits exp ;
exp          = ("e" | "E") [ "+" | "-" ] digits ;
singleton    = "true" | "false" | "null" | "none" ;
map-lit      = "{" [ map-pair { "," map-pair } [ "," ] ] "}" ;   (* §3.7 *)
map-pair     = ( ident | string-lit ) ":" expr ;
args         = expr { "," expr } ;
```

An assignment target is a name, an element of one (`a[i]`, `a[i][j]`), or an element of what a call
returns (`f(x)[0]`). A parenthesized expression or a string literal can be indexed when you read it
(`out((x)[0])`), but a statement has to start with a keyword or a name, so `(x)[0] = 3` and
`"abc"[0] = 3` are errors. So is `f(1) = 3`, which assigns to a call.

### 4.1 Precedence

From loosest to tightest: `||`, `&&`, the comparisons, `.` (join), then `+ - | ^`, then
`* / % << >> &`, then unary `! ~ -`, and last `[]` indexing, which binds tightest.

The bitwise operators bind tighter than the comparisons, at the same level as the arithmetic of
similar strength. That's Go's arrangement, and I chose it over C's. In C, `flags & MASK == 0` parses
as `flags & (MASK == 0)`, one of the best-known precedence bugs in the language. In word,
`flags & MASK == 0` means what it looks like it means.

`.` (join) binds looser than arithmetic, so `"n=" . a + b` joins the sum, and tighter than the
comparisons, so `a . b == c` compares the joined region. It associates left. A chain of three or
more parts allocates its result once, when nothing from its third part on is a call, and joins pair
by pair from such a call on (§14). Appending to a name is different again: `s = s . a . b` becomes
in-place appends where §3.4 can prove it safe.

### 4.2 Two disambiguation rules

**Calls versus definitions.** At the top level, a `name(args)` line is a call when nothing is indented
under it, and a function definition when a block is. In a definition every argument must be a plain
parameter name (§8.1). Inside a block, the same line with an indented block under it is an error
(`unexpected indent`), because functions are defined at the top level only. Inside an expression,
`name(args)` is always a call. This is what having no `fn` keyword costs, and §15 goes into it.

**A bare expression is not a statement.** Assignment isn't an expression, and the only expression
with a side effect is a call, so a line like `x + 1` can't do anything. It's an error instead of a
value that gets thrown away. Only a call can stand alone as a statement. A line holds one statement,
and anything after it on the same line is an error (`expected the end of the line (one statement per
line)`).

The grammar also has no `f(x)(y)`. A call's target is an identifier, never an expression, so there's
no way to call the result of something. There are no function values (§6).

---

## 5. Declaration and assignment

**`=` declares and stores.** There is one assignment operator.

- `x = expr` where `x` isn't bound yet **declares** `x`, bound to the value of `expr`.
- `x = expr` where `x` is already bound **stores** into it. `p[i] = expr` always stores.

The compiler already knows which of the two it is (that's what a scope table tells it), so I don't
make you say it again with a second operator. A separate declaration operator would let the compiler
catch `total = 0` on a name nothing had bound as a typo, and that typo is caught anyway, at the read.
After a mistyped `totl = 0`, `out(total)` is "undefined variable", and `total = total + 1` with
nothing bound reports the read on the right, which is the more useful place to point. Writing `:=`
gets a diagnostic telling you to write `=`, so it doesn't parse as something else.

**A new name is scoped to the whole function.** `total = 0` inside an `if` is still visible after the
`if`. The code generator works this way (every local gets one slot per function, §14), and
it makes the obvious reading of

```javascript
found = 0
loop line in lines
    if match(line)
        found = found + 1
```

the correct one. It also means there's no shadowing: a name is bound the first time it's assigned
anywhere in the function, and there's only ever one of it.

**A name that's assigned in only one place and never read is an error**, and that's where the rest of
the typo protection comes from. `totl = 5` next to a `total` that is read is "'totl' is assigned but
never read", reported at the write. The rule applies only when the value is **call-free**.
`junk = text(1000)` is there for the allocation, not the name, and a call is the only expression with
a side effect (§4.2), so throwing away a call's result is a choice and throwing away a literal or a
computation is a mistake. That's what lets this be an error without a `_name` convention to learn
alongside it. A name assigned in more than one place isn't checked, because each later assignment
counts as a use. Parameters and the `loop x in` variable are exempt, since a function that ignores an
argument and a loop that only wants the iteration are both normal. `word` applies the same rule to
functions (§15).

**Assignment is a statement.** It isn't an expression, so you can't write `if x = 5`. That's a syntax
error, because `=` can't appear where an expression is expected, which removes the classic `=`/`==`
mix-up and keeps the grammar smaller.

### 5.1 Scope

Scope is lexical and per function. A variable is visible from its first assignment to the end of the
function it's in, whichever block that assignment sits in.

- **Bind before use.** A local must be assigned textually above its first read. (Functions and hooks
  are exempt, see §10.) Reading a name nothing has bound is "undefined variable".
- **Assigned on every path before it's read.** Binding a name and giving it a value are separate
  questions. `x = expr` anywhere in a function makes `x` a local of that function, but a read of `x`
  is only accepted where every path that reaches it has assigned it. So

  ```javascript
  if c
      x = 1
  else
      x = 2
  out(x)          // fine: both paths assign
  ```

  and

  ```javascript
  if c
      x = 1
  out(x)          // error: the path where c was false assigns nothing
  ```

  A branch that always `return`s or `break`s adds nothing where the paths join, so assigning in the
  other arm is enough. A loop body may run zero times, so an assignment inside one never counts after
  the loop, and that includes a `loop x in` body. The fix is always to assign before the branch, or in
  every branch.

  This rule is there for safety. Without it a read would take whatever its stack slot held, and
  because a static kind (§3.6) lets the compiler skip the run-time tag test, that value would then be
  used as the kind the visible assignment implied: a leftover region would print as a raw integer,
  and a leftover integer would be dereferenced as a region. Keeping ordinary source away from unchecked memory is what
  this language is for, so this is rejected at compile time instead of patched over at run time.
- **One binding per name per function.** A name assigned anywhere in a function is that function's
  local, and every later assignment stores into the same one. There's nothing to shadow and nothing
  to redeclare. The one name that has to be fresh is a `loop x in` variable (§7.2).
- **The top level is the outermost block, and functions are closed.** Top-level variables (first
  assigned at file scope in `app.w`) are locals of that outermost block. Later top-level statements
  can see them, and no function can. A function sees only its parameters and its own locals, so
  nothing leaks in and there's no global state. A function's scope and the top-level scope don't
  nest, so a function may use a top-level name for its own local, and that isn't shadowing. Using a top-level variable's name inside a function that has no local by that name
  is an "undefined variable" error. Pass a value in when a function needs it.

---

## 6. Expressions

The grammar (§4) covers their structure and the value model (§3) covers what they mean. A few points
need saying outright:

- **`&&` and `||` short-circuit.** They're control flow: `a && b` evaluates `b` only if `a` is true,
  and `a || b` evaluates `b` only if `a` is false. The compiler turns them into branches. Both
  operands must be booleans (§3.2), and each operator answers `true` or `false`, never one of its
  operands, so `(a != 0) || (b != 0)` is `true` or `false` and never `a`.
- A **call** `f(args)` resolves `f` by name at compile time, to a function, a builtin or a module
  function. There are no function values: you can't pass a function as an argument or call the result
  of an expression.
- **Indexing** `p[i]` reads an element of a region (§3.4), and `p[i] = v` writes one.

---

## 7. Statements

### 7.1 `if` / `else`

```javascript
if cond
    ...
else if other
    ...
else
    ...
```

`cond` must be `true` or `false` (§3.2): `true` takes the branch and `false` doesn't. A number (`0`
and `1` included), text or any other region, a float, a map, or what `find()` answers is a compile
error where the compiler can see it and a run-time fault where it can't. `null` and `none` always
fault at run time, even written out as `if null`. `else` sits at the header's indentation and is
followed by a block or by another `if` (`else if`). A header with nothing indented under it is an
error. There's no brace-less one-line form, so there's no dangling-else bug.

### 7.2 `loop`

`loop` is the only loop, and it has three forms:

```javascript
loop                     // infinite; leave with break or return
    ...

loop cond                // run the body while cond is true (§3.2)
    ...

loop x in region         // for-each: bind x to each element of region, in order
    ...
```

There's no C-style counting form and no `;`. You write a counting loop out, which keeps the counter
visible and the language uniform:

```javascript
i = 0
loop i < n
    ...
    i = i + 1
```

**The for-each form, `loop x in y`**, walks a region's elements. `in` is a contextual word. The
stdin builtin is also called `in`, but it's always written with parentheses, so the two never
collide, and `x in y` isn't a legal expression anywhere else, so the form adds no ambiguity. It's the
counting loop above with the index hidden:

```javascript
loop v in xs             //  is  i = 0 / loop i < len(xs) / v = xs[i] / ... / i = i + 1
    use(v)
```

- `y` is evaluated **once**. A string gives its **code points** (§3.4), an array or `text` region its
  elements, and a byte-backed buffer (`fs.read`, `bytes`) each byte as an integer: the same value
  `y[i]` would give.
- `x` is a **fresh binding**, scoped to the loop body and bound to each element in turn. A number is
  copied. An element that is itself a region is the same region `y` holds (as with any assignment,
  §3.4), so `x[i] = v` writes into it. Assigning `x` itself never writes back into `y`. `x` may not
  reuse a name already bound in the function (§5.1), and it's out of scope after the loop.
- `break` and `return` work as in any loop.
- A **map** isn't walked directly: `loop k in keys(m)` walks its keys (in insertion order, §3.7), and
  `m[k]` reads each value. Handing the loop anything but a region is an error. A number or a map is
  caught at compile time when the compiler can see it, and anything else faults cleanly at run time
  (`region expected`). It never crashes.

**On x86-64, `loop i < len(a)` reads the length once.** Written the obvious way, a walk evaluates
`len(a)` on every pass, because in general the name `a` can be given a different region inside the
loop. The compiler checks whether that can happen. When nothing in the loop body assigns `a`
(no `a = ...`, and no `loop a in ...` rebinding it), the length is loaded once into a hidden local
before the loop, and the test compares against that. If the compiler hasn't proved that `a` holds a region, there's
one more condition: `a` could be a map, and storing a new key grows a map, whichever name it's stored
through. So for a name like that, the length stays in the loop when the loop stores into any element
or calls one of the program's own functions. The program gets the same answers either way; the
obvious spelling just stops being the slow one. When the body does assign `a`, the length is read on
every pass and the walk sees the new length, as it has to. In these two loops the compiler has proved
that `a` is a region:

```javascript
loop i < len(a)          // len(a) loaded once, before the loop
    a[i] = a[i] * 2      // storing INTO a does not change its length
    i = i + 1

loop i < len(a)          // len(a) reloaded each time: the name is reassigned
    a = a . more(i)
    i = i + 1
```

The hidden local always holds an integer, because that's all `len` answers, so the loop test
keeps the two-instruction integer form (§3.6) and doesn't pay for the run-time kind dispatch a name
of unknown kind would need.

**And `a[i]` inside that loop isn't bounds-checked twice.** The test has just answered `i < len(a)`.
The other half of the check is `i >= 0`, which holds when `i` is a **counting** local: one that,
anywhere in the function, is only ever set to a non-negative integer literal or stepped up by a
positive one. With both facts the subscript is provably in range, so the `cmp`/`jae` pair isn't
emitted. On my machine (x86-64 Linux on an Intel Core Ultra 9 275HX) that makes a walk-and-sum loop
about 6% faster when the array fits in the cache, and about 3% faster over a 20-million-element array
that doesn't.

The fact expires at the first statement that writes `i`, at any nesting depth, because after
`i = i + 1` the test's answer is about the value `i` had before:

```javascript
loop i < len(a)
    s = s + a[i]         // checked by the guard: no check emitted
    i = i + 1

loop i < len(a)
    i = i + 1
    s = s + a[i]         // i may now be len(a): checked, and it faults
```

A parameter is never counting, since nothing is known about what a caller passes, and a `<=` test
proves nothing about `a[i]`. The subscript must be the loop variable itself: `a[i + 1]` and `a[j]`
keep their check. Only the x86-64 backend does this. The arm64 backend doesn't hoist the length yet,
so it has nothing to elide against, and both targets fault the same way wherever a check is needed.

Rust gets this from its type system: `&mut` on a slice promises there's no other access, so LLVM can
hoist the length without proving anything. In word the proof is a walk over the loop body looking for
an assignment to `a`. Two names can hold the same region, but that can't change its length. A
region's length is set when it's made (an append gives a new region, even when §3.4 grows the old
buffer in place), so only assigning `a` can change what `len(a)` answers. A map is different, which
is why a name that isn't proved to be a region needs the extra condition above.

What isn't elided is the byte-backed subkind test: the `test [a-16], 1` and its branch that pick
between a packed byte and a whole word (§3.4). It's loop-invariant for the same reason the length is,
and in a loop where the subkind isn't known it costs a little more than the bounds check does (about
8% of the same walk-and-sum on my machine, and 5% over the big array). It can't be hoisted the way a
length can, because the branch is the load: taking it out of the loop means emitting the body twice,
once per subkind. That's the one transform here that would make the code bigger, so it's the one that
would need a size heuristic. I measured it and left it alone. Counted in the function bodies of
`word build -asm` output, the only benchmark in `dev/benchmarks/` that emits the test in its own code
is `jsonbench` (3 times, in its walk over a parsed JSON array), because the subkind pass proves the
others' regions. The two network benchmarks carry the net library, which emits it about 900 times,
and the compiler emits it about 3,900 times. That's where widening the subkind pass would pay.

The loop-and-a-half, where you do some work and then decide whether to stop, is a bare `loop` with an
`if ... break`. That's why the bare form exists alongside `loop cond`:

```javascript
loop
    if ended()
        break
    handle(in())
```

### 7.3 `break`

`break` is only legal inside a `loop`, and it leaves the nearest enclosing one. There's no labelled
break and no `continue`. Skipping an iteration reads more clearly as an `if` around the body, and it
avoids the duplicated increment that `continue` tends to need.

### 7.4 `return`

`return expr` leaves the current function with `expr` as its result. A bare `return` in a function
leaves with an unspecified value (don't read it), and is a **compile error inside a hook**, where
`return` always has to carry a pass/fail answer (§8.2). `return` is legal inside a function, a hook,
or at the top level (§8.1). **A function that reaches the end of its body without a `return` returns
`0`.**

---

## 8. Functions and contracts

### 8.1 Functions and the entry point

```javascript
add(a, b)
    return a + b
```

A function is a name, a parenthesized parameter list, and an indented body. There's **no `fn`
keyword**. At the top level, a `name(params)` line with a body indented under it can only be a
definition, and everything that runs is either a statement or a function anyway, so `fn` would add
nothing. A `name(args)` line with no indented block after it is a call, and one with an indented
block is a definition, where every argument must be a plain parameter name.

Functions are **top-level only**: no nested functions and no closures. A definition inside a block is
an error (`unexpected indent (a function is defined at the top level only)`). Parameters are plain
names, with no types to annotate and no default values. Calling a function with the wrong number of
arguments is a compile error (§10). A function sees only its parameters and its own locals, never a
top-level variable (§5.1), so it's self-contained. Recursion is ordinary, and running out of stack
ends the program (§10.2).

**Top-level code is the program.** Statements may appear at the top level of `app.w`, and running the
program means running those statements, top to bottom. No entry function is needed: `out(67)` on its
own is a complete program. If you like structure you can define an `app()` function and call it on
your first top-level line, but nothing requires it. Only `app.w` may hold top-level statements. The
other `.w` files in its folder hold function and hook definitions only (§11), and a statement in one
is a compile error.

**Exit status.** A top-level `return n` ends the program with status `n & 255`, and running off the
end of `app.w` ends it with status `0`. The operating system keeps eight bits, so `return 300` exits
with status `44`. `n` must be an integer. A value the compiler can see is something else (text or any
other region, a float literal, a map, `true`, `false`, `null` or `none`) is a compile error at the
`return`, and anything else is checked when it runs and faults if it isn't an integer. A float faults
even when it's whole, like `3.0`.

### 8.2 Contracts: `:before` and `:after`

A function can have a **before-hook**, an **after-hook**, or both: separate blocks that run at the
function's boundary, so it can be checked without cluttering its body. Contracts only observe. A hook
can read and it can stop the program, but it can't change the arguments or the return value:
assigning to a parameter or to `result` in a hook is a compile error. A region a hook is handed is
still the caller's data. Nothing stops a hook from writing into one, but it shouldn't. (Hooks that
rewrite would bring back the invisible action contracts exist to avoid, so they're left out; see §15.)

A hook is written as its own top-level declaration, linked to its function by name and a suffix that
is `:before` or `:after` (anything else, like `:befor`, is an error):

```javascript
divide(a, b)
    return a / b

divide:before
    if b == 0
        return false        // guard fails -> program dies (see below)
```

A hook takes **no parameter list**. It sees the function's own parameters by name: inside
`divide:before`, the names `a` and `b` are in scope and hold the arguments the call was made with.
Spelling them out again would only repeat them.

**Hooks are guard functions.** What a hook answers is a **condition** (§3.2), so its body can
`return`:

- `return false`: the **contract fails**. The program ends with a contract-violation error that
  gives the function's name, located at the `return` that said no. On a `:before`, the function never
  runs. This is the "if it doesn't meet requirements it needs to die" behaviour.
- `return true`, or reaching the end of the block: the contract **passes**.
- Anything else isn't an answer, the same as in any other condition. A number (`return 0` and
  `return 1` included), text or any other region, a
  float, a map, or what `find()` answers is a compile error at the `return` when the compiler can see
  it. A value it can't see (a parameter, or what one of the program's own functions returns) and
  `null` or `none` fault at the `return` when the hook runs, the same way `if null` does.

A hook's answer is only a pass/fail signal. It never replaces an argument or the function's result.
A bare `return` in a hook is a compile error.

**Ordering, and the race rule.** For a call `f(args)`:

1. The before-hook runs. If it fails, the program dies there: `f` doesn't run and neither does the
   after-hook. You don't reach the end of the race if you weren't allowed into the race.
2. `f` runs.
3. The after-hook runs on **every** exit path of `f`, including falling off the end. If `f` can
   `return` from three places, all three go through the after-hook first. If it fails, the program
   dies.
4. The caller gets `f`'s original return value.

**Hooks fire on every call, recursive ones included, except calls written in a hook's own body.**
Those go straight to their targets without running any hook, so a guard can call its own function
without recursing forever. Only the calls written in the hook itself are exempt. A function the hook
calls makes its own calls through the hooks as usual, so a guard that reaches its own function
through another one (the hook calls `g`, and `g` calls `f`) runs the hook again, and unless something
stops it, that recurses until the stack runs out (§10.2). The compiler emits hook bodies with direct
calls, so the exemption costs nothing at run time.

**The after-hook and `result`.** Inside an `:after` hook, the contextual name `result` is bound to the
value `f` returned. It's the only new name a hook introduces, and only after-hooks have it. (`result`
isn't reserved anywhere else, so you can use it as an ordinary variable name outside after-hooks. A
function that has an after-hook can't have a parameter named `result`, and that's a compile error
naming the function.)

```javascript
withdraw:after
    if result < 0
        return false        // post-condition violated -> die
```

### 8.3 Sharing a hook across functions

One hook body can guard several functions, listed with commas, each one carrying the suffix:

```javascript
withdraw:before, deposit:before, transfer:before
    if amount <= 0
        return false
```

Rules:

- **All the suffixes in one hook declaration must be the same kind**, all `:before` or all `:after`.
  Mixing them (`a:before, b:after`) is an error.
- **All the functions sharing a hook must have identical parameter lists**: the same names and the
  same count. That's what lets the shared body use the parameters at all (`amount` above has to mean
  the same thing in every function it guards). The compiler checks it, and on a mismatch the error
  shows the first function in the list and the first one that differs, each with its parameters
  (`'a(x, y)' and 'b(x, z)' differ`). A different arity is just one way for the parameters to differ.
- **A hook can only name a function the program defines**, in any of its files. A builtin or a module
  function can't be hooked: naming one gets the same error as naming a function that doesn't exist
  (`contract hook names undefined function 'out'`).

---

## 9. Builtins

Builtins are always there, and there's no import for them. The set is small, and it's the part of the
language most likely to grow. In the table, `n` is a number, `s`/`a`/`p` are regions, and `i` is
an index.

| Builtin | Effect |
|---------|--------|
| `out(x)` | Write `x` to standard output, then a newline: a number as decimal text, a region or a map as §9.1 describes. |
| `err(x)` | The same as `out`, but to **standard error** (fd 2) instead of standard output (§9.1). Use it for diagnostics that mustn't mix into the program's data on stdout. |
| `in()` | Read one line from stdin, with the newline (and a carriage return before it) stripped. The answer is a **number** if the line is an integer, and a **region** otherwise. At the end of input it answers an empty region, so test with `ended()`, not with `len`. |
| `ended()` | `true` if stdin is exhausted, else `false`. It isn't called `eof` because the other nineteen builtins have plain English names, and a Unix acronym would be the odd one out. |
| `len(p)` | The length of region `p`, or for a map, how many pairs it holds (§3.7). |
| `array(n)` | Allocate a new zero-filled region of `n` elements, marked as a **JSON array**, so `out`, `.` and `json.stringify` render it as `[…]` (§3.7). `n` must be `>= 0`. This is the one to use for an array of values that should print as an array. It brings in the small piece of runtime that renders one (about 4 KB), so use `text(n)` when you want the storage without the rendering. |
| `bytes(n)` | Allocate a new zero-filled region of `n` elements stored as packed **bytes**, one byte per element instead of one 64-bit word, so it costs `n` bytes of memory instead of `8n`. Otherwise it's an ordinary region: `len`, indexing, `copy`, `==`, `.` and `sort` all behave the same, and element `i` reads back as an integer `0..255`. Storing an integer outside `0..255` keeps only its low byte (`256` stores `0`, and `-1` stores `255`), and storing anything that isn't an integer (a float, even `2.0`, a region, a map, or one of the four singletons) faults. Use it for large byte buffers (sieves, bitmaps, binary data) where a whole word per element would be wasted, and `array(n)` when elements have to hold any value, regions included. It's the same representation `fs.read` returns (§12). |
| `bytes(hex)` | The same kind of region, built from a **hex string literal**: `bytes("637c777b")` is four bytes, and `bytes("")` is an empty one. The string must be an even number of hex digits. It's decoded **at compile time** into the literal pool, so a constant table costs its own bytes in the binary instead of one store instruction per element, and it's read-only like any other literal (`copy` it to get a writable one). |
| `copy(p)` | Allocate and return a **new region holding the same elements** as `p`, or, when `p` is a **map**, a new map holding the same pairs in the same insertion order. Regions and maps are both references, so `t = p` makes two names for one thing, and a write through either is visible through the other. `t = copy(p)` is how you get your own. The copy is **shallow**: the element (or key and value) words are copied, so a value that is itself a region or a map is shared with the original. Subkinds carry over, so a copy of a JSON array is a JSON array and a copy of a byte-backed buffer is byte-backed. |
| `copy(p, start)` | The elements of region `p` from `start` to the end: `copy(p, start, len(p))` without saying `p` twice. Requires `0 <= start <= len(p)`. |
| `copy(p, start, end)` | The same for **part** of a region `p`: the elements from `start` up to but **not including** `end`, the half-open range most languages use, so `copy(s, 2, 5)` is elements 2, 3 and 4, and `end - start` is the length. Requires `0 <= start <= end <= len(p)`, and `copy(p, i, i)` is the empty region. **Subkinds carry over to the result**: part of a JSON array (§3.7) is a JSON array, so it still renders as `[…]`, and part of a byte-backed region (§12.1, what `fs.read` returns) is byte-backed, so it costs an eighth of the memory and `out` writes it as the bytes it came from. |
| `args()` | Every command-line argument, as an **array** (§3.7) of regions of **code points** (UTF-8 decoded, §12). `args()[0]` is the program name, `args()[1]` the first argument, and `len(args())` is how many there are. Indexing it is bounds-checked like any other region, so ask `len` before reaching past the end: an argument that isn't there faults instead of reading as an empty string. Because the result is an array, calling it brings in the small piece of runtime that renders one (about 4 KB), the same as `txt.split` does. That's what lets `out(args())` print `["prog","x"]` instead of faulting on a region of regions. |
| `kind(x)` | The name of `x`'s kind, as text. There are **eight** answers: `"number"` (an integer or a float), `"text"`, `"bytes"`, `"array"`, `"map"`, `"boolean"` (`true` or `false`), `"null"`, and `"none"`. The last three cover the four singletons of §3.8: `true` and `false` share `"boolean"`, while `null` and `none` each get their own, because a program that receives one has to tell them apart. Comparing the answer with a name is the language's **only** kind test, which is why it's one builtin and not eight. It's the test a program needs to check `in()`, `args()` or a parsed document and take a branch instead of stopping on bad input (§3.6). It costs no more than a dedicated builtin would: `kind(x) == "number"` is recognized as a whole and compiled to the tag arithmetic it describes, so no name is built and none is compared. A literal that isn't one of the eight is a compile error, because that test could never be true. `"array"` is a region carrying the JSON-array mark: what `array(n)`, a parsed `[…]`, `keys` and `txt.split` return. It behaves like `"text"` in every other way (§3.4: an array and a string are the same thing), but a walk over a parsed document has to tell an array from a string, and this is the only place the two differ. `"bytes"` is a **byte-backed** region: what `bytes(n)` and `fs.read` return, and what a `copy` of one keeps. It has its own answer because it's the one case where the difference shows: `len` counts bytes and `y[i]` is a byte, where text would give code points. `txt.decode` turns one into text and `sort` promotes one to word-backed, so both answer `"text"` afterwards. The answer is a literal, so writing into it faults the way writing into any literal does. |
| `round(x)` | Round `x` to the nearest whole number, as an **integer**. Ties round away from zero: `round(2.5)` is `3` and `round(-2.5)` is `-3`. An integer comes back unchanged. This is the one way from a float back to where a whole number is required (an array index, a byte count, `%`), and the one place non-finite arithmetic stops: `inf`, `-inf`, `nan` and any value past the integer range **fault** here (§2.6, §10.2) instead of answering. |
| `now()` | Nanoseconds since the Unix epoch, as an **integer** (`CLOCK_REALTIME`). The integer range holds it until February 2116. It's wall-clock time and not monotonic, so it can step backward when the clock is adjusted. |
| `random()` | A random non-negative **integer** in `0 .. 2^62 - 1`, from the OS entropy source. Use `random() % n` for a value in `0 .. n-1`. If the operating system has no randomness to give (an old kernel without `getrandom`, or a sandbox that denies it), the program stops (§10.2) instead of answering a number that isn't random. |
| `env(name)` | The value of environment variable `name` as a region of **code points**, or **`none`** if it isn't set. That's a different answer from a variable set to the empty string: `env(x) == none` is "not set", and `len(env(x)) == 0` is "set and empty". `name` can be text or bytes, and names are ASCII by convention. On Windows a name matches whatever its ASCII case (`env("path")` finds `PATH`), the way Windows programs expect. Everywhere else the case has to match. A name holding `=` answers `none`, and so does an empty name. |
| `number(x)` | Parse region `x` as a number and return it, or **`none`** if the text isn't one. Digits alone (with an optional leading `-`) answer an **integer**, or a **float** when the value is outside the integer range (§2.6): too big to count with isn't the same as not a number, and `json.parse` reads those digits the same way. Text with a `.` or an `e`/`E` exponent answers a **float**, the nearest double to all of its digits, as a float literal is (§2.6). `json.parse` reads numbers the same way, so the same digits give the same double whichever of the two reads them. The exception is a value past the double's range: `number("1e400")` is `inf` (and `number("-1e400")` is `-inf`), as IEEE says, where `json.parse` answers `none`. A number `x` comes back unchanged. `number` reads back the text `.` and `out` write for a number, but that text is rounded for floats (§2.6), so the round trip is exact for every integer and only for the floats that survive the rounding: `number("" . (1 / 2))` is `0.5`, but `number("" . (1 / 3))` isn't `1 / 3`. It doesn't accept surrounding whitespace, a leading `+`, a trailing `.` (`"1."`), an exponent with no digits (`"1e"`) or with nothing before it (`"e5"`), or the words `inf` and `nan`. A leading `.` is fine: `number(".5")` is `0.5`. Compare the result with `none` to tell a `0` in the text from a parse failure. |
| `find(haystack, needle)` | The index of the first position where `needle` occurs as a contiguous run in `haystack`, or **`none`** if it doesn't occur. Both are regions, and elements match by value (§3.3), so it finds a substring in text or a run in a number array. An empty `needle` answers `0`. A miss is **`none`**, not `-1`, so you test `find(s, c) != none`. The answer is a number or `none`, and neither is a condition (§3.2), so `if find(s, c)` is a compile error: a hit at index `0`, or a miss, can't be read as a yes or a no by accident. |
| `sort(region)` | A **new** region with `region`'s elements in ascending order, leaving the input untouched. The order is the order `<` gives (§3.3): numbers signed, regions lexicographic. A region mixing numbers and regions faults, as comparing them would. It's a **merge sort, O(n log n)**; a region of integers long enough to pay for it is **radix sorted** instead, in at most eight linear passes. |
| `text(n)` | Allocate a new zero-filled **mutable text buffer** of `n` elements: `n` word-sized slots of one code point each (§3.4), with no rendering mark. It's the same as `array(n)` for indexing, `len`, comparison and everything else except how `out` and `.` render it (§9.1): as **text** instead of as `[…]`, which is what you want for a region you're filling with character codes, and not what you want for a region of values. It's the buffer you build a string in, and the one `kind(x) == "text"` names. It carries none of the JSON-rendering runtime, so a program that only ever indexes its storage stays about 4 KB smaller. |
| `keys(o)` | An **array** (§3.7) of map `o`'s keys, in insertion order. |
| `has(o, k)` | `true` if map `o` has key `k`, else `false`. `o[k]` answers `none` for a missing key, so `o[k] != none` already tells a missing key from a present one. `has` is what tells a missing key from one whose value **is** `none`. |

`copy` **allocates**. That's what it's for, and what the name says: the result is an independent
region, so `t[0] = 65` never writes through to `p`. It isn't a view over `p`, and it can't be one while
regions are mutable. `p[i]` reads element `i` at a fixed offset from the reference, with no
indirection (§3.4), which is what makes indexing one instruction, and a base/offset/length header
would put a branch and a second load on that path to make `copy` cheaper. The move itself is cheap:
on x86-64, 64 elements are sixteen 32-byte moves (§14). What keeps a copy in a loop cheap is §3.5's
dead-store rewind, which gives the arena back each window once the loop is done with it.

Taking an **end index** instead of a count costs nothing, even for a fixed-width window, where a count
would be the natural thing to pass. On x86-64 the compiler sees that the end in `copy(s, j, j + w)` is
the start plus something, and passes `w` straight through as the length, so the friendlier spelling
compiles to what a count would. An end that isn't written in terms of the start (`copy(s, j, k)`,
`copy(s, i, len(s))`) costs the one subtraction.

The name says what you get: `copy(p, start, end)` is part of a region, and `copy(p)`, the whole
region, is how you get your own copy of one, since a region is a reference (§3.4). `copy` takes a
**map** as well as a region, because a map is a reference in the same way, and "how do I get my own?"
has the same answer.

`sort` is a merge sort, so it's **O(n log n)**. A region whose elements are all integers, with at
least 24 of them for each byte their spread covers, is sorted by LSD radix instead: linear, at most
eight passes, no comparisons. 50,000 pseudo-random integers sort in about 1 ms that way and 800,000
in about 14 ms (the merge takes about 4 and 80, x86-64 Linux on an Intel Core Ultra 9 275HX). The
answer is the same either way, since two equal integers are the same word. The complexity is part of
the contract, so there's no performance cliff to find by accident. Like `copy`, `sort` carries the
JSON-array mark onto its result, so a sorted **JSON array** (§3.7) is still a JSON array and doesn't
turn back into text.

The current merge sort is stable, but stability isn't promised, so don't write a program that
depends on which of two equal values comes first. It can be seen: `1` and `1.0` are equal, and they
print differently.

`sort` and `find` want regions, and handed a map they end the program (§3.3: a map has no order).
`keys` and `has` are the other way round. They want a map, and a number or a region is rejected, at
compile time where the kind is known and otherwise with a `this needs a map` fault at run time.

To join regions, use the `.` operator (§3.3). There's no `concat` builtin and no join function.

### 9.1 Output

**Text or a list, decided by looking.** A region prints as text when every element is a character
you can see, and as a list of numbers when it holds other integers, because printing three invisible
NULs tells nobody anything and `[0, 0, 0]` does. The full rule is in the list below. So a partly
filled `text(8)` prints as a list until it's trimmed with `copy`, and `kind()` answers `"text"` the
whole time: the rendering doesn't change the kind. A **byte-backed** region (§3.4) is always
written as its bytes, since `fs.read` has to stay byte-exact.

A **diagnostic** that quotes source text goes through the same rule, so the compiler replaces the
characters below 32 (other than tab, newline and carriage return) with `?` before quoting them.
Otherwise a stray NUL in a string literal would turn the whole message, file and line included, into
a list of code points.

`out` is one of three polymorphic operations (with `.` and comparison), and it's safe for the same
reason they are: nothing downstream depends on what went in. You never wrap a number in a `str()`
call: `out(42)` prints `42`, and `out("hi")` prints `hi`.

- A **number** is written as decimal text, with a leading `-` when it's negative (a float as §2.6
  describes).
- A **region** is written **as text or as an array, decided by looking at its elements**, because a
  region of small numbers and a string are the same thing, and only the contents can tell them apart.
  It's written as text (each element encoded as **UTF-8**) when every element is a character you can
  see: a Unicode scalar value of `32` or above, or tab, newline or carriage return. Otherwise, if
  every element is an integer, it's written as `[a, b, c]`, so `out(text(3))` emits `[0, 0, 0]`
  instead of three invisible NUL bytes, and an element that's negative, above `0x10FFFF`, or a
  surrogate in `0xD800..0xDFFF` shows as the number it is. Elements are code points (§2.1), so
  `out("café")` emits five bytes for four elements.
  An element that isn't an integer at all (a float, a region, a map, `true`, `false`, `null` or
  `none`) can't be shown as a character or as a number, and ends the program (`not a character`,
  §10.2). A **byte-backed** region (§12.1, what `fs.read` returns) is always written as its raw bytes,
  so `out(read(f))` stays byte-exact for binary data.
- A **map** is written as **JSON** (§3.7): `out({a: 1})` emits `{"a":1}`. A map has no other text
  form. An array-marked region, a JSON array, prints as JSON for the same reason: `out(array(2))`
  emits `[0,0]`. The mark matters because it means always JSON. An array holding `104` and `105`
  prints `[104,105]` where an unmarked region holding them prints `hi`, and an array of strings prints
  as `["a","b"]`, with quotes and escaping.
- The same rendering rules apply to a number, map or array operand of `.` (§3.3), so a value joined
  into a region becomes the text `out` would have shown.

`out` **ends every call with a newline** (`\n`): `out("hi")` writes `hi` and a line break, and
`out(42)` writes `42` and a line break. To put several values on one line, build the line as one
region and print it once (`out("x = " . n)`). In a loop, collect into a region with `.` and print
once after the loop instead of on every pass. There's no way to leave the newline off, so there's no
prompt on the same line as the `in()` after it. That trade favours the common case, and §15 records
it.

`err(x)` is `out` in every way (the same rendering, the same trailing newline), except that it writes
to **standard error** (file descriptor 2) instead of standard output (fd 1). The split keeps a program
usable in a Unix pipeline: its real output goes down the pipe on stdout, while progress notes,
warnings and errors go to the terminal on stderr, where a `> file` or `| next` can't swallow them.

```javascript
err("warning: retrying")     // to the terminal / 2> log
out(result)                  // to the pipe / > out.txt
```

The `net` runtime already writes its diagnostics to fd 2 when a request fails (§12.2), and `err`
gives a program the same stream.

**When output is written.** `out` collects what it writes in a 64 KB buffer, and the buffer is
written when it fills, at exit, and before anything that can wait or hand the output to another
process: `err`, `in()` and `ended()`, the `fs` verbs, the network and `exec`. So into a pipe or a
file, output arrives in pieces of up to 64 KB, and a program that prints a few lines and exits writes
them all at the end. When standard output is a terminal (a console on Windows), each `out` is written
as it ends, so an interactive program looks the same as it would with no buffer. On macOS every
`out` is written as it ends, terminal or not. `err` is always written as it ends, after
whatever `out` had collected, so the two streams stay in order when they go to the same place.

A fault writes the lines that finished before its message, and an `out` that faulted part way writes
nothing. A program killed by a signal loses whatever was still in the buffer, up to 64 KB.

If the reader at the other end of a pipe has gone (`app | head -1`), the program ends with status 141
at its next write into that pipe. For standard output that's the next time the buffer is written,
which can be well after the reader left, and at exit at the latest. 141 is the status a shell reports
for SIGPIPE on Linux and macOS, and a Windows build exits with it too. Any other failed write of
standard output or standard error is a fault (§10.2). A full disk stops the program with
`could not write standard output`, at the line of the first `out` whose text wasn't written, which
can be earlier than the statement that was running when the write failed. A program started with no
standard output at all faults the same way at its first write. When it's `err` that can't be
written, there's nowhere to put a message, so the program ends with status 70 and says nothing.

### 9.2 Input

`in()` returns a **number** when the line is an integer (an optional `-` followed by digits, and
nothing else: no spaces, no underscores, no `+`), and a **region** otherwise. So `age = in()`
followed by `age + 1` or `if age > 17` just works, because numeric input is already a number, with no
`num()` call, while a line of other text comes back as a region you can join, index or compare. A
line whose value is outside the integer range (§2.6) comes back as a region, since `word` can't hold
it as an integer.

An `in()` value is one of the few whose kind is decided at run time (§3.6). That means `age + 1` on a
line the user typed as `twelve` ends the program, because arithmetic on a region is an error. That's
the language's standing answer to bad input (the same one §8.2's contracts give), where some
languages would coerce the value without a word.

**`ended()` exists because the alternative is ambiguous.** An empty line and the end of input both
give a zero-length region, so `len(line) == 0` can't tell them apart, and no sentinel works either,
since a line holding `0` is a legitimate number. One builtin settles it:

```javascript
loop
    if ended()
        break
    handle(in())
```

**Print the prompt before you ask.** `ended()` answers whether input is exhausted, and the only way to
know is to look, so on a terminal it **waits for the keystroke**, the same as `in()`. A prompt written
after it shows up too late for the reader to see it:

```javascript
if ended()                      // blocks here, on a bare cursor
    break
out("1 attack   2 defend")      // the options arrive after the answer
choice = in()
```

Put the output first and it reads the way it should:

```javascript
out("1 attack   2 defend")
if ended()
    break
choice = in()
```

---

## 10. Checks

`word` has no type system, but it keeps every check that's cheap and catches a real mistake. They
cost almost nothing, and they're most of what makes a language pleasant to use.

### 10.1 Compile time

A program the compiler rejects gets one diagnostic, in the form `<file>:<line>:<column>: <message>`,
which is the form editors and other tools already read. When an identifier is involved, the message
names it: `app.w:41:5: undefined variable 'badge_found'`, `app.w:12:1: call to undefined function
'nope'`. The build writes no executable and exits non-zero.

Diagnostics go to standard error, and so do usage messages and every other failure the toolchain
reports. Standard output carries only what a command produces: the assembly from `build -asm`,
`verify`'s success line and `version`'s report. It's the same split `err()` gives a program (§9.1),
for the same reason: `word build -asm app.w > app.s` must not get an error mixed into the assembly,
and `word build app.w 2> errors.log` must catch one.

A program that doesn't parse (a stray token, a value where a statement was expected) is reported the
same way, at the token that's wrong. The compiler never falls through to an internal fault that
names a line of its own source. The checks are:

- **Assigned before read** (§5.1). Reading a name nothing has assigned is `undefined variable`, and a
  read on a path that hasn't assigned the name is rejected too, so no program can see an
  uninitialised slot. Functions and hooks are found across the whole program whatever their order
  (§11), so a call may come before the definition.
- **A `loop x in` variable is a new name** (§7.2). Using a name that's already bound there is an
  error (`'x' is already defined in this scope`). There's no other shadowing or redeclaration rule:
  assigning a bound name again is a store (§5).
- **Functions are closed** (§5.1). A function that reads a top-level variable's name, with no local
  of its own by that name, gets an `undefined variable` error.
- **A `loop` that can't end** is rejected. That's `loop <cond>` where the condition isn't a literal
  and contains no call, the body never assigns a name the condition reads, and the body has no
  `break` at that loop's level and no `return` at all. Such a loop runs forever (the forgotten
  `i = i + 1`), and at run time it would just hang, with no output and no location to go on.

  The compiler can be sure because word has no references and no closures (§5.1, §8.1): a callee
  can't rebind a caller's local. It can write into a region or a map it was passed, though, and an
  index store can write into one through another name. So when the condition reads inside a region
  or a map (an index, or a name that may hold one), a body with an index store or a call to one of
  the program's own functions leaves the loop alone. `loop true`, or a bare `loop`, is the intended
  forever-loop and isn't checked, and neither is a condition containing a call, which may answer
  differently each time.
- **Call arity** matches the callee's parameter count, and a call's target has to be a function the
  program defines, a builtin or a module function. A module function needs no import (the compiler
  enables its module on first use, §12), so an unknown name really is unknown:
  `call to undefined function 'raed'`.
- **Kind errors wherever the kind is known**: a numeric operator applied to text, an ordering
  comparison between a number and a region, `len` or `[]` applied to a number. The kind comes from
  the expression's own shape (a literal, a `.` result, a builtin whose answer is fixed) and, for a
  local, from its assignments.

  A local's kind is known when every assignment to it in the function agrees, and unknown otherwise.
  An assignment counts when its value's kind comes from its own shape; a copy of another name
  (`y = x`) isn't followed, so it leaves the kind open. It's the weakest rule that can't be wrong:
  there are no joins at branches and no fixpoint around a loop. One walk of the body collects every
  assignment, and a name whose assignments disagree falls back to unknown. Definite assignment
  (§5.1) is what makes it sound: a read is only accepted where some path assigned the name, so every
  value a read can see came from an assignment that walk saw. Two names are left out because no
  assignment in the body decides them. A parameter holds what the
  caller passed (so in `f(a)`, a later `a = 3` doesn't make `a` a number at a read above that line),
  and so does `result` in an `:after` hook. A `loop x in` variable is an element of a region and is
  never tracked.

  So `len(3)` and `x = 3` / `len(x)` are both compile errors. These still aren't:

  ```
  f(a)                  // a parameter holds what the caller passed
      return len(a)

  if c                  // two paths that disagree leave the kind open
      x = 3
  else
      x = "ab"
  out(len(x))

  x = mk()              // a word function's result is not tracked (§15)
  out(len(x))

  x = 3                 // nor is a copy of another name
  y = x
  out(len(y))
  ```

  These are caught at run time instead. A kind the analyzer doesn't know can't skip the tag test
  (§3.6), so the value is checked when the program runs, and each of these faults with
  `region expected, got a number` at its line and exit status 70 (§10.2). The program never carries
  on with a kind the compiler assumed. `dev/toolchain/test_guarantees.sh` writes each mistake in all
  three places (in the open, behind a name whose kind is settled, and behind one whose kind is
  open), next to the shapes that must keep compiling.
- **`break` only inside a loop** (§7.3), `return` only in a function, a hook or the top level, and
  never a bare `return` in a hook (§7.4).
- **Contract integrity** (§8). A hook's suffix is `:before` or `:after`, and every suffix in one
  declaration is the same one. A hook names functions defined in its own directory, never a builtin
  or a module function, and a function has at most one before-hook and one after-hook across the
  whole program. Functions sharing a hook have identical parameter lists, and no function with an
  after-hook has a parameter named `result`. A hook doesn't assign a parameter or `result`.
- **No duplicate definitions**: two functions with the same name are an error, whether they're in one
  file or in two files of a folder (§11).
- **No unused functions**: a function the program never reaches is an error (`function 'name' is
  defined but never used`), reported at the definition. A function is reached when the top level or
  a hook body calls it, or a function that's reached does, so a call in its own body doesn't count.
  Two functions that only call each other get `... is defined but never used: the only calls to it
  are in functions that are never used either`. A function with a contract hook is exempt, since the
  hook shows it's wanted. This catches most accidental definitions (§15): inside a
  block, a line indented under a call is `unexpected indent`, and at the top level it turns the call
  into a function nobody calls. It doesn't catch one case. A program may define a function with a
  builtin's or a module function's name (§2.5, §12), so at the top level a line indented under
  `out(x)` defines an `out`, and every `out` in the program calls it.
- **No unread names**: a local that's assigned in one place only, from a call-free value, and never
  read is an error (`'name' is assigned but never read`), reported at the assignment. That's where a
  typo like `totl = 5` next to a read of `total` sits (§5). A second assignment to the name counts
  as a use, and a discarded call result, a parameter and a `loop x in` variable are exempt.
- **Top-level statements and imports only in `app.w`** (§11, §11.1). In a folder program the other
  files hold definitions only, and `import` goes at the top of `app.w`, before any other line.
- **Lexical** (§2): a tab in indentation (`indent with spaces, not tabs`), a dedent to a width no
  open block has (`inconsistent dedentation`), an indent with no header above it (`unexpected
  indent`), a `(`, `[` or `{` still open at the end of the file (`this '(' is never closed`, at the
  bracket), a literal out of range, and a malformed number or character literal.
- **Nesting has a ceiling**, in three numbers, because the three shapes cost the compiler's stack
  different amounts per level:

  | at most | of | when it is passed |
  |---|---|---|
  | 256 | levels of nested *expression* | `this expression nests too deeply` |
  | 512 | levels of nested *block*: an indented body, or an `else if` arm, which nests in the tree without indenting in the source | `this block nests too deeply` |
  | 1024 | operators in one *chain* at a single precedence, as in `a . b . c . ...`, which leans left, so the tree grows a level per operator while the parser's own depth stays flat | `this expression chains too many operators` |

  The compiler recurses over the shape of the source, so without a limit a source file decides how
  much of the compiler's stack gets used. 10,000 nested parentheses would use all of it, and so would
  10,000 joins on one line, and the compiler would stop with a run-time fault naming a line of its
  own source (§10.2) instead of a diagnostic about your program.

  None of the three is close to real code. The deepest nesting in this repository (compiler,
  examples and tests) is 8 brackets, 9 indents, a 31-arm `else if` chain and 24 operators on one
  line. The limits are sized for a 1 MB stack, where a level of expression costs about eleven of the
  compiler's frames, a level of block about two and a chained operator about one. On that stack the
  compiler survives about 730 levels of expression, 3,550 of block and 4,000 chained operators, so
  the limits are about a third, a seventh and a quarter of those. Every target gives the compiler an
  8 MB stack by default, which leaves about eight times that room.

### 10.2 Runtime

Every failure in the table below ends the program with a message on standard error, in the form
`<file>:<line>: <what>`, and exit status 70. It's the form a compile diagnostic uses (§10.1), so one
editor rule jumps to either. There's no exception mechanism and nothing to catch: a `word` program
that has gone wrong stops and says where. 70 is `EX_SOFTWARE` from `sysexits.h`, which keeps a fault
apart from the usual 0, 1 and 2. A program can still end with 70 itself (`return 70` at the top
level, §8.1), so the message on standard error is what tells a fault apart. A contract violation
names the function it guarded: `app.w:38: contract violation in withdraw`.

The file is the one the faulting statement is in. A folder program (§11) is compiled as one text,
`app.w` first, and each statement records its line in that text. At a fault the runtime works out
which file the line falls in and prints that file's name with its own line: `helper.w:3`, where the
combined text's line would have been `app.w:6` after a three-line `app.w`. A program of one file
carries none of that lookup, and neither kind records anything extra.

Where a fault has the values you'd want, it prints them: an index out of range says
`app.w:12: index 5 out of bounds for a region of length 3`. None of this costs anything until
something has gone wrong.

**After a call returns, the line is the calling statement's again.** Each function records its own
line as it runs, so without this a statement that calls a function and then faults would report a
line inside the function that already returned: `return a + big() + a`, overflowing on the second
`+`, would blame the `return` inside `big`. So the line is put back after a call, in the statements
where something after the call can still fault. A fault inside the callee reports the callee's
line, with one exception: a one-line `return <expr>` function that the compiler substitutes into
its caller (§14), whether that's a function or top-level code, has no line of its own there, so its
fault reports the calling line.

The bundled `net` library (§12.2) is the other exception. It's compiled in after the program's last
line and isn't a file the program has, so a line of it would point past the end of the caller's
file, where no editor can follow. Its statements record no line, and a fault inside it (an array
`url` whose elements aren't characters, or the arena running out mid-fetch) reports the line of the
program's statement that called the verb.

Whether a statement stores its line, and whether it puts it back after a call, is decided per
statement by one walk of its expressions that asks two things: can anything here fault, and can
anything fault after a call. A statement that can't fault (a literal or a plain local read into a
local) stores no line at all, since it can't produce a located message. Two operations that can't
fault matter most, because they're what a loop tests: a comparison of two values the compiler proved
are numbers, and of two it proved are floats. Each is one compare instruction (`cmp` or
`ucomisd` on x86-64), with no fault path and no boxing. So `if n < 2` stores nothing, and
`if dist(a, b) > 1000.0` doesn't put the line back after the call.

| Failure | Cause |
|---|---|
| divide by zero | an integer `/` or `%` with a zero divisor. A `/` with a float on either side gives an infinity or a NaN instead (§3.1) |
| integer overflow | `+` `-` `*` or unary `-` whose result leaves `-2^62 .. 2^62 - 1`, or `MIN / -1` and the same `%` |
| shift out of range | shift count not in `0 .. 63` |
| operator needs whole numbers | a float where a whole number is needed: `%`, a bitwise operator or a shift on a float, a float size for `array`, `bytes` or `text`, a float stored into a byte-backed region (§3.4), or a float handed to a `sys` verb that takes a number (§12.5) |
| array index must be a whole number | `p[i]` or `p[i] = v` with a float `i`, or a `copy` with a float start or end |
| index out of bounds | `p[i]` with `i < 0` or `i >= len(p)`; a `copy` range outside the region; `array(n)`/`bytes(n)` with `n < 0`; `reset(m)` with `m` below 0 or above what's in use now, and `exec` with a count past the end of its list (§12.5). One message covers all of them, so there's no separate `bad range` or `bad length`. An index into a region adds the index and the length |
| write to a literal | `s[i] = v` where `s` is a string literal's region, or `recv` into a literal (§12.5) |
| write to a map key | `s[i] = v` where `s` is a region some map is keyed by (§3.7), including one `keys` handed back |
| number expected | a numeric operator applied to a region, a map or a singleton (§3.3), or a `copy` whose start or end is one of those. The message says which: `got a region`, `got a map`, or `got true, false, null or none` |
| no order | `<` `<=` `>` `>=` on a pair that isn't two numbers or two regions (§3.3). A pair gets one message, whichever side holds the offending value and on every target: a singleton on either side is `'<' and '>' have no meaning for true, false, null or none` (§3.8); otherwise a map is `this needs a number or a region, not a map`; otherwise it's a number against a region, `cannot order-compare a number and text`. A float is a number like any other here, so `none < 1.5` is the singleton fault. The same three messages come from inside two regions, since the element pair that decides a lexicographic comparison is ordered by the same rules (§3.3), and so from `sort` over such a region |
| region expected | `len`, `[]`, `copy`, or any other builtin or module function that needs a region, handed a number, a map or a singleton; a map key that isn't a region (§3.7). The message names what it got the way `kind()` names it (§9): `got a number`, `got a map`, `got a boolean`, `got null` or `got none`. A number or a map is told from the tag (§3.6) the check already read, so a ranged `copy` of a map reports `got a map`; the four singletons share one tag, so each is told from the word itself (§3.8), and `len(none)` says `got none` |
| bytes expected | a `sys` socket verb handed a word-backed region where it needs bytes: `bytes expected, got text` or `bytes expected, got an array` (§12.5) |
| this needs a map | `keys` or `has` handed something that isn't a map, where the compiler couldn't tell (§9) |
| not a character | `out`, `err` or `.` writing a text region (one with no array mark) that holds a float, a region, a map, `true`, `false`, `null` or `none` (§9.1). A text region whose elements are all whole numbers but not all characters (one past the Unicode range, say) renders as a list of numbers instead, and an array-marked region renders as JSON; neither faults. `write` or `append` data, or a path (§12.1), holding an element that isn't a code point: a float, a region, a map, a singleton, a whole number outside `0 .. 0x10FFFF`, or a surrogate. `encode` of a surrogate (§12.4). A map key holding an element that isn't a whole number (§3.7). Text written as JSON, by `stringify` or by `out` or `.` of a map or an array, holding an element that isn't a character: a negative number, a surrogate or one past `0x10FFFF` as well as the kinds above (§3.7, §12.3) |
| text: expected a whole number | `char`, `pad` or `encode` given something that isn't a whole number: `char(1.5)`, a float width or fill for `pad`, or an `encode` element that's a float, a region, a map or a singleton (§12.4) |
| encode: not a code point (0 to 0x10FFFF) | `encode` of a whole number below 0 or above `0x10FFFF` (§12.4) |
| round() has no whole number for inf, nan or a value past the integer range | `round` of an infinity, a NaN, or a float past the 63-bit range (§9) |
| split needs a separator with at least one character | `split` with an empty separator (§12.4) |
| none is not a JSON value | `stringify` of `none`, or of a map or array holding it (§12.3) |
| inf and nan are not JSON values | `stringify` of an infinity or a NaN, or of a map or array holding one (§12.3) |
| json: value nests too deeply (a cycle?) | `stringify` of maps and arrays nested more than 1000 deep, or of one that contains itself (§12.3) |
| a condition must be true or false | a condition (§3.2) that isn't `true` or `false`, where the compiler couldn't tell: an `if` or `loop` test, an operand of `!`, `&&` or `\|\|`, or a hook's answer. A hook answering something else gets this fault, not a contract violation (§8.2) |
| contract violation | a `:before` or `:after` hook returned `false` (§8.2), naming the function, at the `return` that answered |
| out of memory | the arena can't grow, including for a request too large to exist, such as `array(n)`, `text(n)`, `bytes(n)` or `pad` with `n` near the top of the integer range, which is refused before its size is computed instead of wrapping into a small one |
| could not map region space | at start-up, before the first statement runs, the operating system refused the memory for the program's literals or its arena. A fault before the first statement is reported at line 1 |
| could not write standard output | a write of `out`'s buffer failed for a reason other than a reader that has gone (§9.1): a full disk, say, or no standard output at all. It's reported at the line of the first `out` whose text wasn't written |
| could not write standard error | the same for `err`. The message goes to standard error too, so it usually can't be written either, and the exit status 70 is what's left |
| no randomness | `random()`, or a `net` handshake (whose keys and nonces come from it), when the operating system's random source doesn't deliver: `random: the operating system gave no random bytes` |
| stack exhausted | recursion deeper than the stack allows, or a function whose locals don't fit in what's left of it, in the program's own code. The stack is 8 MB on Windows, and the process's stack limit on Linux and macOS (8 MB by default, and at most 1 GB), less 128 KB kept back so the message can be printed, or a quarter of the limit when that's under 512 KB (§14) |
| comparison nests too deeply (a cycle?) | any comparison walking a structure it can't finish (§3.3): `==` and `!=`, and `<` `<=` `>` `>=` (and so `sort`) over two regions whose elements nest, either deeper than the stack allows or in a cycle, which has no end at all. It's the same limit as the row above, named for what reaches it here |

---

## 11. Compilation model

`word build app.w` compiles the entry file `app.w` together with every other `.w` file in its
directory into one native binary. `app.w` holds the top-level code, and each of the other `.w` files
adds its function and hook definitions. Building any other file on its own (`word build helper.w`)
stays single-file, so a directory of unrelated `.w` files, like a test folder or a scratch
directory, pulls in nothing it didn't name. What follows from that:

- **Definition order never matters.** Compilation has two passes: the first collects every function
  and hook name, and the second checks bodies, so any function may call any other wherever it is.
  Locals are different: a local has to be assigned before it's read (§5.1), which is why their order
  matters and functions' doesn't.
- **Module functions need no import.** `read`, `get`, `parse`, `split` and the rest resolve on first
  use (§12). `import fs` is legal, as a note to a reader, and there's nothing else `import` can name
  (§11.1).
- **One program per folder.** Only `app.w` may hold top-level statements, so a second program in the
  same directory is an error. Keep one self-contained `app.w` per folder.

There's no import statement for `.w` files, and the unit of compilation is a flat directory:

- **The entry file is `app.w`, and its directory is the program.** Every `.w` file in the directory
  is part of the program, and they're all compiled together. `app.w` holds the top-level program and
  any definitions, and every other `.w` file holds function and hook definitions only. A top-level
  statement in one is an error (`only app.w may hold top-level statements`), and so is an `import`.
- **The directory is flat.** Subdirectories aren't scanned, not even one named like a source file
  (`x.w/`), so a `scratch/` or `experiments/` folder in your project can't end up in the build. There
  is no way to reach code in another folder: `import` names only the built-in modules (§11.1).
- **Definition order doesn't matter across files either.** The two passes cover the whole directory.
- **A file can't be included twice.** It's either in the directory or it isn't, so there's no diamond
  problem and no include guard to write.
- **Two definitions of the same name are an error.** If two files both define `parse`, that's a real
  collision, since there are no namespaces. The compiler reports both places and tells you to rename
  one (`b.w:2:1: 'parse' is already defined at a.w:1:1, and there are no namespaces, so rename one of
  them`). It never picks one.
- **A diagnostic or a fault gives the file it's in**, with that file's own line. The files are
  compiled as one text, but a compile error in `helper.w` says `helper.w:3:9` (with the folder in
  front if you gave `word build` one, as in `src/helper.w:3:9`), and a run-time fault there says
  `helper.w:3: ...` (§10.2).

### 11.1 `import`

`import` goes only in `app.w`, before any other line, and takes one bare name:

```javascript
import fs
```

The name is a built-in module (§12): a set of functions the compiler provides, because they need
system calls and no `.w` file can make one (`txt` is the exception, and §12 says why it's a module
anyway). The list is closed and short: `fs`, `net`, `json`, `txt`, and the internal `sys` (§12.5),
which is documented so you know what it is, not for use. A name that isn't on that list is a
compile error at the `import` line. An unknown import is never ignored.

Importing a module is optional, since the compiler resolves these names on first use (§12).
`import fs` changes nothing about what the program can do. It tells a reader that the program
touches the disk, but it doesn't stop a program without it from touching the disk, so it's
documentation and not a permission. It stays in the language for two reasons: a note at the head of
a program is worth having, and removing the syntax would break every program that already has one,
which the 1.x freeze doesn't allow (`README.md`, "Status").

A name that isn't a built-in module is a compile error, and the message says what to do instead: a
program that outgrows one file becomes one folder (§11), where every `.w` file beside `app.w` is
already part of the program.

Importing another directory isn't part of the language, and §15 records it as a possible future
direction. The 1.x freeze rules out removals and changes in behaviour, not additions, so a directory
import could still arrive in 1.x.

- **`import` appears only in `app.w`.** No other file can bring anything in, so the dependency
  graph stays flat.
- **There's no capability manifest at the top of a program.** A required `import` line would make
  the head of `app.w` look like a list of what the program can reach, but nothing would enforce it
  beyond having to write it. A program's capabilities are what it calls, and `word build -asm` shows
  which runtimes it carries.

Most programs are one file, `app.w`, and grow into one flat folder when they need to. There's
nothing in between: no package manager, no dependency file, no version resolver and no registry. I'd
rather ship none of that in 1.0 than a sketch of it.

---

## 12. Standard modules

A module is a small set of functions the compiler provides. Modules are for things that need the
operating system. They aren't a plugin system, and the list doesn't grow casually.

A module needs no `import`. The compiler knows which module each of these names is in, so calling
`read` is what brings in `fs`. Three things follow:

- **A function the program defines itself wins.** If you write your own `split`, every call reaches
  yours; the module's is only used for a name the program doesn't define.
- **A module is compiled in only when a call reaches it.** The `import` line never decided that, so
  a program that never calls `net` carries no socket code.
- **`import` stays legal** (§11.1), as a note about what the program touches. That's all it does.

A module costs nothing until it's called. The compiler emits a module's runtime, and the buffers it
needs, only for a program that calls into it. A program that never touches `net` has no socket code,
no DNS resolver and no HTTP request text, and one that never touches a file has no `open`, `read` or
`write` path. The same goes for `in()` and `ended()`, the only readers of standard input, and for the
map and JSON runtime, which a program with no `{}` literal and no call to `array`, `split`, `keys`,
`has`, `args`, `parse` or `stringify` never carries.

The modules are `fs` (§12.1), `net` (§12.2), `json` (§12.3), `txt` (§12.4) and the internal `sys`
(§12.5). `txt` is the odd one out: it needs nothing from the operating system, and its five
functions could have been builtins. Putting them in a module is about where they're documented.
This is where you look up `split`, and the list of builtins in §9 stays at 20 names, under the
ceiling of 25 I've set, because that's the list you have to know to read any program at all. A
module function is one you look up when you need it.

### 12.1 `fs`


| Function | Effect |
|---|---|
| `read(path)` | Read the whole file at `path` (a region) and return its contents as a region, one element per byte. Returns `none` if the file can't be read. |
| `write(path, data)` | Write `data` to `path`, replacing any existing contents. Text, like any word-backed region, is written as UTF-8, and a byte-backed region as the bytes it holds. An element that isn't a code point faults with `not a character` before the file is touched (§10.2). Returns `true` on success and `false` on failure, including a write that fails part way: a full disk, a closed pipe or a file size limit. |
| `append(path, data)` | As `write`, but adds to the end of the file. |
| `rename(old, new)` | Rename the file at `old` to `new`, replacing any file already there. Returns `true` on success and `false` on failure. Within one filesystem the replacement is atomic, so to update a file you `write` a temporary one and `rename` it over the target, and a reader sees either the whole old file or the whole new one. Nothing is flushed to disk first, so that holds for readers, not across a power loss. On Windows `rename` answers `false` when the target is read-only, or is open in a program that didn't allow it to be deleted (word's own `read` allows it), so a program updating a file there should check the answer and try again. Replacing an empty directory with a directory works on Linux and not on Windows. A directory never replaces a file, and a file never replaces a directory: `rename` answers `false` for either, everywhere, and on Windows a link to a directory (a junction or a directory symlink) counts as a directory. |
| `dir(path)` | List the directory at `path`: a byte-backed region holding its entry names (including `.` and `..`) joined by newlines, in the order the filesystem returns them. The whole listing comes back, however long it is. Returns `none` if `path` isn't a directory or can't be opened. The folder model of §11 is built on it: the compiler reads a program's directory with `dir`. |

**A path reaches the operating system as written, or not at all.** Text goes as UTF-8, the bytes
`out` would write for it, so `read(args()[1])` opens `café.txt` by the name the shell gave it. A
byte-backed region (what `read` and `dir` return) goes as the bytes it holds. A path that can't be
handed over as written, because it holds U+0000 or is longer than 4095 bytes once encoded, fails
the call the way a path the OS refuses does (`none` or `false`). An element that isn't a code point,
a surrogate included, faults with `not a character` (§10.2). Nothing is cut short, and no element is
cut down to one byte.

`dir` lists names as bytes. To join a name with text, decode the whole listing before you split it:
`names = split(decode(dir(p)), "\n")`. A piece split from the raw listing has already been promoted
one code point per byte (§12.4), so decoding it afterwards does nothing, and a non-ASCII name would
then be asked for by a spelling it doesn't have.

That's five functions, with no handles, no modes, no cursor and nothing to close. A program reads a
file the way it reads a line: all at once, into the arena, and then it's a region like any other.

**`dir` on each platform.** `dir` gives the same answers on Linux and Windows: the same entries,
`.` and `..` among them (at the root of a Windows drive too), and `none` for anything that isn't a
directory, an empty path included. Windows lists a directory by searching it (`FindFirstFileW`),
since a directory there isn't a file you can open and read. A drive with no path, `dir("C:")`, lists
that drive's current directory, the way Windows reads `C:x` as a file in it. On macOS `dir` answers
`none` in 1.0.0, because that target's OS layer can't list a directory yet. The folder model of §11
is built on `dir`, so a `word` running on a Mac can't assemble a folder program. A build running
anywhere else, for any target including macOS, isn't affected.

**Failure is `none`**, so `if data == none` is the test, the same one as for `number()` and
`json.parse` (§3.8, §12.3). `none` is a value of its own that equals nothing else, so it can't be
mistaken for an empty file, an empty directory or a `0` in the data.

`none` isn't a condition: `if !read(p)` stops the program instead of picking a branch (§3.8). "The
file couldn't be read" and "the file was empty" are different facts, and a truth test can't tell
them apart, so write the comparison.

**`read` returns bytes.** A file is bytes, so `read` gives one element per byte and `len` is the
byte count; it doesn't guess an encoding. The region is byte-backed (§3.4): `out` writes it back as
the bytes it read, `write` writes the same bytes back, and a `copy` of it is byte-backed too, so part
of a text file prints the same way the whole file does. `d[i]` is the byte, as an integer from 0
to 255.

Joining file text with other text isn't automatic. Joining a byte region with text promotes it one
code point per byte (two byte regions joined stay bytes, §3.4), so `"line " . read(q)` turns each
byte of a multi-byte character into a character of its own. That's the seam between bytes and code
points described in §15. To prefix, wrap or interleave file text, decode it first (`decode`,
§12.4). The language can't do that for you, because it would have to know which regions are text.
`in()`, `args()`, `env()` and `net.get` are the places where it does know, and all four decode. So
does JSON, which is text by definition: `parse` decodes a byte-backed document, and `stringify` a
byte-backed string (§12.3).

### 12.2 `net`


| Function | Effect |
|---|---|
| `get(url [, insecure])` | Fetch `url` and return the response body as a region of Unicode code points, or `none` on failure. |
| `post(url, body [, insecure])` | Send region `body` as an HTTP POST and return the response body, or `none`. |
| `put(url, body [, insecure])` | HTTP PUT with region `body`; return the response body, or `none`. |
| `delete(url [, insecure])` | HTTP DELETE; return the response body, or `none`. |
| `head(url [, insecure])` | HTTP HEAD, which asks for headers only, so the body it returns is empty, or `none` on failure. An empty body and no answer at all are different answers here, which is why the failure isn't `""`. |

Every `https://` call verifies the server's certificate chain against the operating system's trust
store (the X.509 profile below says what that means). A trailing `insecure` argument of `true`, as in
`get(url, true)`, still completes the TLS handshake, so the connection is encrypted, but it skips the
certificate check: the peer isn't authenticated, and anyone in the middle can read and change the
request. It's there for endpoints whose certificate this verifier can't check. The verifier handles
RSA (PKCS#1 v1.5 and PSS, any common modulus size) and ECDSA (P-256, P-384 and P-521) certificate
signatures over SHA-256, SHA-384 or SHA-512, which is what the public web serves, so in practice the
flag is for a self-signed or otherwise untrusted certificate. It doesn't cover everything: a
certificate signed with Ed25519 is decoded and then refused, because there's no Ed25519
verification, and a caller can't tell that refusal from any other failure. A valid signature isn't
the whole test either: the chain also has to fit the X.509 profile below, which is narrower than
"cryptographically valid".

`insecure` is an ordinary condition (§3.2). `true` skips verification and `false` keeps it, and so
does leaving it out, so verification can't be turned off by accident. Anything else, `0` included,
is refused at the call (below). It's a truth test and not `insecure == 0` because under `== 0`,
`get(url, false)` would skip verification, since `false == 0` is false. `insecure` has no effect on
plain `http://`, but it's checked there all the same.

`url` is `[scheme://]host[:port][/path][?query][#fragment]`. The scheme is optional and defaults to
`https`, so `get("api.example.com")` means `https://api.example.com`. `host` is a name or a
dotted-quad IPv4 address. A name is resolved by word's own DNS query to the resolver the host names
(below), except `localhost` and every name under it, which are `127.0.0.1` without a query. Any
other name ending in a dot, like `https://example.com./`, isn't looked up, and the fetch answers
`none`. `port` defaults to 443 for `https` and 80 for `http`, and `path` defaults to `/`. The host
and port end at the first `/`, `?` or `#`, so `http://example.com?q=1` asks `example.com` for
`/?q=1`. The fragment is the caller's and is never sent. A chunked response is dechunked, so the
region you get back is always the decoded body. Failure (a bad URL, a DNS failure, a refused
connection, a failed handshake or certificate check) is `none`, so `if body == none` is the test, as
it is for `fs.read` (§12.1), `number()` and `json.parse`.

**A URL puts on the wire only what it names.** A URL holding a control character, a space or DEL
anywhere is a bad URL and fails before anything is sent. It's refused, never cleaned up: a CR or LF
would otherwise end the request line early and let the URL write headers, or a whole second request,
of its own. So is a host that isn't a name or a dotted quad (a `user@` userinfo, an `[IPv6]`
literal, a character outside ASCII), and a port that isn't a number from 1 to 65535, however many
digits it has. A path or query character past ASCII is sent as its UTF-8 bytes, each written `%XX`
(RFC 3986 §2.1), so every byte of the request line is printable ASCII. A URL is read as code points,
so a byte-backed URL (from `read` or `encode`) has each byte past ASCII taken as a code point of its
own and encoded a second time: decode one first (`decode`, §12.4). `Host` carries the port whenever
it isn't the scheme's own (`Host: 127.0.0.1:8080`). A `post` or `put` body that's text is sent as
its UTF-8 bytes, what `encode()` gives it, and a byte-backed body as the bytes it holds. A text body
holding something that isn't a character faults the way `encode` does (§12.4).

**A response is framed the way RFC 9112 frames it.** Any number of interim `1xx` responses may come
before the answer (`100 Continue`, `103 Early Hints`); each is a head with no body, and the answer is
the response after them. A `101 Switching Protocols` answers a request this client never makes, so
it's a failure. A reply to `head`, and any `204` or `304`, ends where its head does, whatever
`Content-Length` it names, since that length describes a body such a response never sends. A
`Content-Length` that isn't a length (not all digits, too many digits to be a size, or two values
that disagree) makes the response unusable, and the fetch answers `none` instead of guessing where
the body ends. A `Transfer-Encoding` is chunked only when `chunked` is its last coding; otherwise the
body runs to the close. A response whose head declares a body larger than the response ceiling below
is refused as soon as the head arrives. The search for the end of the head picks up where the last
read left it, so a head that never ends costs what its size does, up to that ceiling.

**A wrong kind is a fault at the call, not a failed request.** `url` and `body` must be regions and
`insecure` must be `true` or `false`. A verb checks all three, in the order they're written, before
it resolves, connects or sends anything, and a value of another kind stops the program on the
caller's line with the message any builtin gives (§10.2). So `post(url, 5)` is `region expected, got
a number`, and `get(url, 0)` is the condition fault, before any handshake. `none` says the request
didn't work, and a fault says the call was written wrong.

**The body comes back as text.** The returned region holds Unicode code points: the body's UTF-8 is
decoded on the way out, so `out(get(url))` prints correctly for any UTF-8 response and `len` counts
characters, the way string literals and `out` treat text everywhere else (§3.4). This is the one
intended difference from `fs.read`, which returns raw bytes (a file may be binary, and the compiler
reads its own source byte by byte); `net` is for text APIs, so it decodes. Only well-formed UTF-8
decodes (§12.4). A response that isn't valid UTF-8 has its stray bytes passed through unchanged,
including an overlong form or an encoded surrogate, which are bytes and not the characters they'd
spell. The body is read into a buffer that doubles as bytes arrive, so a body of many megabytes comes
back whole, and a chunked body is decoded in place and then copied out once, like a body with a
`Content-Length`.

**A fetch is bounded in five ways that fail differently.** A client dialling out to a peer it doesn't
control has to be able to give up, and these are where it does. All five are fixed, and all five
answer `none`, as a DNS or TLS failure does:

| Bound | Value | What it stops |
|---|---|---|
| connect deadline | 10 s | a peer that never answers the handshake: an address nothing routes, or a host that drops the SYN |
| idle deadline | 30 s | one read or write blocking forever: a peer that accepts the connection and then says nothing |
| total deadline | 120 s | a peer that never trips the idle deadline and never finishes either, sending one byte at a time, in the response or in the TLS handshake before it |
| flight ceiling | 64 KiB | a server's TLS handshake flight that never ends: a `Certificate` declaring up to 2^24 - 1 bytes, or record after record with no `Finished` |
| response ceiling | 64 MiB | a response the peer keeps sending: the arena doesn't shrink, so "read until it stops" would be a memory limit set by the other end |

The connect deadline is `connect()`'s own, because nothing above it has a socket to set one
on until it returns. It sets `SO_SNDTIMEO` for the handshake on Linux and `TCP_MAXRT` on Windows, and
takes it off again once connected. Without it a blocking connect would run to the operating system's
TCP timeout: about two minutes on Linux with the default `tcp_syn_retries`, and 21 s on Windows. It
holds for the TCP retry of a DNS query too, and that answer then has five seconds in all to arrive.

The total deadline covers the whole fetch, counted from the call: resolving, connecting, the TLS
handshake and the response all spend it, so a fetch is over two minutes after it started, whatever
the peer does. It's checked before every read and write the fetch makes, including each read inside
a single TLS record (a record delivered a byte at a time is still a trickle), and a read that could
outlast it gets its own deadline brought in to end with it. A fetch it ends answers `none` with
`net: the fetch did not finish inside the deadline` on stderr, even if part of a close-delimited body
had arrived: that body didn't end, it was cut off. A body that needs longer than that in one fetch is
out of reach of `net`.

A response that declared where its body ends, by `Content-Length` or by chunking, and then stopped
short is a failure (`net: the response ended before its declared length`). Handing back half a
document the caller can't tell from a whole one would be worse. A response framed by the connection
closing is exempt, since for that framing the close is the end. `head`, `204` and `304` are complete
at the end of their head, because they carry no body, whatever `Content-Length` they name.

The flight ceiling does for the TLS handshake what the response ceiling does for the body. After the
`ServerHello`, the server's flight (`EncryptedExtensions`, `Certificate`, `CertificateVerify`,
`Finished`) arrives encrypted, and the client has to buffer it until a whole `Finished` is in before
it can verify it. A handshake message may declare up to 2^24 - 1 bytes, and a server may send record
after record without a `Finished`, so without a ceiling a peer could grow that buffer until the arena
couldn't grow any more. Past 64 KiB the handshake fails, with `net: the server's handshake flight is
larger than this client will read` on stderr, and the fetch answers `none`. Real flights are a few
kilobytes: measured once with `openssl s_client -trace` across the thousand domains in
`dev/toolchain/top_domains.txt` (September 2026), the largest was about 14 KB and the median about
4 KB. So the ceiling leaves plenty of room for a large enterprise chain and still refuses a flood.

The request side is bounded too, by explicit checks: the host is at most 255 bytes, the path 2048,
and the whole request (request line, headers and body) 8 KiB. A URL or a `post`/`put` body that
would go past these is an ordinary failure: the verb answers `none`, as it does for a DNS, TCP or TLS
failure, with `net: URL too long` on stderr, so a caller can test for `none` and retry with a smaller
request. That's the general rule for `net`: every transient or input-shape failure answers `none`,
and the program keeps running. Nothing the network does ends the program, and nothing in the text of
a URL does either. Two things do, and neither is a failure of the request (§10.2): an argument of the
wrong kind (above), which is a mistake in the program, and an operating system with no randomness to
give, since every key share and nonce comes from `random()` and a handshake whose secrets are zeros
is one an eavesdropper can decrypt. A failed request also closes its connection before returning, so
the descriptor isn't leaked and the peer sees a clean end instead of a half-finished handshake. That's
what makes "try one URL, fall back to another" work after a refused certificate.

`net` speaks HTTP/1.1 over TCP for `http://`, and TLS 1.3 for `https://`. It's written in word (the
`net` library, carried as text in `compiler/word.w`) and compiled into any program that calls one of
the verbs above, with no import to write, the same way `char()` needs no `import txt`. Being word
source is what lets it run on more than one instruction set: it works on Linux (x86-64 and arm64)
and on Windows. On macOS a program that calls it builds, but in 1.0.0 every verb answers `none`
there, because the macOS OS layer doesn't map the socket calls yet. Only a program that calls a verb
pays for it, and one that doesn't carries none of it: on Linux x86-64 a program that fetches is about
425 KB, about 21 times one that doesn't, and takes about 90 ms to compile instead of about 5.

DNS is an A-record query over UDP to the resolver the host names. On Linux and macOS that's the first
`nameserver` line in `/etc/resolv.conf` that holds an IPv4 address, read the way glibc reads it: the
keyword starts the line, a space or a tab follows it, and the address is the next word, so anything
after it on the line, a comment included, is ignored. On Windows it's the first IPv4 server the OS
lists through `GetNetworkParams` (`sys.nameservers()`, §12.5). `1.1.1.1` is used only when the host
names no IPv4 resolver. The answer has three seconds to arrive, and the query is asked again over TCP
when the answer is truncated or doesn't come. `localhost` and every name under it, in any case and
fully qualified or not, are `127.0.0.1` and are never sent to a resolver, as RFC 6761 §6.3 asks. The
hosts file (`/etc/hosts`, or Windows' own), search domains and the OS's resolver cache aren't
consulted, so a name the host maps locally resolves differently in a word program than in other
programs on the same machine.

The rest is word's own too: the socket, the TLS handshake and record layer, the key exchange (X25519,
with P-256 and P-384 for a server that asks for one in a HelloRetryRequest), the record encryption
(ChaCha20-Poly1305 or AES-128-GCM, negotiated per connection) and RSA and ECDSA certificate-chain
verification. There's no libc, no OpenSSL and no outside library, as everywhere else in word. HTTPS
is a TLS layer wrapped around the same DNS, TCP and HTTP code, instead of a linked crypto library
(§15).

**The TLS 1.3 surface.** `net` is a TLS 1.3 client (RFC 8446). It isn't a server or a general TLS
library, and it has no TLS 1.2 fallback. What it puts on the wire is fixed and small, and it's listed
here so you can tell whether it will reach an endpoint by reading instead of trying:

| ClientHello field | What is offered |
|---|---|
| Cipher suites | `TLS_CHACHA20_POLY1305_SHA256` `0x1303`, then `TLS_AES_128_GCM_SHA256` `0x1301`, the RFC 8446 mandatory-to-implement suite |
| `supported_versions` | `0x0304` alone |
| `supported_groups` | `x25519` `0x001d`, `secp256r1` `0x0017`, `secp384r1` `0x0018` |
| `signature_algorithms` | `ecdsa_secp256r1_sha256` `0x0403`, `ecdsa_secp384r1_sha384` `0x0503`, `ecdsa_secp521r1_sha512` `0x0603`, `rsa_pss_rsae_sha256` `0x0804`, `rsa_pss_rsae_sha384` `0x0805`, `rsa_pss_rsae_sha512` `0x0806`, `rsa_pkcs1_sha256` `0x0401`, `rsa_pkcs1_sha384` `0x0501`, `rsa_pkcs1_sha512` `0x0601` |
| Extensions | `server_name` `0x0000`, `supported_groups` `0x000a`, `signature_algorithms` `0x000d`, `supported_versions` `0x002b`, `key_share` `0x0033` |

`key_share` carries one entry: `x25519` on a first flight, and on a retry the group the
HelloRetryRequest named, with the server's `cookie` `0x002c` echoed back unchanged beside it. The
rest of the second ClientHello is the first one unchanged, the same `random` and the same
`legacy_session_id`, because RFC 8446 §4.1.2 allows a retry to differ only in the key share, the
cookie, `early_data`, `pre_shared_key` and padding. A server is entitled to check, and the ones in
front of `bing.com`, `office.com`, `live.com` and `msn.com` do.

Before it answers a HelloRetryRequest, the client checks it the way RFC 8446 §4.1.4 asks: a
`legacy_version` of `0x0303`, no compression, `supported_versions` naming `0x0304`, a cipher suite
this client offered, the session id it sent, and a group it offered other than the one it already
sent a share for. It answers one retry at most. A retry that fails any of those checks ends the
handshake with `net: HOST sent a HelloRetryRequest this client cannot answer` on stderr. The
`ServerHello` that follows a retry has to name the retry's cipher suite. Every `ServerHello`, after a
retry or not, has to echo the client's session id (§4.1.3) and has to be one whole message in its
record, and one that isn't is refused with a message on stderr.

The handshake messages the client understands are `ServerHello` (2), including its HelloRetryRequest
form, `EncryptedExtensions` (8), `CertificateRequest` (13), `Certificate` (11), `CertificateVerify`
(15) and `Finished` (20). Certificate signatures are checked for RSA PKCS#1 v1.5, RSA-PSS and ECDSA on
P-256, P-384 and P-521, each over SHA-256, SHA-384 or SHA-512. A `CertificateVerify` has to be RSA-PSS
or ECDSA, since RFC 8446 §4.4.3 doesn't allow PKCS#1 v1.5 there, and an ECDSA one has to name the
curve of the leaf's key.

**A `CertificateRequest` is answered.** A server may ask the client to authenticate too, with a
`CertificateRequest` between its `EncryptedExtensions` and its `Certificate`. This client has no
certificate to present, and it tells the server the way RFC 8446 §4.4.2 prescribes: a
`Certificate` message with an empty `certificate_list` that echoes the request's
`certificate_request_context`, no `CertificateVerify`, and then its `Finished`, over a transcript
that holds the request and that empty `Certificate`. What happens next is the server's decision (§4.4.2.4). One that makes client
authentication optional completes the handshake and answers the request. One that requires it
refuses with `certificate_required`, and the fetch answers `none` at once, with
`net: HOST refused the handshake, alert 116` on stderr. The empty `Certificate` and the `Finished` go
in one record, and the request follows without waiting for a reply (TLS 1.3 gives a client no signal
that its `Finished` was accepted), so a refusal is the first thing read back after it.

The server's flight is judged when its `Finished` arrives, and there it's either accepted or refused;
the client doesn't read on as though more were coming. A flight this client can't accept (messages
out of the order above, a leaf certificate its decoder refuses, a `Finished` that doesn't verify)
fails the fetch with `net: HOST sent a handshake this client could not accept` on stderr. A
certificate other than the leaf that the decoder refuses is left out of the chain, and the chain is
judged without it.

The negotiation is closed at both ends. A `ServerHello` whose `supported_versions` isn't exactly
`0x0304` is refused, and so is one naming a cipher suite this client didn't offer. So there's no
downgrade: a server that speaks only TLS 1.2 gets no handshake at all, instead of a weaker one.

**The X.509 profile.** What `net` implements is a profile of RFC 5280 for one job, authenticating a
TLS server. It isn't general PKIX, and the difference matters in both directions, so the profile is
written out here. A chain is accepted only if every rule below holds. Anything else fails the fetch
with `net: certificate not trusted for HOST` on stderr, and the fetch answers `none`.

| # | Rule | Applies to |
|---|---|---|
| 1 | A `subjectAltName` covers the host. `dNSName` for a name (one leading `*.` label, never a bare `*.tld`), `iPAddress` for a literal address. The common name is never consulted (RFC 6125). | the leaf |
| 2 | The current time is within `notBefore`..`notAfter`. | every certificate, and the anchor |
| 3 | Each certificate is signed by its issuer, over its `tbsCertificate` exactly as it arrived, with an algorithm this implements (RSA PKCS#1 v1.5, RSA-PSS or ECDSA, each over SHA-256/384/512), and the two `AlgorithmIdentifier`s (inside the signed bytes and outside them) agree. A link made with anything else, SHA-1 included, doesn't hold. The issuer is looked for among the certificates the peer sent, in any order and past any extraneous ones (RFC 8446 §4.4.2); only the leaf's position is fixed. | every link |
| 4 | Every issuer carries `basicConstraints` with `cA TRUE`, and a `pathLenConstraint` leaving room for what is beneath it. | every certificate above the leaf, and the anchor |
| 5 | A certificate that carries `keyUsage` must allow what the path uses it for: `keyCertSign` on an issuer, and `digitalSignature` on the leaf, whose key signs the handshake (RFC 8446 §4.4.2.2). A `keyUsage` with no bits in it is malformed, and the certificate is refused. | the leaf and every certificate above it |
| 6 | A certificate carrying `extendedKeyUsage` must name `id-kp-serverAuth` (`1.3.6.1.5.5.7.3.1`). An absent EKU is unrestricted. | every certificate on the path that the peer sent |
| 7 | A certificate carrying a critical extension outside the four this profile processes (`basicConstraints`, `keyUsage`, `subjectAltName`, `extendedKeyUsage`) is refused (RFC 5280 §4.2). So is one carrying `nameConstraints`, `policyConstraints` or `inhibitAnyPolicy`, critical or not, since this profile implements none of them. | every certificate on the path that the peer sent |
| 8 | The path ends at the first certificate that chains to the OS trust store, verified under the stored key: either an anchor issued it, or it is an anchor the server sent back. An anchor's own signature isn't a link and is never checked, so the algorithm it was self-signed with doesn't matter (RFC 5280 §6.1.1). | the anchor |

Rule 8 says first because the peer decides how many certificates to send, and may send more than the
path needs. A CA that has moved to a newer root keeps serving a copy of that root cross-signed by the
older one, so clients whose store predates the move can still build a path; a client whose store
already has the newer root should stop there. `example.com`, `google.com` and `cloudflare.com` all
send that shape (September 2026). A verifier that asks the store about the last certificate it was
handed is asking about one that isn't on the path, and it refuses connections every other client
accepts. The certificates past the anchor aren't validated and get no say: rules 2 to 7 apply to the
path, not to whatever else arrived with it.

Rule 3 says the issuer is looked for because RFC 8446 §4.4.2 fixes only the position of the
end-entity certificate, and asks that the rest be tolerated in any order, extraneous certificates
included, "for maximum compatibility". A CA moving to a new intermediate serves both for a while, and
plenty of servers are simply misconfigured. Six of the thousand most popular domains send a chain no
strict walk accepts: `telekom.net` and `ultradns.com` send their leaf twice, and `warnerbros.com`,
`digikala.com`, `uidai.gov.in` and `terra.com.br` send a root ahead of the intermediate that needs it
(September 2026). So the path is searched for. Each step tries the certificates that carry the
current issuer's name, follows the one whose signature verifies, and backs out if that branch reaches
no anchor. The search spends at most 32 signature checks on the certificates the peer sent, far more
than the four links the deepest real chain needs, so a peer that sends a maze of certificates signed
by each other can't buy a factorial number of verifications with one connection. Each certificate
the search reaches is also checked against the store anchors that carry its issuer's name or its own
name, and those checks aren't counted: the bound is the 32, plus up to two checks per such anchor at
each of at most 33 steps. What a path has to satisfy doesn't change: every certificate on it is
checked where it stands, so an extraneous certificate can be ignored but can never bridge a gap.

Rules 3 and 8 split the certificates into the ones whose signature is checked and the ones whose
signature doesn't matter, and rule 8 decides which side an anchor is on. A trust anchor is a name
and a key the relying party already trusts: RFC 5280 §6.1.1 makes it an input to path validation,
not a link in it, and the certificate that carries it is only an envelope. So a root self-signed with
SHA-1 (as most of the web's oldest roots are) anchors a path just as well as one self-signed with
SHA-256, while a leaf or an issuer signed with SHA-1 is refused under rule 3. `openssl` and Go draw
the line in the same place. Rejecting a certificate because of its own signature algorithm would
delete an anchor from the store instead of refusing a chain, and a store that has lost an anchor
without saying so fails only the sites whose chains needed it. On the Windows machine this was
measured on, that was 19 of 53 anchors, `GlobalSign Root CA`, three DigiCert roots,
`AAA Certificate Services`, `Entrust.net`, `Go Daddy Class 2`, `thawte Primary Root CA` and
`VeriSign G5` among them.
So a signature algorithm nothing here verifies still parses, as a scheme of its own, and it's the
link check that refuses it, not the decoder. A key type the decoder doesn't know is different: a
certificate whose own key isn't RSA, P-256, P-384, P-521 or Ed25519 (an Ed448 or a brainpool key,
say) doesn't parse at all. As the leaf it fails the handshake, anywhere else in the chain it's left
out, and in the trust store the anchor is lost. `dev/toolchain/test_x509_profile.sh` holds both
halves (its S and D cases), and its last case counts the host's own trust store: every anchor the
platform offers has to parse, because an anchor lost at the parse is a fetch that fails for a reason
no message mentions.

Rules 6 and 7 are the ones a from-scratch verifier most easily leaves out, and leaving them out is an
authentication bug, not a cryptographic one: the chain is signed correctly at every link by a trusted
CA and still isn't a chain that authorizes this peer to be this server. Rule 7 is also what makes
every unimplemented part of RFC 5280 fail closed. Name constraints, policy constraints and
inhibit-any-policy restrict what a CA may issue, and nothing here enforces them, so a certificate
carrying one is refused, critical or not, instead of being trusted past a restriction nobody checked.

This profile gives a different answer from `openssl` or Go in six places, and each one is intended.
In five of them word refuses a chain that one or both of the others accept, and in the sixth it
accepts one that `openssl` refuses:

- **`anyExtendedKeyUsage` (`2.5.29.37.0`) doesn't satisfy rule 6.** It's forbidden in a publicly
  trusted server certificate, `openssl verify -purpose sslserver` refuses it at every depth, and
  reading it as "yes to everything" would turn the one extension that narrows a certificate's use
  into one that widens it. Go's `crypto/x509` accepts it; `word` doesn't.
- **A certificate with `nameConstraints` is refused even when the chain satisfies them**, whether or
  not the extension is marked critical, because this profile doesn't implement name constraints
  (rule 7). `openssl` and Go implement them and accept the satisfied case. The same goes for a
  non-critical `policyConstraints`, which `openssl` accepts because it checks policies only when
  asked to.
- **A certificate in the trust store is an anchor whether or not it's self-signed.** RFC 5280 leaves
  the choice of trust anchors to the relying party, and `word` takes whatever is in the store as
  trusted, as Go does. `openssl` also wants the anchor to be self-signed, unless it's given
  `-partial_chain`.
- **A leaf whose `keyUsage` leaves out `digitalSignature` is refused**, even when it allows
  `keyEncipherment`. `openssl verify -purpose sslserver` accepts that leaf, because the purpose also
  covers TLS 1.2's RSA key exchange, which only enciphered; Go doesn't read a leaf's `keyUsage` at
  all. A TLS 1.3 server proves who it is by signing, and `word` speaks nothing else.
- **A `keyUsage` with no bits in it is refused.** `openssl` refuses it too; Go reads it as an absent
  extension and so as unrestricted, which on an issuer skips the `keyCertSign` half of rule 5.
- **A link signed with SHA-1 is refused.** There's no SHA-1 in this implementation, so the signature
  can't be checked, and an unchecked link isn't a link. Go refuses it too (`crypto/x509` dropped
  SHA-1 verification in 1.18); `openssl` still verifies it at its default security level, which is
  what `-auth_level` and `@SECLEVEL` exist to change. An anchor self-signed with SHA-1 isn't this
  case, and all three accept it.

`dev/toolchain/test_x509_profile.sh` puts every rule above, and every divergence, to `word`, to
`openssl` and to Go's `crypto/x509` on the same bytes, and fails if any of the three gives a
different verdict from the one recorded for it. What isn't in the profile is listed in
`docs/SECURITY.md` §5: no revocation (neither CRL nor OCSP), no certificate policies, no signature
algorithm older than SHA-256 on a link, and no Ed25519 verification.

The other half: none of the following is implemented, and an endpoint that requires one of them
doesn't connect.

| Not implemented | What happens instead |
|---|---|
| `TLS_AES_256_GCM_SHA384` `0x1302` | never offered; a `ServerHello` naming it is refused |
| TLS 1.2 and earlier | never offered, and refused if selected (see above) |
| `pre_shared_key` `0x0029`, `psk_key_exchange_modes` `0x002d` | never offered; every connection is a full handshake |
| `early_data` `0x002a` (0-RTT) | never offered |
| `NewSessionTicket` | read off the wire and discarded, since there's nothing to resume into |
| post-handshake `KeyUpdate` | not honoured; the response ends where the keys change |
| Client certificates, and `post_handshake_auth` `0x0031` | none is ever sent, and authentication after the handshake is never offered. A `CertificateRequest` in the handshake is answered with an empty `Certificate` (above): a server that asks without insisting completes the handshake, and one that requires a certificate refuses it with alert 116 (`certificate_required`) |
| `application_layer_protocol_negotiation` `0x0010`, `status_request` `0x0005` (OCSP stapling), `signed_certificate_timestamp` `0x0012`, `max_fragment_length` `0x0001`, `record_size_limit` `0x001c`, `heartbeat` `0x000f` | never offered, and ignored if a server sends one |
| Post-quantum and hybrid key exchange (`X25519MLKEM768` and kin) | not offered; `docs/SECURITY.md` §5 calls this the largest known gap |
| Ed25519 and Ed448 certificate signatures | Ed25519's OID decodes to a scheme of its own and nothing verifies it; Ed448's decodes as an algorithm this can't verify, like SHA-1's. Either way the certificate parses and the link is refused, which fails closed and is also a real gap: a chain a browser accepts won't verify here. A certificate whose own key is Ed448 doesn't parse at all (above) |
| A TLS *server* | there is no `listen`/`accept` path through TLS; `net` dials out |

The 1.x freeze (`README.md`, "Status") covers both tables: what the first one offers can't change in
1.x, and anything that later moves off the second one is an addition, which the freeze allows.
`dev/toolchain/test_tls_surface.sh` decodes the ClientHello the implementation encodes and fails if
it and these tables disagree in either direction.

**What a fetch keeps.** `net` is word, so everything a fetch allocates lives in the arena, which has
no `free` (§3.5). A fetch keeps what it allocated, the response included, even when the program
drops the answer, except that on x86-64 the rewind of §3.5 can give the decoded body back. I
measured it with `sys.mark` around one fetch on Linux x86-64. A plain `http://` fetch keeps about 7.6 KB besides
its response, mostly one read buffer per exchange and a buffer the response is appended into, and
about 10 KB more when it has to resolve a name. The body costs more than its size, since it's kept
as the bytes that arrived and again as code points at 8 bytes each, so a 10,000-byte body brings a
fetch to about 126 KB. That's small enough for a lot of fetches: `dev/toolchain/test_net_verbs.sh`
runs 4,000 of them, with no `sys` anywhere, inside a 200 MB cap.

An `https://` fetch keeps more, for the handshake: about 43 KB against a local server with one
self-signed certificate, and about 113 KB for `https://example.com/` (104 to 107 KB natively on
Windows). Checking the chain adds nothing to that. A verified fetch still reads and parses the whole
trust store every time, but it gives that memory back before it returns, so it keeps what an
`insecure` fetch keeps, and `test_net_verbs.sh` runs 300 verified fetches inside the same 200 MB
cap. What every fetch keeps still adds up. A loop that fetches without end grows by that much on
every pass, since nothing frees it, so to stay inside its memory it has to bracket each fetch with
`sys.mark` and `sys.reset` (§12.5), and nothing allocated between the two may be used after the
reset. A loop that keeps thousands of large bodies needs as much memory as those bodies, as keeping
anything does.

**Cross-platform.** `word build` and `word run` target the system they run on (a Linux `word` builds
ELF files, a Windows `word.exe` builds PE files) and cross-compile with `-win`, `-linux`, `-mac` and
`-arm64`. A defaulted output name gets `.exe` for the Windows target. `word run` works on both: on
Linux the program replaces `word` through `execve`, and on Windows `word` starts it with
`CreateProcessA` and waits for it. `env()` works on both too, and on Windows it ignores the case of
ASCII letters in a name, as Windows does. There's no MinGW and no second compiler
(`docs/BOOTSTRAP.md`): code generation is the same for every target, and the boundary with the
operating system is a `w_syscall` shim that maps the Linux system-call convention onto Win32. That
includes `net`'s transport, which goes through `ws2_32` sockets; the crypto is the same word source
on every platform. `BCryptGenRandom` supplies the random bytes and `GetSystemTimeAsFileTime` the wall
clock the certificate date check needs, and those two also back `random()` and `now()` for ordinary
programs, so every builtin in §9 answers the same on both. `MoveFileExA` backs `fs.rename`, with
`GetFileAttributesA` to keep a directory and a file from replacing each other. Each of these is
imported only by a program that reaches it, so a hello-world PE imports `kernel32` and nothing
else. `word.exe` builds itself.

The trust store and the resolver are the two places the platforms really differ. Linux and macOS
keep their anchors in a PEM file, which `net_load_roots` reads with `fs.read` and parses in word,
and name their resolver in `/etc/resolv.conf`. Windows has neither file: it keeps its anchors in the
Crypt32 `ROOT` store and lists its resolvers through `GetNetworkParams`. `sys.cacerts()` and
`sys.nameservers()` (§12.5) are the primitives that reach them. Two things follow on Windows. `ROOT`
holds only the roots the machine has already needed: Windows downloads the rest of Microsoft's root
program on demand, and word doesn't trigger that, so a site whose root Windows hasn't fetched yet
fails in word while a browser on the same machine reaches it. And the files are never looked for on
Windows, first or as a fallback. A path that begins with `/` there names a file under the root of the
current drive, where any signed-in user may create a directory, so a PEM bundle or a `resolv.conf`
found that way would be someone else's choice of trust store or resolver (`docs/SECURITY.md` §5).

The TLS stack, the X.509 verifier and the record layer are the same word source everywhere, so only
the syscall shim, the sockets, the trust-store lookup and the resolver lookup differ per target. But
being able to build for a target isn't the same as having run there, and `docs/SECURITY.md` §10 has
the table of what's been run where. Full handshakes against real servers run on Linux x86-64 and,
natively, on Windows, where a `net` program cross-compiled to a PE fetches over HTTP and HTTPS the
same way the Linux build does and reads its anchors from `ROOT`. On arm64 Linux it runs under
qemu-user, and macOS has no `net` in 1.0.0.

### 12.3 `json`


| Function | Effect |
|---|---|
| `parse(text)` | Parse `text` as JSON and return the value: an object becomes a map (§3.7), an array an array-marked region, a string a region, a number an integer or a float, and `null`, `true` and `false` the singletons of those names (§3.8). The text has to be JSON as RFC 8259 defines it, and anything else answers `none`: a syntax error, trailing text, a number RFC 8259 doesn't allow (`01`, `-`, `1.`, `1e`) or one past the range of a double, an unknown escape, a raw control character inside a string, or objects and arrays nested more than 1000 deep. A byte-backed `text`, such as what `read` returns, is decoded as UTF-8 first. `text` has to be a region, so a `none` from `get` has to be checked before it's parsed: `parse(none)` faults (§10.2). |
| `stringify(value)` | Render any value as JSON text and return it as a region. It's the rendering `out` and `.` give a map (§9.1), for any value. It faults on `none` (§3.8) and on an infinity or a NaN, since none of the three is a JSON value, and writing their names would make text `parse` rejects. It also faults on maps and arrays nested more than 1000 deep, or on one that contains itself, and on a string holding something that isn't a character (a negative number, a surrogate, or one past `0x10FFFF`) with `not a character`, as `out` does (§10.2). A byte-backed string is written as the characters its bytes spell as UTF-8. |

Two functions, with no options, no schema and no streaming. Everything else JSON usually needs is
already in the language: you walk a parsed payload with `o["field"]`, `len` and `keys` (§9), and you
build one with a `{}` literal.

**Failure is `none`** (§3.8). `none` equals nothing else in the language, so no successful parse can
pass `if data == none`. `parse("0")` gives the number zero, because the input was zero, and
`parse("null")` gives `null`, because the document said null. Those are three different answers,
each with its own value, which is why `none` exists: if failure were `0`, a failed parse and
`parse("0")` would look the same.

```javascript
body = get("https://api.example.com/rates")
if body == none
    err("fetch failed")
    return 1
data = parse(body)
if data == none
    err("bad JSON")
    return 1
out(data["rates"]["EUR"])
```

`none` isn't a condition (§3.8), so `if data` is a fault, not a test. Write the comparison.
Otherwise that line would treat a failed parse as an empty but valid document.

**What survives a round trip.** Keys and their order, text, structure, integers, and `null`, `true`
and `false` keep their values through `stringify(parse(x))`: the JSON words parse to the singletons
of those names and write back as themselves (§3.8). What doesn't survive:

- `none` can't be written: `stringify` faults on it (§3.8). Nothing `parse` produces holds `none`, so
  a parsed document can be written back; a map you built yourself with a failed conversion in it
  can't.
- A duplicate key keeps the last value, as JavaScript does.
- A float is written with the digits `out` gives it (§2.6), so it doesn't always come back as the
  same float: `0.1 + 0.2` is written `0.3`, and `1 / 3` as `0.33333333333333`.
- An integer past the 63-bit range (§3.1) is read as a float, and loses precision the way any 64-bit
  parser loses it; there's no bignum. A number past the range of a double is malformed.

Escapes work in both directions: `\n`, `\t`, `\r`, `\b`, `\f`, `\"`, `\\`, `\/` and `\uXXXX`,
including a surrogate pair (`\ud83d\ude00`), which becomes the one code point `word` stores. Any
other escape, or a raw control character inside a string, makes the text malformed. A `\u`
surrogate with no partner becomes U+FFFD instead of ending the program: the text is usually
something a server sent, and a malformed payload has to fail as data, not as a crash. That's also
why the depth cap exists.

### 12.4 `txt`

```javascript
char(n)          // a one-element region holding code point n
decode(b)        // a byte region's bytes, decoded as UTF-8 into code points
encode(s)        // s's code points as UTF-8 bytes, in a byte region
split(s, sep)    // the pieces of s between occurrences of sep, as an array
pad(s, w, fill)  // s in a field of |w|, padded with the code point fill
```

Five functions, and no new concepts: each takes words and returns a word. Each one covers a gap that
real programs, like the ones in `examples/`, run into.

| Function | Rule |
|---|---|
| `char(n)` | A new one-element region whose single element is `n`. It's the inverse of `s[i]`, and it's how a computed code point gets a spelling: `s . 72` renders the number `"72"`, and `s . char(72)` renders `H`. `n` must be a whole number; text or a float faults with `text: expected a whole number`. A code point outside the Unicode range isn't a character, so `out` renders the region as a list of numbers, as it does any region of integers that aren't all characters (§9.1), and `encode` faults on it. |
| `decode(b)` | A region holding `b`'s bytes decoded as UTF-8 into code points. `fs.read` doesn't decode (a file may be binary, §12.1), and joining a byte region with text promotes it one code point per byte, so `"1:" . line` garbles a non-ASCII line that `out(line)` prints correctly; `decode` is how a program says the bytes are text. It's the runtime's only decoder, the one `in()`, `args()`, `env()`, `net.get`, `parse` and the JSON writer use. Only well-formed UTF-8 decodes (Unicode §3.9): the shortest form, no surrogate, nothing past U+10FFFF. The lead byte of anything else passes through as a code point of its own and the bytes after it are decoded on their own, so `C1 BB` is the two elements `193, 187` (not `{`), and `F4 90 80 80` is four bytes (not 1114112). A region that's already code points is returned unchanged. |
| `encode(s)` | A new byte-backed region (§3.4) holding `s`'s code points as UTF-8 bytes. It's the inverse of `decode`, and it's how you ask how many bytes a text is, since `len(encode(s))` counts bytes where `len(s)` counts code points; the usual reason to ask is a `Content-Length`. The result is byte-backed, so `kind` says `"bytes"` and indexing it gives bytes. Unlike `decode`, a byte-backed argument isn't handed back unchanged: its elements, 0 to 255, are read as code points, and one above `0x7F` encodes to two bytes. That's what makes `encode(decode(b))` give back `b` for valid UTF-8. An element that isn't a code point faults instead of writing a cut-down byte: a whole number below 0 or above `0x10FFFF` with `encode: not a code point (0 to 0x10FFFF)`, a surrogate with `not a character`, and a float, a region, a map or a singleton with `text: expected a whole number`. |
| `split(s, sep)` | The pieces of `s` between occurrences of `sep`, as an array (§3.7), so `out` renders it `["a","b"]`. `n` separators give `n+1` pieces, so an empty piece is a real answer: `split("a,,b", ",")` is three pieces and `split("", ",")` is one empty one. Elements compare by value, which is exact for code points; it's a text operation, not the deep structural comparison `find` does. An empty separator faults (`split needs a separator with at least one character`), since there's no sensible answer. A byte-backed `s` is promoted to code points one per byte first, so pieces of `fs.read` output come back word-backed; `decode` the whole region before splitting it if it's UTF-8 text. |
| `pad(s, w, fill)` | `s` padded with the code point `fill` to `\|w\|` elements. A positive `w` right-aligns (pads on the left) and a negative `w` left-aligns, the `printf` convention. `pad` never truncates: if `len(s) >= \|w\|`, `s` comes back unchanged. `w` and `fill` must be whole numbers. |

`split` and `pad` are the two an ordinary standard library would have. They're in the language
because there's no library to put them in: one folder is one program (§11), so there's nowhere else
for a shared function to live. If that changes, this is the module to revisit.

### 12.5 `sys` (internal)

`sys` holds the operations the `word` toolchain needs for itself: collecting emitted assembly
(`asmput`, `asmtake`), writing an executable (`writex`), running a built program (`exec`, behind
`word run`), asking which instruction set and operating system this binary was built for and which
file it's running from (`arch`, `os`, `image`), reading the trust store and the DNS resolvers where
the OS keeps them behind an API (`cacerts`, `nameservers`), arena `mark` and `reset`, and the socket
verbs `net` is built on (`connect`, `udp`, `timeout`, `send`, `recv`, `close`). Like every module
it needs no `import`. It exists because the compiler, the assembler and the linker are one `word`
program (`compiler/word.w`), and that program has to do these things.

- `asmput(s)` appends the region `s` and a newline to the emit buffer, and `asmtake()` hands back
  everything collected so far and starts a new buffer. The buffer is byte-backed (§3.4): assembly
  text is ASCII, so `asmtake` hands back the shape `fs.read` gives for a `.s` file on disk, at one
  byte per character instead of eight.
- `writex(path, data)` writes `data` to `path` as an executable file, replacing what was there, and
  answers the integer `1` when it worked or `0` when it didn't.
- `exec(path, list)` runs the program at `path`, with `list` as its arguments in the compiler's
  internal list form: element 0 is the count and elements 1 to count are the arguments. It doesn't
  return when it succeeds. On Linux the program replaces the current one, and on Windows the current
  process starts it, waits for it and exits with its status. The path and every argument must be
  regions, and the count a whole number inside the list, all checked before anything is built.
- `arch()` returns the instruction set this `word` binary was built for: `0` for x86-64, `1` for
  AArch64. Each backend answers it as a constant, because a binary can't work it out at run time: a
  cross-built `word` looks the same from the inside as a native one. With `os()`, it decides the
  target `build` and `run` default to, so a `word` running on arm64 builds arm64.
- `os()` returns the operating system this binary was built for: `0` for Linux, `1` for Windows and
  `2` for macOS. It's a constant each backend writes, like `arch()`, so nothing in the environment
  can change the answer.
- `image()` returns the path of the running executable on Windows, as a byte-backed region of UTF-8
  (from `GetModuleFileNameW`, which only a program that calls `image()` imports), and `none` on Linux
  and macOS. It's how `word version` finds the binary it's checking on Windows. On Linux that's
  `/proc/self/exe`, and on macOS `argv[0]` when it holds a `/`.
- `cacerts()` returns the OS trust store as a byte-backed region of repeated
  `[uint32 length, little-endian][DER certificate]` records, or `none` where the OS doesn't provide
  its anchors through an API. Only Windows does: Linux and macOS keep the trust store in a file,
  which `net` reads with `fs.read` and parses in word. It answers `none` and not an empty region
  because the two mean different things: an empty region is an empty store, which trusts nothing, and
  must never read as "look for a file instead". It's a named primitive, not a general call into the
  platform's crypto library, for the same reason the sockets are six named verbs and not a general
  `syscall`: a program that reads the machine's trust anchors should say so where a reader can find
  it. Reading is all it does. Nothing here decides what to trust, and the records are parsed and
  validated in word like any other untrusted input.
- `nameservers()` returns the DNS resolvers the OS lists, as a byte-backed region of ASCII dotted
  quads, each followed by a line feed. It's empty when the OS lists none, and `none` where the OS
  names its resolver in a file. It's the same split as `cacerts`, for the same reason: Windows lists
  its resolvers through `GetNetworkParams` (IPv4 only, in the order the OS gives them), and Linux and
  macOS name theirs in `/etc/resolv.conf`, which `net` reads. The text is the OS's, copied and not
  parsed here; `net` uses the first line that's a dotted quad.
- `mark()` returns how many 8-byte words of the arena are in use, as a plain integer, and `reset(m)`
  rewinds the arena to that point, freeing everything allocated since. It's how a loop that would
  otherwise grow until it runs out of memory stays bounded (there's no `free`): mark at the top of an
  iteration, do the work, reset at the bottom. `reset` takes a whole number from 0 to the count in
  use now. Anything else, such as a made-up mark or one taken before an earlier reset went below it,
  faults with `index out of bounds`. It isn't safe: any region created after the mark is dangling
  after the reset, so nothing allocated in between may be used afterwards, and nothing checks that.
- The six socket verbs are what `net` is built on:
  - `connect(addr, port)` opens a TCP connection to the IPv4 address `addr` (four bytes, in a
    byte-backed region) on `port`, and answers the socket as a number, or 0 when it can't connect.
    It gives up after 10 seconds (§12.2).
  - `udp(addr, port)` does the same for a UDP socket. There's no handshake, so it answers at once,
    and `send` and `recv` then talk to that address.
  - `timeout(fd, ms)` gives the socket a read and write deadline of `ms` milliseconds, and answers 1.
  - `send(fd, data)` writes the bytes in `data`, and answers how many were sent, or 0.
  - `recv(fd, buf)` reads into the byte-backed region `buf`, and answers how many bytes arrived, or
    0 at the end of the stream, on an error, or when the deadline passes.
  - `close(fd)` closes the socket, and answers 0.

  Every argument is checked before any system call. A socket, a port and a timeout must be whole
  numbers, and an address or a buffer must be byte-backed. A wrong kind faults (`bytes expected, got
  text`, `bytes expected, got an array`, `operator needs whole numbers`), and `recv` won't write into
  a literal or a map key. A wrong value, such as an address that isn't four bytes or a port past
  65535, names nothing to connect to, and `connect` answers 0 as it does for a peer that doesn't
  answer.

  A Windows program can have 64 sockets open at once, because the OS layer keeps a table of them to
  tell a socket from a file handle. A 65th `connect` or `udp` answers 0 until one is closed. Linux
  has no such limit of its own.

`sys` isn't part of the general language. It's documented so you know what it is, not so you'll use
it: its functions are low-level and tied to the runtime's layout (`exec` takes a list in the
compiler's internal form, and `mark` and `reset` expose the allocator), and unlike `fs` and `net` it
carries no stability promise.

Most programs never need `sys`. A program that makes a few thousand `http://` fetches fits in an
ordinary amount of memory (`dev/toolchain/test_net_verbs.sh` makes 4,000 inside a 200 MB cap), and
one that keeps thousands of large responses needs room for them, which is the memory model of §3.5.
The exception is a loop that fetches without end. Every fetch keeps what it allocated, about 7.6 KB
plus the response over `http://` and about 110 KB over `https://` to a real site (§12.2), so such a
loop needs `mark` and `reset` to stay bounded.

---

## 13. Worked examples

Each of these is a complete program. Top-level code is the program (§8.1), so the short ones don't
need a function at all.

### 13.1 Hello

```javascript
out("hello")
```

### 13.2 A function, a loop, a branch

```javascript
add(a, b)
    return a + b

x = 10
total = 0
i = 0
loop i < x
    total = total + add(i, 1)
    i = i + 1
if total > 50
    out(total)
else
    out("0")
```

### 13.3 FizzBuzz

```javascript
i = 1
loop i <= 20
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

### 13.4 A contract that dies on bad input

```javascript
divide(a, b)
    return a / b

divide:before
    if b == 0
        return false        // fails the guard -> program terminates

out(divide(10, 2))          // 5
out(divide(9, 0))                // never prints: :before fails, program dies here
```

### 13.5 A shared contract across three functions

```javascript
withdraw(amount)
    return 0 - amount
deposit(amount)
    return amount
transfer(amount)
    return amount

withdraw:before, deposit:before, transfer:before
    if amount <= 0
        return false        // one guard protects all three; identical params required

out(deposit(100))           // 100
out(withdraw(0))                 // dies: amount <= 0
```

### 13.6 A tiny sort: arrays, strings in an array, comparison

A bubble sort over an array of words, compared by content (§3.3). It uses an array holding regions,
`len`, `[]` to read and write, and comparison. This program was the compiler's first milestone (§14).

```javascript
names = array(3)
names[0] = "cherry"
names[1] = "apple"
names[2] = "banana"

i = 0
loop i < len(names)
    j = 0
    loop j < len(names) - 1
        if names[j] > names[j + 1]
            t = names[j]
            names[j] = names[j + 1]
            names[j + 1] = t
        j = j + 1
    i = i + 1

i = 0
loop i < len(names)
    out(names[i])
    i = i + 1
```

### 13.7 A string transform: uppercase in place

```javascript
upper(s)
    // s must be writable: built by `.`, copy, or array, not a literal
    i = 0
    loop i < len(s)
        c = s[i]
        if c >= 'a' && c <= 'z'
            s[i] = c - 'a' + 'A'    // pure integer math on character codes
        i = i + 1
    return s

out(upper("hell" . "o!"))          // HELLO!
```

### 13.8 Input, and numbers-from-text with no conversion call

```javascript
out("How old are you?")    // the prompt is its own line: out always breaks
age = in()                // a number when the line is a whole number (§9.2)
if age > 17                // a plain comparison of numbers, with no conversion call
    out("adult")
else
    out("minor")
out("Hi " . in())          // a non-numeric line comes back as text; . joins it
```

### 13.9 Read every line of stdin

```javascript
loop
    if ended()
        break
    line = in()
    out("got: " . line)
```

### 13.10 Files

```javascript
text = read("notes.txt")
if text == none             // a failed read is none (§12.1)
    out("cannot read notes.txt")
    return 1                // exit status 1
if !write("copy.txt", text)   // write answers false when it fails
    out("cannot write copy.txt")
    return 1
out("copied " . len(text) . " bytes")
```

### 13.11 A map, and a JSON round trip

```javascript
person = {name: "Ada", langs: array(2)}
person["langs"][0] = "word"
person["langs"][1] = "analytical engine"

out(person)                          // {"name":"Ada","langs":["word","analytical engine"]}
out(len(person))                     // 2
out(person["email"])                 // none   an absent key has no value to give
out(person["email"] == none)         // true
out(has(person, "email"))            // false  the same question, for when a value could be none

ks = keys(person)                   // insertion order
i = 0
loop i < len(ks)
    out(ks[i] . " = " . person[ks[i]])
    i = i + 1

again = parse(stringify(person))
out(again == person)                 // true   maps compare by content
```

### 13.12 Multi-file program (folder model)

> The folder model of §11. `word build app.w` on the layout below compiles `strings.w` in with it, so
> `shout` resolves. Only an entry file named `app.w` pulls in its directory: `word build strings.w` is
> an ordinary single-file build, and it fails with `function 'shout' is defined but never used`.

```
myscript/
├── app.w          // entry file: holds the top-level program
└── strings.w      // definitions only, auto-included
```

`strings.w`:

```javascript
shout(s)
    return s . "!"
```

`app.w`:

```javascript
out(shout("hey"))          // shout() is visible with no import; same folder, order-independent
```

`strings.w` is in the same directory, so it needs no `import`, and one would be an error: `import`
accepts only a built-in module's name, and none of those needs one either (§11.1). A sibling
directory can't be imported.

---

## 14. Implementation appendix (informative)

None of this is part of the language. It describes the implementation, and the reasons behind several
of the choices above.

- **Targets.** One source builds for four targets: Linux x86-64, Windows x64 (a PE,
  `word build -win`), Linux AArch64 (`word build -arm64`) and macOS on Apple Silicon (a Mach-O,
  `word build -mac`). A build targets the host unless a flag says otherwise. The compiler self-hosts
  on all four in CI: Linux x86-64 natively, arm64 under qemu, and on a native Windows runner and a
  macOS runner a cross-built `word` rebuilds itself byte for byte. The Windows runner also runs the
  language, net and TLS suites there.

  The compiler emits **assembly text**, then assembles and links it itself. The `word` binary contains
  the x86-64 encoder, the AArch64 encoder and the ELF, PE and Mach-O linkers, so a build needs no
  external tool: no GNU `as`, no `ld`, no libc. Instruction selection, stack-frame layout and the
  calling convention are the compiler's job, and the assembler stage only turns textual instructions
  into bytes. It doesn't emit C, and it isn't an interpreter. GNU `as` and `llvm-mc` are used only in
  development and CI, as the oracles the two encoders are diffed against, never in a build.

  **`word build -asm app.w`** writes that assembly text to stdout (or to the file `-o` names)
  instead of assembling and linking it: the program plus its embedded runtime, which is what a build
  feeds the assembler.
  `word build -asm app.w > app.s` then `word asm app.s out` gives the same binary a direct
  `word build` does, and both commands take the same target flags (`-linux`, `-win`, `-arm64`,
  `-mac`). For `-win`, name the dump after its source (`app.w`, `app.s`): a PE's version block carries
  the program's name, which `word build` takes from the `.w` and `word asm` from the first `.s`. The
  dump is also the way to see what the five keywords compile to, with nothing but `word` itself.
- **No third-party runtime or library.** Every binary embeds the small `word` runtime it needs. On
  Linux the runtime makes direct system calls (`read`, `write`, `mmap` for the arena, and so on).
  Windows reaches the Win32 API through the generated `w_syscall` shim. On macOS, dyld maps the image,
  but there's no `LC_LOAD_DYLIB`, so it loads nothing else, and the runtime makes raw `svc #0x80`
  system calls through its own shim (`m_syscall`). No target links libc or a third-party runtime,
  though a native executable still relies on its OS and loader.
- **The runtime is assembly because it measured faster.** The obvious question about a self-hosting
  language is why `rt_copy`, `rt_sort`, `rt_find`, the UTF-8 codec, the map and the JSON parser are
  emitted assembly when the `net` library is written in `word`. I wrote three of them in `word` and
  ran them against the assembly on the same data and the same x86-64 machine, counting instructions
  with callgrind:

  | | word vs the assembly | wall |
  |---|---:|---:|
  | `rt_copy`: a `rep movsq` against `o[i] = s[i]` | **27.7x** the instructions | 1.4x |
  | `rt_utf8_decode`: a byte-at-a-time scanner | **4.4x** | 3.2x |
  | `rt_sort`: the same bottom-up merge sort, memory-bound | **1.54x** | 1.05x |

  I measured this once, in September 2026, and the `word` versions and the harness aren't in the
  repository. Against a string operation, a loop in `word` pays a tagged increment, two
  bounds checks, a subkind dispatch and a tagged store per element, where the assembly pays one
  `movsq` per eight bytes. Against a byte scanner, which the JSON parser and the number conversions
  also are, it's about 4x. Only the memory-bound sort gets close, and it still runs 54% more
  instructions. Its 5% on the clock is inside the layout noise described under loop alignment below.
  The `net` library is `word` because it's bundled per program and none of it is on a path this hot.
  The runtime every program carries is a different question.
- **Why Rust is fast, and what of it transfers.** Rust is fast for four reasons, and two of them are
  about the language: monomorphization with values laid out inline, and move semantics. `word` has no
  generics to specialize and no destructors to skip, so those two have nothing to offer it. (Inline
  layout it only half has: an integer lives in its word, but a float is boxed, §15.) The other two are
  LLVM's: hoisting a loop-invariant `len`, and dropping the bounds check inside a counted loop. Both
  rest on an aliasing fact Rust states in its type system and `word` has to prove, and §7.2 does both
  on x86-64. What doesn't transfer is `noalias` in general. Rust can tell LLVM that two `&mut` never
  overlap. `word` has no references, but two names can hold the same region, so the nearest equivalent
  is the uniqueness analysis in §3.4. It's already there, and it's what the in-place append and the
  dead-store rewind rest on.
- **Region space.** The literal pool is mapped at a fixed base, `0x0000_6000_0000_0000`, far from
  where any loader puts anything, because codegen bakes each literal's address into the code as an
  absolute `base + offset`. The mapping is read-write on every target, and only the runtime's
  write-to-literal check keeps a program from writing to it (§15). The arena, which holds every
  dynamic allocation, is a separate mapping at a base randomized on every run on every target: at
  least 16 MiB above the pool, plus up to about 256 GiB taken from `getrandom` (Linux), `getentropy`
  (macOS) or `rdrand` (Windows) mixed with the stack pointer's own ASLR (`docs/SECURITY.md` §4). The
  base is page-aligned (16 KiB pages on Apple Silicon), and on Windows it's aligned to
  `VirtualAlloc`'s 64 KiB granularity. The arena grows in place at `arena_base + span`, and never past
  a 16 TiB span. On Linux and Windows that growth refuses to map over anything already there
  (`MAP_FIXED_NOREPLACE`, and `VirtualAlloc` at a fixed address). Darwin has no such flag, so on macOS
  the growth maps with `MAP_FIXED` and relies on the span cap to stay inside the `0x60...` window.
  `is_region` doesn't depend on any of this: it's a low-tag test (`and 7`, §3.6), so a region can live
  at any address. "Is this a literal?" (the write-to-literal check, §10.2) is one compare against the
  pool's end (`litpool_top`).
- **Where the kind test runs.** An operation that needs a particular kind tests the tag of any operand
  the compiler couldn't classify (§3.6): arithmetic, indexing, `len` and the other builtins that check
  their argument, comparison, `.`, and printing. Arithmetic, indexing, `len` and comparison test
  inline, and `.`, `out` and `kind` test inside the runtime routine they call. An operand whose kind
  is known at compile time gets no test.
- **Line numbers at run time.** A fault (§10.2) gives a file and a line, and there's no table behind
  that. A statement that can fault stores its line number into a global, `cur_line`, before it runs,
  and a statement that can't fault stores nothing. After a call, the caller's line is stored again
  only when something later in the same statement can fault, and a loop whose test can fault on a
  later pass stores its line at the top of each pass. The fault handler reads `cur_line`, works out
  which file of a folder program that line falls in, and prints `file:line`. Statements in the bundled
  `net` library store nothing, so a fault inside it gives the line of the program that called the
  verb. Both backends work the same way.
- **Running out of stack is a fault.** `stack exhausted` (§10.2) comes from a guard in every
  function's prologue: two instructions on x86-64 (`cmp rsp, stack_limit; jb rt_stack`), and the same
  compare on arm64. `stack_limit` is computed once at startup, as the entry stack pointer minus the
  usable stack, keeping 128 KB back so the fault message has room to run. Under a limit of 512 KB it
  keeps a quarter of the limit instead, so a stack of 128 KB or less still runs a program. The usable
  stack is the process's `RLIMIT_STACK` on Linux and macOS, clamped to 1 GB so an unlimited stack
  still gets a ceiling. On Windows it's the `SizeOfStackReserve` word's own linker writes into the
  image, 8 MB, and the linker and the runtime read the same constant, so the header and the runtime
  can't disagree.
  Linux's default is also 8 MB, so a program recurses about as deep on both. Unbounded recursion stops
  with `app.w:N: stack exhausted` and exit status 70 instead of a segfault or an access violation, and
  `N` is the line that recursed. A function whose frame is a page (4 KB) or more is checked where the
  frame will end, before it's taken (three instructions on x86-64), so a frame bigger than what's kept
  back faults the same way instead of running off the end of the stack. On Windows that prologue also
  touches the frame a page at a time from the top, the way MSVC's `__chkstk` does, because Windows
  commits a thread's stack one guard page at a time and a first access more than a page below it is an
  access violation. The same guard covers a comparison recursing through a structure it
  can't finish (§3.3), in `rt_eq` and in `rt_order`, on both backends. There it reports
  `comparison nests too deeply (a cycle?)`, because the program usually has no recursion of its own to
  look at.
- **A map is a boxed cell in the same arena.** The extension tag (§3.6) points at four words: a
  subkind, the number of live pairs, the pair region (`key, val, key, val ...` in insertion order),
  and an open-addressing index from a key's hash to a pair position. A lookup is a hash and a short
  probe, and `keys` reads the pair region at stride two, so insertion order needs no second structure.
  Writing an existing key overwrites it in place. A new key appends, and when the index is half full
  it's rebuilt at double the size. Keys hash and compare through the same `bytepromote` path
  everything else uses, so a key sliced out of a file matches the literal that spells it.
- **A join chain allocates once.** `x = a . b . c . d` is one call to `rt_joinn`, on both backends:
  it measures every part, allocates the result once, copies each part in, and writes an integer's
  digits straight into place. The parts are still evaluated left to right, but the joining happens
  after the last one, so a call in a later part could change a region an earlier part names before
  it's copied. So a chain is joined this way only up to the part before the first call from its
  third part on (a builtin's included), and up to 200 parts. From there it joins pair by pair with
  `rt_join`, where each `.` allocates a new region, copies both sides into it and leaves the one
  before in the arena: `"line " . i . " of text"` is one region, and
  `"line " . i . " of " . len(s)` is two. The in-place append (§3.4) is separate: `s = s . a . b`,
  with `s` a unique local, lowers to one append per operand and grows `s` into spare capacity. On
  x86-64, a loop that rebuilds a line with `.` leaves garbage in the arena (there's no `free`) only
  where the line outlives the iteration: a temporary consumed by the operation it was built for, and
  a region a unique local is about to overwrite, are both given back (§3.5). A region that's stored,
  aliased, or handed to a function that keeps it stays. The arm64 backend gives nothing back yet, so
  there every discarded temporary and every overwritten region stays in the arena (§15).
- **On x86-64, an unboxed double stays in the SSE domain.** An unboxed float local's slot is read and
  written with `movsd`, and it can be an SSE instruction's memory operand directly
  (`mulsd xmm0, [rbp-8]`), the same way a pooled float literal can. Routing it through a general
  register instead isn't only longer: a general-register store feeding a vector load from the same
  address doesn't forward through the store buffer, and that stall cost `mandelbrot` 28% of its wall
  clock while its instruction count was 38% lower. An instruction count can't see a domain mismatch
  like that, and neither can cache or branch simulation, so when the clock gets worse while the
  instruction count drops, a store and a load in different domains is the first thing to look for. The
  arm64 backend has no unboxed floats yet (§15).
- **Loop heads are aligned to 16 bytes**, on both backends. Without it, where a hot loop sits in the
  instruction fetch window depends on whatever code comes before it. `sieve` showed it on x86-64:
  across six offsets made by prepending dead statements, its wall time with unaligned loop heads
  spreads from 127 to 147 ms, so the same source can look 5% faster or 5% slower than a change to it,
  depending only on where the inner loop sits. With loop heads aligned I measured a spread of
  127-141 ms, a median of 133 ms against 142, and 127 ms for the program as written against 143.
  slicebench -3.0%, strbuild -3.3%, sortints -1.9%, mapbench +2.2%, strchain, mandelbrot and fib
  unchanged, and the binary 0.2% bigger. 32-byte alignment measured worse on every one of them.
- **On x86-64, a function's busiest locals live in registers.** In a function with a loop, up to five
  integer locals or parameters are pinned to the callee-saved registers `rbx` and `r12`-`r15` for the
  whole body, and up to eight raw-double float locals to `xmm8`-`xmm15`. A use inside a loop scores
  ten, times ten again for each further level of nesting, and a name has to score over 19 (two uses
  inside a loop, or one inside two) to be picked. A slot the dead-store rewind zeroes and the hidden
  index of a `loop x in y` stay in the frame. The function saves the registers it uses and restores
  them at every exit, so the calling convention doesn't change. Nothing else touches `xmm8`-`xmm15`,
  the runtime included, and a Win64 call preserves them. I measured a bare counting loop at 36.4 ms
  pinned against 67.7 ms in the frame, with 29% fewer instructions, because the store and reload
  through a stack slot are part of the loop-carried dependency. Floats show it most: mandelbrot
  measured 8.8 ms pinned against 20.4 (C: 8.1). A double is copied from register to register with
  `movapd`, never `movsd`. The register form of `movsd` writes only the low half, so it waits for
  whatever last wrote its destination, and with `movsd` copies the pinned loop measured no faster
  than the frame. The
  arm64 backend doesn't pin.
- **A one-line accessor is substituted, not called.** A function whose whole body is
  `return <expression>` is inlined into its callers before any analysis runs, when the expression
  makes no call of its own, every argument is free of calls and joins, any parameter the body never
  reads has an argument that couldn't have failed anyway (dropping `f(a[99])`'s index check would
  lose a fault), and the callee has no contract hook (a hook has to see the call). A parameter the
  body reads more than once is substituted only when its argument is a name or an integer, text or
  singleton literal, which reads the same value everywhere and costs nothing to read, and only when
  the body indexes nothing (an index is a checked load, and copying it to every call site grows the
  code), so no argument is ever evaluated twice. `dist(a, b)` for `return x * x + y * y` becomes
  `a * a + b * b`, which I measured at 2.9 ms on vecmath against 4.2 without it. Calls in top-level code are
  substituted the same way. The no-call condition keeps the tree from growing: without it, a chain of
  one-liners that each call the next would have each body substituted into the next, and the tree
  would double down the chain. `lcount(lst)` is `lst[0]` and `lget(lst, i)` is `lst[i + 1]`, about
  thirty instructions of call, prologue, stack guard and epilogue for one load, and the compiler makes
  about 700 such calls. Hand-inlining all of them measured 3.85% of a self-build, and this
  substitution measured 2.65%. It rewrites the tree, before any analysis,
  because the parameter-kind pass, the subkind lattice and the loop analyses all read the tree, and a
  call is opaque to them. The same substitution done during code generation, after they've run,
  measured 0.95%, about a quarter of the hand-inlined figure. One effect is visible: a fault in the
  substituted expression gives the caller's line instead of the accessor's own.
- **On x86-64, a copy is a block move.** `copy`, `.` and the in-place append move their elements with
  no per-element index arithmetic. A word-backed run under 256 words goes 32 bytes a step through
  two SSE registers, because `rep movsq`'s start-up costs more than a copy that short, and a longer
  one is a `rep movsq`. A byte-backed run is a `rep movsb`. For `copy`, under eight words (sixteen
  bytes for a byte-backed region) even that costs more than it saves, so a short slice takes a tight
  countdown loop instead. That's the common case in a compiler or a scanner, where every token is a
  short slice. The arm64 runtime copies with plain load and store loops.

---

## 15. Known tensions and future forks (informative)

Open questions, decisions I've put off, and known gaps in 1.0. Each is a place where the minimal model
strains, or where the implementation doesn't yet do everything the model allows.

- **A kind test reads the value's tag.** Deciding kind by asking whether a word falls inside region
  space misreads a plain integer of the right size as a region. §3.6 is the tagged model instead: the
  tag rides in the value's own alignment bits, so it survives a store into an array cell, `'A'` is
  still `65`, and a kind test takes two instructions. The same goes for the rest of the runtime: a
  kind test that reads an address is only as good as the address map, and every place the runtime
  dereferences a word it didn't classify is a way for an integer to be read as a pointer.
- **Parameter types stay out.** Annotating `show(x: string)` would make every kind static and remove
  the runtime kind test, but it brings back annotations, checking and mismatch errors, the type-system
  machinery the language exists to avoid. Literal notation and operator result kinds stay the
  compiler's static signals, and parameter annotations don't join them.
- **Byte-backed regions are a kind.** A word per element (§3.4) costs 8x on text, too much for file
  I/O: an 8 MB read would take 64 MB. So `read` returns a byte-backed region (one byte per element,
  and a flag in the region header), and `bytes(n)` makes one. It's visible to a program, not an
  internal subkind every operation treats like a code-point region: `kind()` answers `"bytes"` for it (§9), `len` counts bytes, `y[i]` is a byte, a store keeps the low
  8 bits of a whole number (anything else faults), and `write` writes it as raw bytes where it writes
  text as UTF-8 (§12.1). String literals, `text(n)` and every other region stay word-backed, so text
  is still code points (§12.1). The fork left open is making text itself byte-backed UTF-8, and I'm
  not taking it, because that one really would change what `len` and `s[i]` mean.
- **Three constructors, because there are three things.** `array(n)`, `text(n)` and `bytes(n)` look
  like they could collapse into one, but they make three different regions. `bytes(n)` holds only
  bytes. `array(n)` renders as `[...]` and pulls in the map and JSON-rendering runtime, about 4 KB
  that a program which only indexes storage never needs. `text(n)` is the mutable word-backed text
  buffer, the one the compiler's hottest path needs. Collapsing them would route `text(n)` to
  `array(n)`, and then `num_to_str`, which builds a string out of word slots, would render every
  number as `[49, 50, 51]` instead of `"123"`, which in a self-hosting compiler means emitted assembly
  that segfaults. The constructors are named for the three kinds they make, and `kind()` answers with
  those names.
- **`out` always ends a line.** Every `out` appends `\n`, so the common case, one value on one line,
  is a single call, and a loop that would print a fragment per iteration builds one region with `.`
  and prints it once (§9.1). The cost is that `out` can't write without a newline: no prompt on the
  same line as the `in()` that answers it, and no byte-exact stdout that leaves off the final line
  break. On Linux, `append("/dev/stdout", ...)` writes without one, but that's a file path doing an
  output builtin's job, and on Windows it answers `false`. A second primitive (a `put` with no
  newline, or a raw writer beside `out`) would buy it back at the price of a second output builtin.
  For now the trade is one primitive and the lost newline.
- **Floating point.** A float needs the value model to tell a float word from an integer word, and the
  low tag (§3.6) does: tag `010` is a **boxed IEEE-754 double**, a pointer to eight bytes of double in
  the arena, so the kind travels with the value and the CPU's float instructions are reached by
  dispatching on the tag. A literal with a decimal point is a float (§2.6), `+ - * /` promote an
  integer to a float when the other operand is one, `/` gives a float for two integers that don't
  divide evenly (§3.3), comparison works across the two, and `%` and the bitwise operators stay
  integer-only. A float is boxed, one allocation each, which is the price of keeping every value one
  64-bit word, and it's affordable because `word` is integer-first (`docs/VALUE_MODEL.md`, "Floats").

  On x86-64 the compiler takes back part of that cost by **reusing a box it can prove nothing else
  holds**. A result goes into the left operand's box when that box is a temporary the expression owns
  (an operator result, or a freshly boxed literal), and into the target's own box for `x = x <op> ...`
  when the uniqueness pass (§3.4) proves `x` unaliased. So `a*b + c + e` allocates one box where it
  would otherwise take three, and an accumulator loop allocates once per iteration. A temporary on the
  right still costs its own box, so `a*b + c*d + e` allocates two. It goes further for a **local whose
  every assignment is a float**: that local's frame slot holds the raw double, so a float loop
  allocates nothing at all, and the arithmetic and the comparisons run in xmm registers on values that
  never reach the arena. Which locals qualify is decided per function by an optimistic fixpoint over
  the static kinds the compiler already has, and a second, whole-program pass does the same for
  **parameters** by joining what every call site passes. That's exact, because there are no function
  values: every call names its function. A local assigned anything else, and a `loop x in y` binding,
  are left out, since each receives a tagged word from somewhere the compiler can't see. A parameter
  proved float is passed as the raw double, and a function whose every `return` is a float hands back
  the raw double. Caller and callee agree because both read the same row of the same whole-program
  table, computed before any code is emitted, and a body that might fall off its end (which answers
  the integer 0) is left out.

  None of this is the parameter-type machinery set aside above: there's no annotation to write, no
  check to fail, no mismatch to report, and no behaviour that depends on it. It's only an
  optimization. A copy, and a value read out of a region or a map, are still boxed, the ordinary read
  path boxes unconditionally, and a program can't tell which representation a value is in. Arithmetic
  is taken to give a float only when both operands are numbers, so a parameter whose only caller
  passes a map stays a tagged word, and `v + 1` on it faults with `number expected, got a map` when it
  runs, on both backends. The arm64 backend has none of the optimization: it boxes every float result
  (see the arm64 entry below).

  Each distinct float literal is converted to the nearest double at compile time and loaded from a
  constant slot, so a literal in a loop is one load.

  Printing is fixed-point: the integer part, the point, and as many fraction digits as 15 significant
  digits leave room for, with trailing zeros trimmed and at least one fraction digit kept, so a float
  always shows its point. That gives 15 significant digits in the usual range, but not everywhere. A
  value below 1 gets 14 (`out(1 / 3)` prints `0.33333333333333`), a value from 1e14 to 1e15 with a
  fraction gets 16, and from 1e15 up to 2^63 the integer part is printed in full, up to 19 digits,
  with one fraction digit after it. Every value is rendered through an **exact decimal expansion of
  the bits**: the significand is written in decimal and doubled or halved by its binary exponent
  (both exact in base ten, by up to 2^56 a pass), then rounded half up at the last place printed. No
  division and no floating point, so nothing drifts. `1e25` prints as
  `10000000000000000000000000.0`.

  Going the other way, a float back to a whole number where one is required (an array index, `%`) is
  the one `round(x)` builtin (§9), which faults on `inf`, `nan` and anything past the integer range.
  There's no `is_float`/`int`/`float` trio: `kind(x)` is the only kind test the language exposes, and
  it answers `"number"` for an integer and a float alike.
- **Float printing isn't a shortest round trip.** `out` and `stringify` print a float with the digit
  counts above, which aren't the shortest decimal that reads back as the same double. Sometimes that's
  too few: `0.1 + 0.2` prints as `0.3`, which reads back as a different double, and `1 / 3` prints 14
  digits where reading back the same double takes 16. Between 1e15 and 2^63 it can be more than
  needed: `98765432109876543.0` prints all 17 digits of `98765432109876544.0`, where 16 would read
  back the same. A shortest-form printer would fix both, but it would change what existing programs
  print.
- **A long-running fetch loop stays within the safe subset.** Memory here is safe by construction: no
  `free`, no pointer arithmetic, every region access checked, and no way to reach a dangling region.
  `sys.reset` is the exception. Its purpose is to invalidate live references, so the SECURITY.md
  threat model calls it an opt-in use-after-free, and §12.5 keeps `sys` out of ordinary programs. A
  plain http fetch keeps about 7.6 KB plus its response, so an http poller runs a long time with no
  `sys` in it (`test_net_verbs.sh` runs 4,000 fetches under a 200 MB cap). A verified https fetch
  keeps about 110 KB against a real site, and none of that is the trust store, which it parses every
  time and gives back, so an https poller needs `mark`/`reset` (§12.5) only for the reason an http
  one does. The rest of the gap, what any fetch keeps, is the cross-call reclaim in its own entry
  below.
- **The map is JSON.** The map is the language's second aggregate, and it answers two questions at
  once: `{}` is a map (§3.7), and JSON is what a map prints as (§9.1), so one concept gives both the
  keyed structure and the data format every network program needs, with no object-to-JSON layer, no
  `to_json` and no schema. The map uses the extension tag reserved in §3.6. Its runtime, with the JSON
  renderer, is emitted only for a program that can build a map or a JSON array: one with a `{}`
  literal, or a call to `array`, `split`, `keys`, `has`, `args`, `parse` or `stringify`. What's left
  out matters as much: no methods, no inheritance, no field syntax (`o.k` is still a join), and no
  keys that aren't text. A map holds data, and there are no objects.
- **Content equality goes all the way down.** `==` recurses into nested regions and maps (§3.3), so
  `parse(stringify(x)) == x` holds for a map built from text, integers, `true`, `false`, `null`, and
  maps and arrays of those, and there's no way to ask whether two words are the *same* region. The
  round trip doesn't hold for every value: a float can come back different, because printing isn't a
  round trip (above), and `none` isn't a JSON value, so a map holding it faults in `stringify`
  (§12.3). Nothing in the compiler depends on identity comparison: a string-literal node carries its
  own pool offset, so `lit_lookup` is one load instead of a scan that content equality would turn into
  a deep comparison of every literal's text.
- **The kind test is `kind(x)`.** It exposes the test the value model already runs (§9), a name per
  kind from `"number"` to `"none"`, so a program can check what `in()` or `args()` gave it and branch
  instead of dying. That softens the rule that a program which doesn't meet its requirements dies
  (§8.2, §9.2) for the most common case, bad input, while every other misuse stays fatal. The fork
  left is how much more of that should become recoverable. Nothing is planned, and leaving it is a
  decision, recorded here and in `docs/SECURITY.md` §10.
- **No logical shift right.** `>>` is arithmetic (§3.1), because the one integer type is signed. A
  logical shift takes a mask, which is awkward enough to argue for a second operator, and the operator
  budget doesn't want to pay for one.
- **No `fn` keyword.** A bare `name(args)` line followed by an indented line is a function definition,
  not a call (§4.2), so an accidental indent can turn a call into a definition. The compiler catches
  most of these. A duplicate definition, an argument that isn't a plain name, and an arity mismatch
  with the program's actual calls are errors. Inside a block the indented line is an
  `unexpected indent`, since a function can only be defined at the top level. A definition the
  program never reaches is an error too, `function 'name' is defined but never used`, located at the
  definition, even when it calls itself, unless the function carries a contract hook (§8), which
  shows it's meant to be there. This is the
  same idea as Go making unused variables and imports errors, and it needs no warning channel: `word`
  has only errors and clean builds. One case is still open. At the top level, an accidental definition
  that takes a builtin's name, such as `out(x)` followed by an indented line, is legal, because a
  program may define its own `out` (§2.5). Every other `out` in the program then calls it, so nothing
  reports it.
- **Rewriting (transformer) contracts.** A hook (§8) observes: it can't reassign a parameter or
  `result`, though it can still write into a region it was handed (§8.2). Letting hooks rewrite
  arguments or results would make them middleware. That's powerful, but it brings back the invisible
  action contracts exist to prevent. If it's ever added, it will be an explicit opt-in.
- **Networking, HTTP and TLS, in `word`.** Fetching from the web needs DNS, TCP, TLS and HTTP parsing,
  and all of it is written in `word` itself with no external dependency. DNS, the socket, the TLS 1.3
  handshake and record layer, ECDHE (X25519, P-256, P-384), ChaCha20-Poly1305 and AES-128-GCM, and
  RSA/ECDSA X.509 verification are the `net` library carried in `compiler/word.w` (§12.2). Unlike most
  entries here, this is a fork the language took. `https://` works from scratch on Linux and Windows.
  macOS is the next entry.
- **No `net` on macOS in 1.0.0.** The macOS runtime's system-call shim has no socket calls yet, so on
  macOS every `net` verb answers `none`. The TLS code itself is the same on every target. What's
  missing is the socket layer underneath it.
- **The literal pool is writable memory.** The pool is mapped read-write at its fixed address (§14),
  and nothing makes its pages read-only after the literals are copied in. What stops a program writing
  to a literal is the runtime's check (`s[i] = v` on a literal faults with `write to a literal`,
  §10.2), and page protection doesn't back it up. A bug in the compiler or the runtime that wrote
  through a literal's address would change the literal instead of faulting.
- **The arm64 backend does less.** Programs mean the same on both backends, but the arm64 one (Linux
  arm64 and macOS) has none of the x86-64 memory and speed work yet: it gives back no temporaries and
  no overwritten regions (§3.5, §14), it boxes every float result, it pins no locals to registers, and
  it doesn't hoist `len` or drop bounds checks (§7.2). Some loops use far more memory there. The float
  loop `acc = acc + x * 1.5`, run five million times in a function, keeps one box on x86-64 and 480 MB
  on arm64, and `len(copy(s, 0, 10000))` two thousand times keeps nothing on x86-64 and 160 MB on
  arm64.
- **Importing a sibling directory isn't part of the model.** A second form of `import`, a bare name
  that isn't a built-in module resolving to a sibling directory of `app.w`'s and pulling it in whole
  under the same flat, definitions-only rules (with the built-in module names reserved, so a directory
  called `fs` would be an error), is a possible future direction. A program can't do it in 1.0, which
  ships the folder model alone.

  If it were built, what it would cost is the argument against building it. All imported code would
  share the one flat namespace, so a library directory could call a function from another directory,
  but only if `app.w` imported that one too. A library's requirements would be declared nowhere and
  checked only at build time. Directory names would have to be unique across everything a program
  pulls in, with nothing to tell two `http`s apart. Each of those is a small problem at one folder and
  an unbounded one at a hundred, and the answer to them is namespacing, which is the next entry and
  isn't here either. A language meant for one folder doesn't need to solve either, and leaving both
  out keeps the collision rule a single sentence.

  The 1.x freeze is what makes this cheap to defer. It forbids removals and changes in behaviour, so a
  directory import arriving in some 1.x would be an addition, which is allowed. The only thing that
  couldn't be walked back is shipping the wrong one now.
- **Namespaces.** None. Cross-file name collisions are resolved by renaming (§11). If programs grow
  past what a flat folder handles, namespacing is the natural next tool, and leaving it out is what
  keeps the collision rule so simple.
- **A discarded call gives nothing back when the callee is `word`.** §3.5's rule that a temporary used
  as an argument and not kept is popped works: on x86-64, `len(copy(s, 0, 10000))` two thousand times
  over keeps nothing in the arena, where without the pop it would keep 160 MB (which is what arm64,
  with no pop yet, keeps). But it only fires for builtins. Write the same loop around a `word`
  function that allocates, `len(mk(10000))` where `mk` returns `text(n)`, and it keeps 160 MB on every
  target, because the callee may have allocated things *below* its return value and the bump pointer
  can only move back over the most recent allocation.

  That's all that's left of the `sys` gap above: it's why a fetch keeps about 7.6 KB at all, since
  `get` is a `word` function like any other. The reclaim would be invisible in the sense §3.5 means (no
  program could observe that it fired), but it stays an open fork, because the obvious route isn't the
  safe one.

  Rewinding the arena to a mark taken before the call would free everything the callee allocated,
  including anything it stored into a region the caller passed in. Nothing in the compiler answers
  that: `fn_retains` asks whether an *argument* stays reachable, which is a different question from
  whether the callee put something *new* somewhere lasting. That route needs a store-taint analysis
  this compiler doesn't have, and its failure mode is a use-after-free, which the language exists to
  rule out.

  The route that does fit is `rt_popregion`, which guards itself: it rewinds a region only when that
  region is still the last thing allocated in the arena, so when it's wrong it does nothing. Extending
  `is_owned_temp` to a call whose result is provably freshly allocated by the callee would let a
  discarded result be reclaimed under that same guard. The analysis it needs, that every `return` in
  the body yields something the body allocated and never shared, is close to `returns_bare` and the
  escape set `infer_retention` already computes. That's how a fix should look, and it needs a
  poisoning test over the whole suite before anyone trusts it.
- **A kind error behind a name is caught when the local's kind is unambiguous.** A local's kind is
  known when every assignment to it agrees (§10.1): one walk, no joins, no fixpoint, and one sentence
  to state. It misses two things. One is a name whose branches disagree, where a flow-sensitive rule
  would know the kind on each path separately. I've left that open, because the extra reach is small
  and it's bought with a rule whose answer a reader can't predict without running the analysis in
  their head, which is the wrong trade for a language people are meant to hold all of at once. The
  other is a plain copy. The right-hand side has to show its kind without looking through another
  name, so after `x = 1` and `y = x`, `out(y[0])` compiles and faults at run time, while `y = x + 1`
  is caught. That one simply isn't done yet. If either is revisited, the definite-assignment machinery
  (§5.1) is where a second lattice would go.
- **`json.parse` gives the double a source literal gives.** `json.parse` and `number()` read the
  digits into a 63-bit mantissa, and while that's below 2^53 and the power of ten is within 10^15,
  one multiply or divide of two exact doubles is correctly rounded. Anything else is converted the
  way the compiler converts a literal (§2.6): the first 800 significant digits, and a 1 standing in
  for any nonzero digit after them, are held exactly in decimal and doubled or halved until the
  integer part is a 53-bit significand. So at every magnitude `parse`, `number()` and a literal of
  the same digits give the same double, the nearest one. The exact path costs more: I measured about
  13 microseconds for `parse("1e-300")` against a few hundredths of one for `parse("1.5")`, and 0.2
  for a 17-digit number like `0.30000000000000004`.
- **A parsed JSON payload can lose information.** A duplicate key keeps the last value, and an
  integer beyond the 63-bit range (§3.1) comes back as a float and loses precision. `null`, `true` and
  `false` parse to the matching singletons (§3.8), so they come through as themselves. §12.3
  documents both.
- **Tooling.** Syntax highlighting, an LSP language server and a formatter all ship (`editors/`,
  `word format`), the formatter as the one canonical layout of §2.2. The server owns none of the
  language: its diagnostics are `word build`'s own stderr and a format is `word format`'s own output,
  so the only things it decides for itself are where a name is defined and what's in scope. Still open
  are a **tree-sitter grammar** (the TextMate one is generated from `builtin_arity`, which keeps it
  current but doesn't make it a parser) and an incremental server that doesn't re-run the compiler on
  every keystroke. Neither is needed until a file is big enough for the difference to be felt, and
  `compiler/word.w` at about 39,000 lines is not.
