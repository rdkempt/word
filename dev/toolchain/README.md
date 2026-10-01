# dev/toolchain

Everything word needs to build a program is in the one `word` binary: the compiler, the x86-64 and
AArch64 assemblers, the ELF, PE and Mach-O linkers, and the runtime, all from
[`compiler/word.w`](../../compiler/word.w). `word build app.w -o app` compiles, assembles and links
in one process, and `word asm [-win|-linux|-arm64|-mac] in.s [more.s...] out` runs just the
assembler and linker on hand-written assembly. A normal build runs nothing else: no Python, no GNU
`as` or `ld`.

This directory holds the test suites, their fixtures and drivers, and a few tools for working on
word. Python, GNU binutils, llvm-mc, qemu, openssl, Go and Node show up here as oracles and test
drivers only. None of them is needed to build or run word.

Every `test_*.sh` is described below, grouped by what it checks. Each one prints a summary line at
the end and exits non-zero when something failed. Most take the binary to test from `WORD`
(default `./word`), so `WORD=$PWD/word.exe sh dev/toolchain/test_examples.sh` runs a suite with a
native `word.exe` on Windows.

## Self-hosting and the seed

- `test_selfhost.sh`: `word verify`, the fixed point. word rebuilds itself from `compiler/word.w`,
  and the result has to be byte-identical to the committed `word`. Run it before every commit.
- `test_bootstrap_seed.sh`: the check `word verify` can't make. The Python seed in `bootstrap/`
  compiles `compiler/word.w` into word_A, word_A compiles it into word_B, and word_B has to be the
  committed binary byte for byte. A tampered binary reproduces its tampered self under
  `word verify`, but it doesn't survive this. The chain runs through the seed's own assembler, and
  a second time through GNU `as` and `ld` when they're installed.
- `test_selfhost_a64.sh`: the same fixed point on arm64. The x86-64 word cross-compiles
  `compiler/word.w` to an arm64 word, which rebuilds itself byte-identically (under qemu, or
  natively on an arm64 host), reports itself in step and targets arm64 by default.
- `test_selfhost_win.sh`: cross-compiles `word.exe` and checks it's a PE64 (with objdump, when it's
  installed). Where it can run a PE (natively, under wine or through WSL interop), `word.exe` also
  builds and runs hello, rebuilds itself byte-identically, targets Windows by default, forwards
  arguments through `word run`, and reads CRLF input. With no way to run a PE, only the structural
  check runs.

## The language

- `test_lang.sh`: the broad suite: every CLI subcommand (and the usage and unknown-command paths),
  contracts, located diagnostics, and which parts of the runtime a program carries. It includes
  cross-target checks (`-win` writes a PE, `-linux` an ELF). A few cases need `strace` or Linux and
  skip without them. 529 cases today.
- `test_guarantees.sh`: what the language promises, organized by promise instead of by feature, so
  the places where word makes claims get cases of their own. When a promise gains a clause, it gains
  a case here.
- `test_gaps.sh`: `err()` and `ended()`, the SPEC 10.2 run-time faults (located, exit 70, never a
  signal), the 63-bit boundaries, map keys that aren't text, the 8 MB stack, oversized allocations,
  paths and data reaching the OS as written, pipes whose reader has gone, and a Windows section.
  `ended()` also runs on arm64.
- `test_builtins.sh`: known answers and boundaries for every builtin and operator. `in()` and
  `env()` also run on arm64.
- `test_kinds.sh`: every builtin and kind-sensitive operator handed each of the ten kinds, read back
  from an array element so the run-time check is what runs, and every pair of kinds compared with
  both operands unknown. Every cell has to exit 0 or stop with a located fault, never a signal, and
  x86-64 and arm64 have to agree byte for byte. Without qemu the arm64 side isn't run, and the suite
  doesn't say so. It takes a few minutes.
- `test_tag.sh`: the tagged value model (SPEC 3.6). An integer never aliases a region, including
  `0x600000000000` (the literal pool's base) and integers computed to look like an address.
- `test_txt.sh`: the `txt` module (`char`, `decode`, `encode`, `split`, `pad`) and `kind()`, that
  none of them needs an import, and that a program only carries what it calls.
- `test_json.sh`: maps and JSON: literals, reads and writes, `len`/`keys`/`has`, equality, growth
  past 8 keys, `parse` and `stringify`, malformed input answering `none`, hostile input staying data,
  and JSON arrays through `copy` and `sort`. A parsed number is the nearest double to its digits, on
  both targets.
- `test_float.sh`: float literals with exponents, printing (every digit rounded from the value's
  exact decimal, on both targets), promotion, the `number()` round trip, `round()`, boxing and
  unboxing staying invisible, NaN and the infinities, and a float loop that allocates nothing.
- `test_float_exact.sh`: a float literal is the nearest double. For 34 literals it reads the 64-bit
  constant straight out of the assembly the compiler emits, so word's float printing (separate code
  with its own rounding) isn't involved. Then 186 long literals are built, run and compared with
  Python's shortest repr. The values sit where the format breaks: both ends of the exponent range,
  the largest and smallest normals, subnormals down to the last one, the powers of ten around where a
  double stops holding them exactly, and decimals that can't be represented. Last, the long literals'
  digits, the integers either side of 2^62 and 2^63 and random 17-digit doubles, 420 cases in all,
  go through `number()` and `json.parse` on both targets, which do the same conversion at run time,
  and two literals of a million digits check that an exponent of a million or more is read whole.
- `test_folder.sh`: the SPEC 11 folder model on x86-64 and arm64. Diagnostics and faults name the
  real sibling file (odd and non-ASCII names included), duplicate definitions name both places, the
  other files hold definitions only, and a directory named like a source file isn't read.
- `test_cycle.sh`: a value that contains itself. `a[0] = a` is an ordinary store, and the
  operations split into two groups. The ones that walk the value (`==`, `!=`, `<`, `<=`, `>`, `>=`
  and so `sort`, since SPEC 3.3 orders by content, then `find`, `out`, `.` and `stringify`) have
  nothing finite to walk, and must stop with a located diagnostic instead of crashing or hanging.
  The ones that don't walk it (`len`, `kind`, indexing, `keys`, `has`, a shallow `copy`) must answer
  normally. Every case runs under a timeout with its exit status checked for a signal, and 12 of the
  refusals and 5 of the normal answers run again on arm64, held to x86-64's output and exit status.
- `test_map_alias.sh`: the map-key aliasing matrix. SPEC 3.7 keeps a key's region instead of a copy
  and indexes it by content, so the region is read-only once it's a key, and the question is how
  many ways a program has of reaching that region. 13 rows (the name, `keys(m)[i]`,
  `copy(keys(m))`, `sort(keys(m))`, a key of `copy(m)`, through an array, through another map's
  value, through a function, byte-backed, `json.parse`, nested, a literal, re-keyed) against five
  columns (write, read, append, copy, re-key), plus the for-each variable in the write column. Each
  legal cell checks the map still answers and prints right, a separate pass checks each row's map
  still answers its own keys and round-trips through JSON, and the 13 refusals run again on arm64.
  100 checks.
- `test_alias.sh`: a region two names can reach is never appended in place or handed back to the
  arena. `decode`, `pad` and `number` can return their argument unchanged, and a for-each whose
  body reassigns its subject, or a contract hook that stores a parameter, keeps a second reference.
  `alias/` also holds programs where `len(m)` mustn't be hoisted out of a loop that can add a key,
  and programs that append to a number, an array, a map or `none`. Each program's expected output is
  on its first line. It runs on x86-64, on arm64 (Linux with qemu), and natively on Windows.
- `test_opt_differential.sh`: the optimizer, judged by a second compiler instead of by expected
  answers. `deopt_compiler.py` writes a copy of `compiler/word.w` with the optimizer's gates pinned
  to their conservative answer, and `gen_opt_programs.py` generates programs that put the passes'
  assumptions side by side (an alias made through a call, an alias that only exists inside a nested
  container, a map key that's also a loop subject, a u32 local that overflows). Both compilers build
  each one, and the output and exit status have to match byte for byte. Nothing has an expected
  answer written down, which is what lets there be hundreds of them. Before any comparison counts,
  the patched compiler has to show it's really deoptimized (different assembly for a program whose
  optimizations the suite can name) and still correct (it passes `test_guarantees.sh` and
  `test_builtins.sh`). 200 programs by default, 40 of them also on arm64; `OPT_DIFF_N=5000` for a
  soak. Half the programs have no float in them, since only there do the u32 locals and the rotate
  idiom run. A last program checks the rotate and funnel shapes against python's arithmetic, on
  both targets and with both compilers.
- `test_compile_limits.sh`: the compiler against source that's extreme in shape instead of size.
  It has to finish inside a budget (`LIMIT_SECS`) and either compile, with the program running and
  printing the right answer, or refuse with a located diagnostic on stderr, nothing on stdout and no
  executable. Exit 70, a signal and a timeout are each checked by name: exit 70 is word's run-time
  fault code, so there it would mean the compiler itself faulted. The shapes are seven recursive
  ones 10,000 deep, 2,000 nested `if`s and a 2,000-arm `else if` chain, loops nested 5 to 512 deep
  (and 520, which is refused), left-leaning operator chains (six of 10,000 operands, the exact
  1,024/1,025 limit, constant-folded terms, 250 levels around a 1,000-operand chain), breadth (a
  10,000-pair map literal, a 1 MB string, 200,000 comment lines, a 100,000-character identifier,
  10,000 parameters, 10,000 top-level statements, a 10,000-statement body, a 1,000,000-digit
  literal, 16,600 functions), malformed-and-extreme input, and the file and folder shapes. 48 cases.
- `test_examples.sh`: every program in `examples/` except `https`, which needs the network
  (`test_net.sh` runs it). The small ones are built with `word build` and checked on their first
  line of output, `rpg`, `calc` and `store` are driven through a session, `life`, `sqrt` and
  `inventory` are held to known results, and the tools (`wc`, `find`, `hexdump`, `jsonq`) go through
  `word run` against a fixture. Where they're installed, `wc`'s counts are compared with GNU `wc` and
  `hexdump`'s hex columns with `hexdump -C`. `fetch` is built and its size held under 450,000 bytes,
  but it isn't run.

## Files, memory and randomness

- `test_readall.sh` + `readall_test.w`: `read()` returns the whole file (SPEC 12.1) on both targets.
  The case that matters is a `/proc` or `/sys` entry, whose size the kernel reports as zero while the
  file has content, so a reader that trusts that size gives back an empty region for a file it
  opened fine. The fixture pads the environment so `/proc/self/environ` outgrows the fallback
  allocation several times over, and checks the read comes back longer than 20,000 bytes. The
  padding is checked byte by byte through `env()`, not through what `read()` returned.
- `test_fsdir.sh` + `fspath_test.w`: `dir()` (a FIFO and a 5,002-entry listing over 1 MB among the
  cases), and the path `write`, `read`, `dir` and `rename` hand the OS, checked against what `dir()`
  says was stored: UTF-8 for text, the bytes themselves for bytes, and no file at all for a path
  holding a NUL or longer than the OS takes. Also a `write` to a FIFO whose reader has gone answering
  `false`, `out()` into a closed pipe exiting 141, and `write` and `append` past `ulimit -f`
  answering `false`. On x86-64 and arm64.
- `test_bigio.sh`: about 3 MiB of random bytes go through `write` and `read` unchanged, and
  3,000,000 bytes of mixed one- to four-byte UTF-8 text are written and appended, on x86-64 and on
  arm64.
- `test_output.sh`: `out()` and `err()` come out in call order through the 64 KB buffer `out()`
  fills. A fault writes the finished lines before its message and none of the line that faulted,
  the exit status survives the last write, a prompt reaches a pipe before the program reads, exec
  and `/dev/stdout` see what came first, a terminal gets each line as its `out()` ends, and 100,000
  lines into a pipe are a handful of `write(2)` calls, counted in `/proc/self/io`. On x86-64 and
  arm64, and natively on Windows less the four Linux cases.
- `test_arena_grow.sh`: `text(39000000)`, about 312 MB, is allocated
  and written at both ends.
- `test_arena_reset.sh`: 100 allocations of 80 MB under a 1 GiB `ulimit -v`. With `mark()` and
  `reset()` the loop finishes; without them it has to stop with `out of memory` and exit 70.
- `test_arena_reclaim.sh`: the ways the arena gets memory back (static render scratch, in-place
  append growth, popping owned temporaries, raw-double float parameters, and rewinding what a callee
  left behind, and joining a chain in one go), checked for the right values, five of the runs under
  a 200 MB `ulimit -v`. 30 cases.
- `test_random.sh` + `nogetrandom.py`: `random()` fails closed. The launcher installs a seccomp
  filter that fails `getrandom`, and a program that asks for randomness has to stop with a located
  fault on both instruction sets, while a TLS fetch has to stop before its ClientHello leaves (the
  listener checks it received nothing). python3 installs the filter, so the suite needs no C
  compiler and no root. Its listener is on port 8139, which `test_net_limits.sh` also uses, so don't run the
  two at once.

## Scaling

- `test_sort_scaling.sh`: `sort()` is O(n log n). 200,000 and 400,000 integers each have to sort
  in under 20 s, doubling n may cost at most 300%, and the output has to be in order.
- `test_append_scaling.sh`: `s = s . x` and the join chain `s = s . a . b` stay amortized O(1) per
  append: n = 400,000 and 800,000 each under 5,000 ms, with exact lengths.
- `test_slice_scaling.sh`: a loop that copies windows stays flat in memory. Three loop shapes making
  2 million `copy()` windows have to fit a 400,000 KB `ulimit -v` and give the right sum, and a kept,
  an aliased and a self-slice have to read back intact.
- `test_map_scaling.sh`: inserting and reading back 200,000 and 400,000 keys of three shapes each
  take under 8,000 ms with the right length and sum, and a byte-backed, a joined and a sliced key
  hash alike.
- `test_compile_scaling.sh`: compiling N functions costs about N, whichever way round the call
  graph runs. Chains of 500 and 1,000 functions defined backward, and 1,000 forward, best of three
  builds: doubling may cost at most 300%, and so may backward against forward.

## Backends and binary formats

- `corpus.txt` / `net_corpus.txt` + `test_encoder_vs_as.sh`: the x86-64 encoder oracle. It runs
  word's assembler (`word asm`) over each one-instruction line of the corpus and diffs the encoded
  `.text` against GNU `as`. Relative forms (rip- and label-relative) are skipped, since their bytes
  depend on where things land (word resolves them, `as` leaves a relocation), and so is a line `as`
  refuses. `as` is only a dev and CI cross-check here. Today that's 2,460 matches and 1,772 lines
  skipped. `corpus.txt` holds the forms the compiler emits, plus a few only the encoder or the
  Windows startup uses. `net_corpus.txt` is a wider set of forms, many of which the compiler doesn't
  emit.
- `a64_corpus.txt` + `test_a64_vs_llvm.sh`: the AArch64 encoder oracle: `word asm -arm64` against
  `llvm-mc`, over the corpus plus every one of the 6,636 logical immediates the encoding can express
  (5,334 at 64 bits and 1,302 at 32), and seven values that aren't logical immediates, which have to
  be refused instead of encoded as the nearest legal mask. `llvm-mc` is a dev and CI cross-check
  only.
- `a64_run.s` + `test_a64_run.sh`: the AArch64 backend end to end. word assembles and links an ELF
  and the ELF runs, under qemu or on an arm64 host. This is the half no encoding oracle can judge:
  the wide `mov` sequences llvm-mc rejects outright, the masks whose 64-bit pattern doesn't fit one
  of word's 63-bit integers, the label relocations, the `.align` padding (which is only right if
  walking through it does nothing), and conditional branches too far for their field, which the
  assembler relaxes.
- `a64_lang/` + `test_a64_lang.sh`: the arm64 code generator, checked against the x86-64 one. word
  builds each program in `a64_lang/` for both targets, and the two runs have to print the same bytes
  and exit the same way. The oracle is the other backend, so a new program there is a new test on
  both targets at once. It also checks that net programs (`get`, `post`, `head`) build for arm64. 52
  programs.
- `test_abi_regs.sh`: no runtime function may clobber a callee-saved register (`rbx`, `r12`-`r15`,
  `x19`-`x28`), on either target. It reads what `dump_runtime.sh` prints right now.
- `test_elf.sh`: the ELF container, the counterpart of `test_win_pe.sh`'s header checks: three
  `PT_LOAD` segments (R-X, R--, RW-) in ascending `p_vaddr`, each aligned to 4096 and none both
  writable and executable, and a `PT_GNU_STACK` that's readable and writable and not executable.
  Checked for an x86-64 build, an arm64 build and the committed seed.
- `test_win_pe.sh`: word's PE output: a PE64 from `word asm -win` with kernel32 imports, the
  `build -asm` then `asm` round trip matching `build`, `-win` programs running under a PE runner,
  imports gated by what the program uses, header hygiene and the `.rsrc` contents, live http and
  https fetches compared with the Linux build, and `sys.cacerts()`, `sys.nameservers()` and
  `env()`'s case-insensitive names. The structural checks need objdump, the hygiene checks python3,
  and the runtime cases a way to run a PE, and each part skips without its tool. `ci.yml` runs the
  structural part and `windows.yml` all of it.
- `test_macho.sh`: the Mach-O image `word build -mac` writes, and the reference images from
  `macho_ref.py`. llvm-objdump has to parse every load command, the segment protections have to be
  right with no overlap, there has to be an `LC_MAIN` and a dynamic linker with no `LC_UNIXTHREAD`
  and no dylib, the ad-hoc code signature has to verify over every 4 KiB page and sit inside
  `__LINKEDIT`, `LC_BUILD_VERSION` has to say macOS, and every `bl` into the Darwin syscall shim has
  to keep `x30`. Nothing here can run a Mach-O; `macos.yml`'s Apple Silicon job does that.
- `hostpath.sh`: sourced by the suites that hand paths to a native `word.exe`, and by
  `win_runner.sh`. On Linux and macOS its `hostpath` does nothing; on Windows it turns the MSYS path
  Git Bash hands a script into one `word.exe` can open. Its `wordbin` turns `WORD` into an absolute
  path.
- `win_runner.sh`: sourced by the Windows suites to run a PE, natively when the shell is on Windows,
  or else under wine or through WSL interop.

## The net library

- `crypto_w/` + `test_crypto_w.sh`: known-answer tests for the crypto word implements itself (the
  net library, kept as text in `compiler/word.w`), from one source on both targets. Covered:
  SHA-256, SHA-384/512, HMAC and HKDF, AES, AES-GCM, ChaCha20, Poly1305 and the ChaCha20-Poly1305
  AEAD, X25519, ECDH on P-256 and P-384, big-integer modular exponentiation, RSA verification
  (PKCS#1 v1.5 and PSS), ECDSA on P-256, P-384 and P-521, a DER reader, X.509 parsing and chain
  verification, Base64 and PEM, the TLS 1.3 key schedule, record layer and client handshake (RFC
  8448's recorded traces, including the one where the server asks for a client certificate), DNS
  and HTTP framing. The vectors are published ones or come from an independent implementation:
  openssl, Python's hashlib and `pow`, Python's `cryptography` for the record-layer seals, and
  Python written for the purpose (an ECDSA, the TLS key schedule, a transcription of the ChaCha20
  RFC), which isn't in the tree. The DNS and HTTP vectors are wire bytes built by hand. The arm64
  half runs when qemu is there, and without it nothing says it was skipped.
- `test_tls_surface.sh`: SPEC 12.2's TLS 1.3 surface against the bytes on the wire. SPEC 12.2 gives
  the surface as two tables: what the ClientHello offers (suites, groups, signature schemes and
  extensions), and what isn't implemented. This decodes the ClientHello the client actually encodes,
  and a retry after a HelloRetryRequest, and checks the first table against them in both directions,
  so the SPEC can't claim what the client doesn't send and the client can't send what the SPEC
  doesn't list. Every code the second table lists has to be absent from the wire, and the record
  layer has to accept the suites the first table offers and no others. The bytes come from
  `crypto_w/tls_kat.w`, where `test_crypto_w.sh` pins them against the encoder, so the chain from
  the SPEC to a vector to the implementation has no link that can move on its own. The decoder is
  awk, not word, because a check written in the same language against the same source would only
  restate it.
- `x509_verdict.w` / `x509_verdict.go` + `test_x509_profile.sh`: the X.509 profile, three ways.
  SPEC 12.2 states what word accepts as eight rules, and the six places it differs from the usual
  verifiers. This puts each case to the word verifier, to `openssl verify -purpose sslserver` and to
  Go's `crypto/x509` on the same fixture bytes, and fails if any of the three disagrees with the
  expected verdict. Go is there because openssl is the implementation a hand-written verifier is
  most likely to have been read from, and Go's PKIX code shares no history with it. 60 cases: 59
  three-way verdicts (the six divergences are the eleven cases D1 to D11) and a check that every
  anchor in the host's trust store parses. It needs no root, no socket and no change to the trust
  store, which is what lets it carry a wide matrix where `test_tls_reject.sh` carries the end-to-end
  handful. Two of its cases are defects a self-test wouldn't catch: a chain carrying a critical
  extension word can't process, and a leaf restricted to clientAuth.
- `test_net_w.sh`: a net program builds for x86-64 and arm64 and carries the library, and a program
  with no net call (or only a comment naming one, or a function of its own called `get`) carries none
  of it. Also a build of a bare directory, for `-win`, `-arm64` and `-mac` too, library faults
  reported at the caller's line, and name clashes between a program and the library. No server and
  no network. 20 cases (17 without qemu).
- `test_sockets.sh` + `socket_test.w`: connect, send, recv and close over loopback, on x86-64 and on
  arm64. A closed port answers 0, PING gets PONG, a send to a closed peer answers 0, and the 10 s
  connect deadline is checked when the probe finds a silent peer. Needs python3, and uses the fixed
  ports 51987 and 51988.
- `test_net_verbs.sh`: every verb over `http://` against a Python echo server (`head()` returns an
  empty region, and 2,000 fetches with `mark()`/`reset()` and 4,000 without fit a 200 MB cap), and
  over `https://`: verification is on by default and with `false`, `insecure` set to `true`
  completes every verb, the reason for a failure goes to stderr only, and three CertificateRequest
  cases. The halves skip without python3 or openssl. Fixed ports 4447, 4449 to 4451 and 4481. 20
  cases.
- `test_net_limits.sh`: the bounds a fetch runs under (SPEC 12.2). A peer that accepts and then says
  nothing, a peer that never stops sending, a response that stops short of the length it declared, a
  peer that never answers the handshake (connect() gives up at 10 s, and the suite wants the fetch
  to give up between 8 and 18 s), and a TLS server and a DNS resolver that answer a byte at a time,
  which the 120 s total deadline and the resolver's 5 s budget give up on. Also the 64 KiB ceiling
  on a TLS handshake flight (against a pure-Python TLS 1.3 server), 16 MiB chunked and
  Content-Length bodies under a 512 MB cap, a 40 MiB head that never ends, and nine ServerHello and
  HelloRetryRequest refusals. The same fixture holds the framing a response is read by (interim
  `1xx` responses before the answer, a `101` nobody asked for, `HEAD`, `204` and `304` replies that
  name a length they never send, a `Content-Length` that isn't a length) and the request a URL can
  produce (the `Host` port, a query and a fragment, and a URL that tries to write request lines of
  its own), and the request cases are checked against the bytes the fixture received. The fixtures
  are local, so it needs no root and no internet, except on Windows: a full listen queue there
  refuses a handshake instead of ignoring it, so the unanswered-handshake case goes to 192.0.2.1, a
  documentation address nothing routes. Needs python3, and uses the fixed ports 8137 to 8140. 38
  cases.
- `test_tls_server.sh`: 14 cases against `openssl s_server`: ECDSA and RSA leaves, direct and
  through an intermediate, four HelloRetryRequest cases, three CertificateRequest cases, the retry
  repeating the first random and session id, and plain HTTP and refused ports against a Python
  server. It adds a throwaway root to the host's CA bundle and puts the bundle back after, so it
  needs root (or a private mount namespace), and it skips without openssl or root. Ports 4443 and
  4480.
- `test_tls_reject.sh`: 18 chains against `openssl s_server`, 12 that have to be refused and 6
  positive controls that have to be accepted, with the same throwaway root. `docs/SECURITY.md`
  quotes those two counts, and `test_doc_counts.sh` checks them.
- `test_tls_a64.sh`: a TLS 1.3 handshake run by arm64 code over a real socket. One client, built for
  both targets and held to the same answers against a local `openssl s_server`: both suites, all
  three groups (two of them through a HelloRetryRequest), RSA and ECDSA leaves, a CertificateRequest
  answered with an empty Certificate, the refusals SPEC 12.2 promises, and, with verification on,
  chains under a throwaway root added inside a private mount namespace, never to the host's store.
  Under qemu on x86-64, natively on arm64. Without openssl it fails instead of skipping. Port 48300.
- `test_dns_conf.sh`: where `net` finds its resolver on Linux (macOS reads the same file).
  `dns_server()` takes the first IPv4 `nameserver` line of `/etc/resolv.conf` and falls back to
  1.1.1.1 only when there's none, and `localhost` and every name under it are the loopback address
  without a query. The suite
  runs in a private mount namespace with its own `/etc` (and a network namespace where it can have
  one, for a resolver of its own on port 53 that records every name it's asked), so the host's
  resolver is never touched. Needs root or `unshare`. 23 cases.
- `test_win_netconf.sh`: the same questions on Windows, run natively. A path beginning with `/`
  names the root of the current drive there, and any signed-in user may create a directory at the
  root of `C:`. So on Windows `net` reads neither `/etc/resolv.conf` nor the six PEM bundle paths it
  reads elsewhere: a planted file there would choose the resolver or replace the trust store of every
  program run from that drive. The suite checks the resolver against `Get-DnsClientServerAddress`, fetches `localhost`
  and a name under it from a loopback server, and plants all seven files and a `\proc\self\exe` at
  the root of a `subst` drive, requiring the resolver, the anchor count and `word version` to be
  what they are from the system drive.
- `test_net.sh`: builds `examples/https/https.w` and fetches `api.github.com/rate_limit` over the
  live network (TLS 1.3 and X.509 chain verification in one binary). It passes on any output except
  an empty one or "request failed". It also runs three offline cases, an over-long host, path and
  body, each of which has to fail the call cleanly instead of stopping the program, and fetches an
  8.7 MiB file from a CDN (more than 4 MiB has to arrive), which it skips when the CDN is
  unreachable.
- `test_net_live.sh`: `get()` against 12 independent public hosts, 45 s each. It passes when at
  least 80% of them answer, rounded down (9 of 12).
- `test_top_sites.sh`: an https fetch of the first `TOP_SITES` domains in `top_domains.txt` (100 by
  default, 1000 for a soak), 30 s each. `openssl s_client` sorts every failure into a bucket, and the
  buckets that count against word (and fewer hosts reached than the baseline, 88 of 100 or 808 of
  1000, less a tolerance) fail the run. When more than a quarter of the hosts answer no TLS at all it
  reports NETWORK-UNAVAILABLE and exits 0, unless `TOP_SITES_REQUIRE_NETWORK=1`.

### Fuzzers

A case passes only on the exit status its suite expects. Exit 70 is word's bounds check firing (a
parser indexing past what arrived), 124 is a hang, and anything else is a crash, including the plain
127 Git Bash reports for most Windows crashes. The X.509 and TLS drivers exit 0 whatever their
verdict, and the JSON and DNS/HTTP drivers exit 1 when an answer is wrong.

- `fuzz/` + `test_fuzz.sh` / `test_fuzz_tls.sh`: the decoders that run on bytes a server sends
  before any of them is authenticated. X.509 and DER in the first; the handshake framing,
  ServerHello, HelloRetryRequest, CertificateRequest, the Certificate message, the record layer and
  the client state machine in the second. Certificates minted by openssl, and handshake messages
  built around them in Python, are truncated and corrupted at `FUZZ_OFFSETS` offsets spread over
  each seed (220 for X.509 and 400 for TLS by default, every byte of a seed shorter than that;
  `windows.yml` uses 64), and every mutant has to come back with an answer. Every region access in
  word is bounds-checked, so a decoder that walks off the end stops with `index N out of bounds`
  and exit 70 instead of reading the memory beside it. That's a safe failure, and still a bug.
- `test_fuzz_net.sh` + `fuzz/fuzz_net.w`: the DNS response parser and the HTTP response framing,
  the two parsers a remote party reaches that the TLS fuzzer doesn't. `dns_parse_a` reads a
  resolver's answer before any connection exists (and `dns_conf_line` gets the same inputs, as though
  each were a line of `resolv.conf`), and over `http://` the framing is all there is. Seeds of every
  shape each one branches on are truncated and corrupted, and the driver checks what comes back as
  well as that it came back: an address is four bytes, a head sits inside the response, a body is
  no longer than what arrived and doesn't depend on bytes past the live length, and the chunk walk a
  read loop resumes agrees with a walk from the top (on every prefix up to 2 KiB, then in 64 steps).
  5,522 cases at the default `FUZZ_OFFSETS=160`, and 2,942 at the 64 `windows.yml` uses.
- `test_fuzz_json.sh` + `fuzz/fuzz_json.w`: `json.parse`, which runs on whatever a server sent
  before a program has looked at any of it. SPEC 12.3 says malformed text returns `none`, so a
  fault, a hang or a signal is a bug. For input that does parse, it also checks the round trip is
  stable (parse, stringify, parse, stringify), which catches a renderer writing text its own parser
  won't read back. 1,872 cases. That a parsed float is the same double as the literal, and that no
  value renders as `inf`, are checked in `test_guarantees.sh`.
- `test_fuzz_frontend.sh`: the compiler's own front end, fed truncated, corrupted and re-indented
  copies of every example and every net library module. For arbitrary input there are two
  acceptable outcomes: it compiled, or it was refused with a diagnostic whose first line starts
  `file:line:col:` (SPEC 10.1). A signal, a hang, exit 70 (the compiler is a word program, so that
  means the compiler itself faulted) and a refusal with no location all fail. About 3,500 cases
  (3,486 today; the number of truncations follows the size of the seeds). The cases include an
  unterminated string literal, which mustn't walk the lexer off the end of the source, and which is
  what an editor asks about on every keystroke inside a string.

## The docs, the editor and the suites themselves

- `test_spec_kinds.sh`: the SPEC and the compiler, checked against each other. The kinds
  `is_kind_name` answers are the same set SPEC 9 documents, the lexer's reserved singleton words are
  the same as the grammar's and each has a row in SPEC 3.8, and every documented kind is one a real
  program can actually get, which is the part a grep can't check.
- `test_doc_counts.sh`: the numbers the docs state about this repository are the repository's
  numbers. Every "N lines" claim about `compiler/word.w` in the docs and the suites has to be within
  2% of the file's size without its net library region; `docs/SECURITY.md`'s crypto module count
  and its `test_tls_reject.sh` counts, and `docs/LEARNABILITY.md`'s builtin count (in three
  phrasings), have to match the code; no prose may call the `txt` module `text`; and every module
  the compiler accepts has to be named in the SPEC and in the compiler's unknown-module message.
- `test_doc_examples.sh`: the programs in `README.md` and SPEC 13 (and the SPEC 8.3 hook) are taken
  from the documents as they are, built, and run on x86-64 and on arm64 under qemu, or natively when
  `WORD` is a Windows `word.exe`. A `// value` comment on an `out(...)` line is the output that line
  has to print. Where the text states the output in prose instead, a table in the script pins it,
  with the stdin, arguments and files each run needs, and an example the table doesn't know about
  fails the suite. The README's three network examples are built but not run.
- `test_tmgrammar.sh`: regenerates `editors/vscode/word.tmLanguage.json` with `gen_tmgrammar.sh`
  and compares it with the committed one, checks that every builtin in `builtin_arity` is in it, and
  (with python3) that it's valid JSON that `package.json` points at.
- `gen_lspdata.sh` + `test_langserver.sh`: the language server (`editors/vscode/server.js`), in
  four parts. The table it answers hover and completion from is regenerated and compared, so a new
  builtin can't leave the editor describing last month's language. The set of names comes from
  `compiler/word.w` and the prose from SPEC.md's own builtin tables, so the two can disagree, and
  the suite checks they don't: a builtin the compiler has and the SPEC doesn't is a documentation
  bug. Then `lsp_probe.js` drives the server over real LSP framing (the byte-length framing is the
  part most likely to be subtly wrong, and a unit test would never see it) and makes 53 checks: an
  unsaved edit is what gets compiled, a diagnostic lands on the right identifier and in the right
  sibling file, renaming a parameter doesn't escape its own function, `import` offers exactly the
  closed module list, and more. Four of them run against `compiler/word.w` (about 39,000 lines
  without the net library it carries, the largest word program there is): it compiles clean through
  the server, and an error typed into the buffer is found without the file on disk being touched.
  Last, `test_outline.js` checks the one thing the server decides for itself, what a definition is,
  against an oracle the compiler gives for free: every function becomes an `fn_<name>:` label in
  `word build -asm` output, so the outline of every program in the repo (58 today) is compared with
  the compiler's own list. The ambiguity it guards is that at column 0, `twice(n)` is a definition
  and `out(total)` is a call, and only the indented block underneath tells them apart.
- `test_suites.sh`: two static checks on the suites, since neither problem shows up as a failure.
  No shell function may be called on a line before the one that defines it (the call prints
  `name: not found` and the case never runs), and every `test_*.sh` has to be run by a
  workflow, or by a suite that is. It doesn't check that this README lists every suite.
- `test_bench_harness.sh`: the benchmark harness fails what fails. `bench.sh` is what
  `docs/PERFORMANCE.md` is rendered from, so a failed word run mustn't become a row marked `ok` and
  the answer every other language is checked against. Each way a benchmark can
  go wrong (a run that exits non-zero, a build that fails, a twin with another answer, an answer
  that moves between reps, a failing `gen.w`, a benchmark with no folder) is built as a benchmark of
  its own in a scratch copy of the harness, and held to the exit code and, where it has one, the
  row's label. A setup that can't start is held to being a skip, and the revision line to what the
  tree is, clean or with the changed files named. `compilespeed.sh` and `scaling.sh` are held to the
  same contract through a stand-in word that swaps in a fixture program, stand-in comparison
  compilers on `PATH`, and a scratch `compiler/word.w`. It needs a C compiler and git.

## Tools

- `dump_runtime.sh`: prints the runtime the compiler embeds in every program as plain assembly, for
  reading (`-arm64` for the other target). It lives in `compiler/word.w` as `asmput("...")`
  strings, and no copy is kept in the tree, since a committed copy could fall behind the real one.
  It runs `./word` from the repository root and needs python3.
- `bench_crypto_w.sh`: what the crypto costs, beside OpenSSL on the same machine where one command
  can be pointed at the same bytes (the SHA-256, SHA-512 and ChaCha20 rows; ChaCha20-Poly1305,
  AES-128-GCM, X25519 and P-256 have no OpenSSL column). OpenSSL is hand-vectorized in those rows
  (SHA-NI, AVX2), so none of them isolates the language. The P-256 row also pays for the 30-bit
  big-integer limbs word's 63-bit integers force (X25519 uses 17-bit limbs). The number to watch
  over time is word's own throughput. A dev tool, never part of a build.
- `netlib_cat.py`: prints a module of the net library out of `compiler/word.w`'s NETLIB region, or
  `--list` for their names. The known-answer tests and fuzzers compile the library from that source.
- `gen_tmgrammar.sh` and `gen_lspdata.sh`: write the editor's grammar and its hover and completion
  table (see `test_tmgrammar.sh` and `test_langserver.sh`).
- `top_domains.txt`: the domain list `test_top_sites.sh` fetches.

## What each suite needs, and what a SKIP means

Most of this runs on a bare checkout. Where a suite can't find what it needs, it usually prints
`SKIP` with the reason and exits 0, which is right on a contributor's machine, but it means "the
suite is green" can say less than it looks like. These are the requirements, and the places a
missing one is a failure or passes without a word:

| Needs | Suites | Without it |
|---|---|---|
| nothing | `test_selfhost`, `test_tag`, `test_txt`, `test_guarantees`, `test_compile_limits`, `test_examples`, `test_spec_kinds`, `test_net_w`, the scaling and arena suites, all but one case each of `test_lang` and `test_gaps`, and the x86-64 side of `test_float`, `test_json`, `test_builtins`, `test_kinds`, `test_cycle`, `test_map_alias`, `test_alias`, `test_bigio`, `test_folder`, `test_fsdir` and `test_readall` | |
| python3 | `test_suites`, `test_elf`, `test_float_exact`, `test_abi_regs`, `test_opt_differential`, `test_bootstrap_seed`, `test_doc_examples`, the fuzzers, `test_a64_vs_llvm`, `test_macho`, `test_sockets`, `test_net_limits`, the prompt and terminal cases of `test_output`, and the `in()` and `decode()` case of `test_gaps` | skip |
| python3 | `test_crypto_w`, `test_tls_surface`, `test_doc_counts`, `test_x509_profile`, and one case each in `test_lang` and `test_gaps` | fail |
| python3 and Linux seccomp | `test_random` | skip |
| openssl | `test_fuzz`, `test_fuzz_tls`, `test_x509_profile` (its fixtures and the first oracle), the https half of `test_net_verbs`, `test_tls_server`, `test_tls_reject` | skip |
| openssl | `test_tls_a64` | fail |
| go | `test_x509_profile`'s second oracle | it runs word against openssl alone, and says so |
| node | `test_langserver` | skip |
| qemu (`qemu-aarch64-static` or `qemu-aarch64`) | `test_a64_run`, `test_a64_lang`, `test_selfhost_a64`, `test_tls_a64`, and the arm64 half of the two-target suites | skip, except `test_kinds`, `test_crypto_w`, `test_builtins`, `test_gaps`, `test_folder`, `test_net_w` and `test_fsdir`, which drop the arm64 half without saying so |
| llvm-mc | `test_a64_vs_llvm` | skip |
| llvm-objdump | `test_macho` | skip |
| GNU `as` and `objcopy` | `test_encoder_vs_as` | skip |
| GNU `as` and `ld` | `test_bootstrap_seed`'s second chain | skipped, and it says so |
| objdump | the structural checks of `test_win_pe` and `test_selfhost_win` | skip |
| a way to run a PE (Windows, wine or WSL interop) | the rest of `test_win_pe` and `test_selfhost_win` | skip |
| a C compiler and git | `test_bench_harness` | fail |
| root (or `unshare`) | `test_dns_conf`, `test_tls_server`, `test_tls_reject`, and `test_tls_a64`'s verified-chain cases | skip |
| Windows, natively | `test_win_netconf` (`subst` and `powershell`, both stock, and python3 for its loopback server) | skip anywhere else |
| the real network | `test_net`, `test_net_live`, `test_top_sites` | see below |

Several suites listen on fixed local ports: `test_sockets` (51987, 51988), `test_net_verbs` (4447,
4449 to 4451, 4481), `test_net_limits` (8137 to 8140), `test_random` (8139), `test_tls_server` and
`test_tls_reject` (4443, 4480) and `test_tls_a64` (48300). Two runs that share a port on the same
machine fail each other, and on Windows with WSL a listener inside WSL counts, since WSL forwards it
to Windows' loopback.

Three suites depend on something outside this repository. `test_net` fails when it can't reach
api.github.com, though it skips its CDN case when the CDN is unreachable. `test_net_live` passes
while 9 of its 12 hosts answer, so one outage doesn't fail it and a systemic break does. `test_top_sites`
holds a baseline of hosts reached, less a tolerance, and treats a network with no TLS at all as
unavailable instead of failed (it needs openssl to sort its failures, and without it they all
count). In `ci.yml`, `test_net` and `test_net_live` are informational and
`test_top_sites` gates; in `windows.yml`, `test_net` and `test_top_sites` gate and `test_net_live` is
informational.

`ci.yml` installs llvm and qemu-user-static, and fails if `as`, `objcopy`, `llvm-mc`,
`qemu-aarch64-static`, `node` or `go` is missing. python3 and openssl come with the runner and
aren't checked, and neither are root and seccomp. `windows.yml` fails if python3, openssl or go is
missing.

## Workflows

There are five, in `.github/workflows/`.

| workflow | runs on | when |
|---|---|---|
| `ci.yml` | `ubuntu-latest` | a pull request that isn't a draft, a push to `main`, or by hand |
| `windows.yml` | `ubuntu-latest`, then `windows-latest` | a pull request that isn't a draft, a push to `main`, or by hand |
| `macos.yml` | `ubuntu-latest`, then `macos-14` | a pull request that isn't a draft, or a push to `main`, when either touches one of its paths; or by hand |
| `bench.yml` | `ubuntu-latest` | a push to `main` that changes more than the benchmark output, or by hand |
| `release.yml` | `ubuntu-latest` | a `v*` tag (a release), a push to `main` (the rolling nightly), or by hand |

In a private repository every Actions minute is billed, Windows at twice the Linux rate and
macOS at ten times it with a one-minute minimum. Three rules keep that down:

- `ci.yml`, `macos.yml` and `windows.yml` take `push` only on `main`. Otherwise a branch with an
  open pull request would run each of them twice for one commit, once for the push and once for the
  pull request. Every other branch is covered by its pull request, once it isn't a draft.
- Every job has a `timeout-minutes`: 25 for `ci.yml`, 15 for each `macos.yml` job and for
  `windows.yml`'s cross-build, and 30 for the native Windows job, the benchmarks and the release.
  Without one, a stuck job runs to the six-hour default.
- `ci.yml`, `macos.yml` and `windows.yml` each have a `concurrency` group, so pushing to a pull
  request again cancels the run on the older commit instead of finishing the whole suite on it.
  `main` never cancels, so every merge gets its own result.

`macos.yml` is a workflow of its own instead of a job in `ci.yml` because GitHub filters paths per
workflow, not per job. Its paths are `compiler/word.w` (the Mach-O emitter and the Darwin syscall
shim), the committed `word`, the four macOS files here (`test_macho.sh`, `macos_runtime.w`,
`macho_ref.py`, `macos_net.w`) and `macos.yml` itself: what decides whether macOS will load the
image word writes, which is signed ad hoc and loaded by dyld with no dylibs. A documentation change
doesn't pay for an Apple Silicon runner. Its Apple Silicon job also runs the crypto vectors, the
socket test and a local TLS handshake, which depend on files the filter doesn't list
(`test_crypto_w.sh`, `crypto_w/`, `test_sockets.sh`, `socket_test.w`, `netlib_cat.py` and
`dev/benchmarks/netserve.py`), and net isn't available on macOS in 1.0.0, so the socket test and
the handshake can't pass there yet. Start it by hand from the Actions tab when you want it anyway.

## Running the checks

```sh
sh dev/toolchain/test_selfhost.sh        # the fixed point: run before every commit
sh dev/toolchain/test_bootstrap_seed.sh  # the Python seed rebuilds the committed binary
sh dev/toolchain/test_lang.sh            # the language, broadly
sh dev/toolchain/test_guarantees.sh      # the language's promises, by promise
sh dev/toolchain/test_kinds.sh           # every builtin against every kind, both targets (slow)
sh dev/toolchain/test_examples.sh        # every example builds and runs
sh dev/toolchain/test_doc_examples.sh    # README and SPEC 13 examples print what they say
sh dev/toolchain/test_doc_counts.sh      # the numbers the docs state are the repo's numbers
sh dev/toolchain/test_suites.sh          # every suite is run by a workflow
sh dev/toolchain/dump_runtime.sh         # read the embedded runtime as assembly
```

Every other suite above runs the same way, `sh dev/toolchain/<name>.sh`, from the repository root
or anywhere else, since each one finds the root from its own path.

## Note on branch relaxation

word's x86-64 encoder always emits near jumps: a conditional jump is always `0F 8x` with a 32-bit
displacement, and `jmp` and `call` are `E9` and `E8` with one too. GNU `as` uses the short (rel8)
forms where it can. Both are correct, but it makes whole-program layouts differ, which is why the
oracle compares one instruction at a time, skipping relative forms, instead of whole `.text` blocks.
A relaxation pass for x86-64 would match `as` and shrink the output, but correctness doesn't need
one. The arm64 backend does relax: a conditional branch reaches 1 MB either way, so one that can't
reach its target becomes the inverted branch over a plain `b`, in `word build -arm64` and
`word asm -arm64` alike.

## Regenerating the corpus

`corpus.txt` and `net_corpus.txt` are lists of distinct instruction forms, one per line, with no
labels and no directives. They aren't a dump of everything a program emits. After a codegen change,
dump the assembly and look for forms they don't already cover:

```sh
word build -asm examples/https/https.w \
  | sed 's/#.*//' \
  | grep -v '^\s*\.' | grep -v ':\s*$' | grep -v '^\s*rep\b' \
  | sed 's/^\s*//; s/\s*$//' | grep . | sort -u > /tmp/emitted.txt
```

The result still holds about 80 `label: .directive` lines (like `arena_base: .space 8`), since the
filter only drops a label on a line of its own, so ignore those. Add anything new to `corpus.txt`: a
new mnemonic, a new operand shape, a new operand size, or a register the encoder handles differently
(r8 to r15 need a REX prefix, and rsp and r12, or rbp and r13, as a base take other encodings). Leave
out the thousands of lines that differ only by an ordinary register or a frame offset.
`test_encoder_vs_as.sh` assembles each line of the corpus with both `word asm` and GNU `as` and
diffs the bytes, so a form that isn't in the corpus is a form nothing checks.
