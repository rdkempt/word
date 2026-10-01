# The value model

Every `word` value is one 64-bit word, and its kind is in the low bits. Reading the kind takes a
couple of instructions, doesn't depend on where anything is in memory, and works on any word, so no
integer can be mistaken for a pointer. `SPEC.md` §3.6 is the normative description, and this page
describes the representation the compiler emits. `dev/toolchain/test_tag.sh` and
`dev/toolchain/test_float.sh` test it.

## The tag

An integer is stored as `2n + 1`, so its low bit is 1. Every other kind has a 0 there and a 3-bit
tag in the three low bits, which are free because every pointer the bump allocator hands out is
8-byte aligned:

```
  ...1   integer    value = w >>a 1   (arithmetic shift; signed 63-bit)
  ...000 region     w is the pointer itself: deref [w], [w+8] with no masking
  ...010 float      w & ~0b111 points to an 8-byte IEEE-754 double in the arena
  ...100 extension  w & ~0b111 is a boxed cell; [cell] = subkind, 0 = a map (SPEC 3.7)
  ...110 singleton  the payload is the whole word: null 6, false 14, true 22, none 30
                    (SPEC 3.8). No pointer and no allocation, so a compare against one
                    is a compare against a constant.
```

Kind tests are tag arithmetic:

```
kind(x)=="number"  ==  (x & 1) == 1 || (x & 0b111) == 0b010   # int or float
is_int(x)          ==  (x & 1) == 1
is_region(x)       ==  (x & 0b111) == 0b000
is_float(x)        ==  (x & 0b111) == 0b010
```

`kind(x)` is the only kind test the language exposes (SPEC §9). `kind(x) == "number"` compiles to
the test on the first line, and the other three are tests the runtime makes inline, not functions a
program can call. `kind()` tells the three region kinds (`"text"`, `"bytes"` and `"array"`) apart by
the flags word in the region's header, below.

The all-zero word would decode as a null region. That's never a valid region, and no operation hands
one to a program: an operation that fails answers `none` (SPEC §3.8), so a program tests a failed
read with `if body == none`. An integer is 63-bit signed. The parser caps a literal at
`2305843009213693951` (2^61 - 1), and arithmetic whose result runs past the integer range,
`-2^62` to `2^62 - 1`, traps (SPEC §3.1 and §10.2) instead of wrapping. `<<` is the exception: it
checks its shift count, and the bits it shifts off the top are lost.

### Region layout

A region has a header at negative offsets: `[w-16]` is the flags word, `[w-8]` the capacity and
`[w]` the length, and the elements start at `[w+8]`. So `len` and indexing need no untagging on the
hot path. Three bits of the flags word are used. Bits 0 and 1 change how the region is stored and
printed, and `kind()` answers `"bytes"` or `"array"` for them where an unflagged region is
`"text"`. Bit 2 stops writes into the region.

- **Bit 0, byte-backed:** each element is one packed byte, 1x the memory instead of 8x. `fs.read`,
  `bytes(n)`, `bytes("<hex>")`, `encode`, `dir` and the compiler's emit buffer (`sys.asmtake`)
  return one, and a `copy` of one is byte-backed too. `d[i]` still gives an ordinary integer, and an
  operation that works at word stride promotes a byte-backed operand first. Three things differ from
  a word-backed region. A store keeps the low 8 bits of a whole number (`b[0] = 300` reads back
  `44`) and faults on anything that isn't a whole number. `out` and `fs.write` send its bytes as
  they are, where a region of code points goes out as UTF-8. And JSON reads it as UTF-8 text:
  `parse` decodes a byte-backed document, and `stringify` writes a byte-backed string as the
  characters its bytes spell.
- **Bit 1, JSON array:** set by `array(n)`, and on the arrays that `json.parse`, `split`, `args()`
  and `keys` build. `out`, `.` and `stringify` render a marked region as JSON (`[0,0,0]`) instead of
  deciding from its elements. Otherwise it's an ordinary region: an array holding 97 is `==` to the
  text `"a"`, and `len`, indexing, `copy` and `sort` work the same way (a `copy` or a `sort` of an
  array is still an array).
- **Bit 2, map key:** set by `rt_map_set` on the region it keeps when a new key goes in. A map finds
  a key by its contents, so a write through another name that still holds that region would corrupt
  the map (SPEC §3.7). `s[i] = v` tests the bit and faults with `write to a map key`, and an in-place
  append treats the region the way it treats a literal and copies it instead. The test and its branch
  on the indexed store are only emitted for a program that has a map in it, since nothing else can
  set the bit. `copy` doesn't carry the bit, so `copy(k)` is the writable region to work on.

Whatever the flags say, the value is a plain region pointer with tag `000`. A region that isn't
byte-backed, a string literal included, holds one 8-byte tagged word per element (SPEC §3.4).

## Floats

A float is a boxed double: the word has tag `010` and points to an 8-byte IEEE-754 value in the
arena. `json.parse` returns an integer for a whole number in the 63-bit range and a float for
anything with a fraction or an exponent, and also for an integer too big for 63 bits, so untrusted
input never wraps. A number past the double's range makes the whole parse answer `none`.

On x86-64, a float that lives its whole life in one frame slot doesn't need a box. A local whose
every assignment is statically a float holds the raw 64-bit double in its slot, so the inner loop of
a float program runs `mulsd`, `addsd` and `ucomisd` with no allocation. Which locals qualify is
worked out per function by a fixpoint over the kind lattice (from nothing known to integer, region
or float). A second pass, `infer_param_kinds`, joins every call site's argument kinds into the
callee's parameters, and it also carries each function's return kind back to its callers. That's
exact because `word` has no function values and no indirect calls: every call names the function it
calls. A parameter whose callers pass it a map isn't taken for a float, so arithmetic on it faults
when it runs, as it would anywhere else. The arm64 backend has none of this yet and boxes every
float result (SPEC §15).

A parameter proved float is passed as the raw double, and a function proved to return a float on
every path hands its result back raw in `xmm0`. Caller and callee agree because both read the same
row of the same table, computed before any code is emitted. The only reads that take a raw double
from a slot are the ones that consume one, float arithmetic and the assignment store. Every other
read boxes the value, so a value that leaves the frame is always boxed, and a read nobody planned
for is slow but never wrong.

A program with no float literal, no `/`, no `round` or `number` call and no `json` call carries no
float code at all: the float runtime and the unboxing passes are only switched on by those.
`compiler/word.w` isn't such a program. It divides, so a build of it carries the float code.

Each distinct float literal is converted to the nearest double at compile time, and the startup code
stores it in an 8-byte slot, so `mulsd xmm0, [rip+flit0]` reads it directly instead of working it
out again on every evaluation.

## Reclaiming memory on a bump allocator

The arena is a bump allocator with no free list. It can still take memory back where it can prove
nothing else holds it. On x86-64 that's the four cases below. The arm64 backend has only the first,
and keeps everything else it allocates (SPEC §15).

- **No allocation when a value is copied straight out.** `"n=" . i` renders `i` into a static
  scratch region, and the join copies it out from there. Only `rt_join` and `rt_append` use the
  scratch, and each copies out before the next use.
- **Grow in place.** When a region's block ends exactly at the bump pointer, `s = s . x` extends it
  by moving the bump pointer: no new buffer, no copy, and the region's address doesn't change.
- **Pop a temporary the expression owns.** A producer with no shortcut return hands back a region
  nothing else has seen, so when the expression is done with it, and it's still the most recent
  allocation, it's reclaimed by moving the bump pointer back. A `.` join qualifies, and so do
  `copy`, `sort`, `keys` and the readers (`in`, `args`, `env`, `read` and the net verbs). A
  variable, an index load, or anything that can return a region it was handed doesn't.
- **Give back a region a name is about to overwrite.** `t = copy(s, i, 64)` in a loop makes the
  previous window unreachable the moment the new one arrives, so its space is used again, and a
  loop that slices peaks at one window. It takes the same proof as growing in place, and a
  right-hand side that doesn't mention the name and always allocates (SPEC §3.5).

## Singletons

`null`, `false`, `true` and `none` take the `110` tag and are the whole word, not a pointer:
`8i + 6`, so `null` is 6, `false` 14, `true` 22 and `none` 30. Nothing is allocated, and
`x == none` is a compare against an immediate. A comparison turns its 0 or 1 into one of these with
`lea rax, [rax*8 + 14]` after the `setcc` on x86-64, and with `lsl` and `add` on arm64.

Every comparison result goes through `emit_bool` (`a64_bool` on arm64). The other things that
answer a boolean, such as `!`, `&&`, `||`, `has` and `ended`, produce 14 or 22 in their own code.
Every truth test goes through `gen_truth_jump` (`a64_truth_jump` on arm64), the one place that
decides truth: 22 is true, 14 is false, and any other word faults. So `if x`, `&&`, `||`, `!` and a
hook's pass or fail all agree on what `false` means. The compiler knows a comparison's result is a
singleton, not a number, so the arithmetic fast paths never claim it.

## Maps

`{}` takes the extension tag `100` (SPEC §3.7). The value is the address of a four-word cell plus 4:

```
  [cell+0]   subkind     0 = map
  [cell+8]   count       live pairs
  [cell+16]  pairs       one region: key, val, key, val ... in insertion order
  [cell+24]  index       open addressing: slot -> 1 + pair position
```

`keys(o)` reads the pair region at stride two, so insertion order needs no second structure. `==` on
two maps compares keys and values in any order, and recurses through the same `rt_eq` as everything
else, so nested maps compare by content. The kind test is two instructions:
`(w & 0b111) == 0b100`.

## Why `array(n)` touches every page

The number `0` is the word `1`, not machine zero, so a fresh `mmap` page doesn't read back as zeros
to a program: it reads as null regions. So `array(n)` writes every element, which commits the pages
instead of letting the OS reserve them lazily. Allocating a huge array and touching two cells still
pays for the whole thing.
