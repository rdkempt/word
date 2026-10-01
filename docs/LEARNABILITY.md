# Is `word` still learnable?

Three questions I keep asking about word, and I want the answer to all three to stay yes:

1. Can a beginner read and understand it, or has it become a hacker language?
2. Can it be fully learned in an afternoon?
3. Does it behave the way a newcomer expects?

The short answers are yes, yes, and mostly. There's one rule you have to be told in the first minute
(a character is its code), and there are two edges worth knowing, and I've kept both. Section 3
goes through them, along with how printing and division behave. This page holds the evidence, so the answers can be
checked again as the language changes.

I wrote it by using the language the way a newcomer would, instead of by reading the spec.

---

## 1. Can a beginner read it?

The whole surface fits in a small table:

| | |
|---|---|
| Keywords | **5**: `if` `else` `loop` `return` `break` (plus 5 contextual words: `before` `after` `result` `import` `in`) |
| Always-available builtins | **20**, against a self-imposed ceiling of 25 |
| Modules | **4**: `fs` (5 functions), `json` (2), `net` (5) and `txt` (5), plus the internal `sys` |
| Aggregates | **2**: the region (text and arrays are the same thing) and the map (`{}` is JSON) |
| Types | **1**: a 64-bit word |

Size isn't what makes a language readable for a beginner, though. What matters more is what happens
when they get something wrong. Every mistake I made while probing got a message that says what's
wrong and where:

```
out(y)                  -> 1:5: undefined variable 'y'
out(lenght("ab"))       -> 1:5: call to undefined function 'lenght'
out(f())                -> 3:5: 'f' expects 1 argument(s), but got 0
out("5" + 1)            -> 1:5: left operand of '+' must be a number, but got a region
out(1 < "a")            -> 1:7: '<' cannot compare a number with a region
out(stringifyy(x))      -> 3:5: call to undefined function 'stringifyy'
out(total)              -> 1:5: undefined variable 'total'    (a read before any assignment)
```

None of them just says "syntax error". (`stringify` itself needs no import: the compiler knows which
module each module function belongs to and turns the module on at its first use, so the only way to
get that error is to misspell the name.) Run-time faults have the same shape, `file:line: message`,
and the program exits with status 70, so one editor rule can jump to either kind:

```
s[0 - 1]     -> p.w:2: index -1 out of bounds for a region of length 3
1 / x        -> p.w:2: divide by zero
n[0]         -> p.w:2: region expected, got a number
t[0] = 'x'   -> p.w:3: write to a literal
```

`+` never turns text into a number, or a number into text: `"5" + 1` is a compile error, where
other languages give you `"51"` or `NaN`. I think that one rule removes most of what makes
dynamically typed languages confusing to learn.

So it isn't a hacker language. It reads like a small teaching language that happens to compile to
native code. The one thing that does feel low-level is the rule at the top of section 3.

## 2. Can it be learned in an afternoon?

The whole language is `SPEC.md` §1 to §12 (leaving out §12.5, the internal `sys` module) and the
README tour. Here's what the afternoon looks like:

| Time | What |
|---|---|
| ~20 min | Values and the one type; `out`; `=`; indentation blocks |
| ~30 min | `if`/`else`, `loop` (three forms), `break`, functions, `return` |
| ~30 min | Regions: text is an array, `len`/`copy`/`find`/`sort`, and `loop x in y` |
| ~20 min | Maps: `{}` is JSON, `keys`/`has`/`len` |
| ~5 min  | `true`, `false`, `null`, `none`: four words, and which of them are conditions |
| ~20 min | The 20 builtins, read once as a table |
| ~30 min | The `fs` / `json` / `txt` / `net` modules: 17 functions in all, and no import to write |
| ~30 min | Contracts (`:before` / `:after`), the one unusual feature |
| ~20 min | Building and running: `word build`, `word run`, `word verify` |

That adds up to about three and a half hours, and there's nothing after it: no second tier, no
generics, no traits, no async, no package manager and no build configuration. What keeps it to an
afternoon is the ceiling of 25 always-available names. Every name in that set is one more thing a
beginner has to learn before they can read a program, and each one looks cheap on its own, so the
ceiling is what stops them adding up. That's why `char`, `decode`, `encode`, `split` and `pad` are
in the `txt` module instead of the always-available set: to keep the number at 20.

## 3. Does it behave the way a newcomer expects?

### A character is its code

```javascript
loop c in "abc"
    out(c)              // prints 97, 98, 99, not a, b, c
```

This surprises nearly everyone. It isn't a bug. There's one type, so a character is a number, and
`s[i]` giving `97` follows from text being a region of numbers. `out(char(c))` prints the letter. It
has to be taught in the first minute, so the README says it in its section on regions, where a
reader would trip on it, and `SPEC.md` §3.4 records the trade. I'm not going to change it.

### Two edges, most likely first

**Assigning text shares it.**

```javascript
s = array(3)
s[0] = 97
t = s
t[0] = 120
out(s[0])              // 120: s changed too
```

That's normal for arrays in most languages and surprising for strings, and in word they're the same
thing. The most common form of the mistake is caught: writing into a string literal faults with
`write to a literal`. Writing into a region you made yourself changes it for every name that holds
it, with no warning. Copying on every assignment would fix that and cost the speed the language is
built for, so I've kept it and documented it. `copy(s)` gives you a region of your own.

**A counted `loop` needs its own counter, and forgetting the increment is a compile error.**

```javascript
i = 0
loop i < 10
    out(i)             // p.w:2:1: this loop cannot end: its body never
                       //   changes 'i', and there is no 'break' or 'return'
```

There's no `for i = 0 to n`. `loop x in y` covers the common case without an index, and the counted
form is for the rest. Forgetting the increment is caught at compile time instead of hanging the
program. The compiler can be sure because a function can't reassign its caller's
local variables, so if the body never assigns a name the condition reads, the condition can't
change. A function can write into a region or a map it's handed, though, so when the condition reads
inside a region or a map, a body with an index store or a call to one of the program's own functions
is left alone (SPEC §10.1). So are `loop true` and any condition that contains a call.

### Printing and division

**`out` prints an array as `[...]`.** `array(n)` marks its region as a JSON array, and a marked
region always prints as compact JSON: `out(array(3))` prints `[0,0,0]`, and an array holding `"ab"`
and `"cd"` prints `["ab","cd"]`. The arrays `json.parse`, `split`, `args()` and `keys` give you
carry the mark too. A region without it, such as a string or a `text(n)`, is printed by looking at
its elements: as text when every element is a character you can see, as `[1, 2, 3]` when they're
all integers and some aren't, and if any element isn't an integer at all (a float, a region, a map,
`true`, `false`, `null` or `none`), the program stops with `not a character` (SPEC §9.1).

**`/` gives the exact answer.** `1 / 2` is `0.5` and `6 / 3` is `2`: `/` answers an integer when
the division comes out even and a float when it doesn't, so it never throws a remainder away.
There's one division. When you want the whole part, write it: `(a - a % b) / b` truncates toward
zero for every sign, and `a >> 3` is the floor of `a / 8`, which is the same answer only when `a`
isn't negative (for `a = -7` they give `0` and `-1`). `out(1 / 3)` prints `0.33333333333333`,
because a float below 1 prints to 14 significant digits (SPEC §2.6 gives the rule for every size).

### What works better than expected

- A question gets a yes or no answer: `1 == 1` is `true`, `has(o, k)` is `true` or `false`, and
  `kind(1 == 1)` is `"boolean"`. There's no C-style "0 means no" to learn, and `if ready == true`
  does what it says.
- A failure has a value of its own. `number("wat")` is `none`, not `0`, so a program can tell "the
  text said zero" from "that wasn't a number", which a `0` for failure can't do.
- `out(0.1 + 0.2)` prints `0.3`, where Python prints `0.30000000000000004`.
- `out(map)` is already JSON. There's no `to_json`, no schema and no marshalling step.
- The remainder of a negative number takes the dividend's sign, as in C: `-7 % 3` is `-1`.
- Bounds are checked, arithmetic overflow (`+`, `-`, `*` and unary `-`) stops the program, and an
  out-of-range literal is a compile error. The exception is `<<`, which checks its shift count and
  nothing else: bits shifted off the top are lost, so `1 << 62` is `-4611686018427387904`
  (SPEC §3.1).

## The tests behind this page

- `dev/toolchain/test_lang.sh` and `dev/toolchain/test_guarantees.sh`: every diagnostic quoted in
  section 1 is in one or the other, checked with its location. `test_guarantees.sh` also has the
  loop that can't end.
- `dev/toolchain/test_gaps.sh`: the run-time faults, and a function that falls off its end without
  a `return`.
- `dev/toolchain/test_txt.sh`: `char` / `decode` / `encode` / `split` / `pad`, and `kind`.
- `dev/toolchain/test_doc_counts.sh`: the builtin count this page gives, in all three places,
  against `builtin_arity` in the compiler.
- `dev/toolchain/test_tmgrammar.sh`: every builtin is in the editor grammar.

No test checks the ceiling of 25 itself. Before adding a name to the always-available set, re-read
section 2.
