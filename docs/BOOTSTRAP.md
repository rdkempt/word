# Bootstrapping word

`word` compiles itself: the compiler, the assemblers and the linkers are all written in `word`
(`compiler/word.w`) and built by `word`. Every self-hosting language has the same problem, which is
that you need some seed to run the first `word` code. This page explains how word handles it without
asking you to trust a binary: the committed binary rebuilds itself byte for byte, and a Python
implementation in `bootstrap/` rebuilds it from the outside.

## The one binary

There is one implementation of the toolchain, the `word` binary committed at the root of the
repository. It's the compiler, the x86-64 and AArch64 assemblers and the ELF, PE and Mach-O linkers,
behind one command line:

```sh
word build [-win|-linux|-arm64|-mac] app.w [-o out]   # compile, assemble and link, in one process
word run app.w [args...]                              # build for this host to a temp file and run it
word asm [-win|-linux|-arm64|-mac] in.s [...] out     # assemble and link hand-written .s files
word format app.w                                     # rewrite app.w in the canonical layout
word verify                                           # rebuild the Linux x86-64 seed, compare it to ./word
word bootstrap [-win|-linux|-arm64|-mac] -o out       # rebuild word from compiler/word.w into out
word version                                          # this binary, and whether it reproduces itself
```

`build`, `asm` and `bootstrap` target the host unless a flag says otherwise, and `run` always does.
Give `bootstrap` an `-o`. Without one it writes `./word` (`./word.exe` for a Windows target), and if
that's the binary you're running, neither Linux nor Windows will let it be replaced, so the command
fails with `cannot write` and a hint to use `-o`.

A normal build touches nothing outside `word`: no Python, no libc, no GNU `as` or `ld`. On Linux
x86-64, `./word build app.w -o app` is all there is to it.

## Why there's a binary in the repo

You can't run `word` source without a `word` toolchain, and you can't build the first `word`
toolchain from source without something that isn't `word`. Every self-hosting language has this
problem. Go's compiler is written in Go and is built with an existing Go, and GCC has to be built
with an existing C++ compiler. The seed has to be one of two things: a compiler written in
another language and kept in the tree, or a prebuilt `word` binary.

word keeps both, because that's what makes the binary checkable. The `word` at the root of the
repository is what you use, and `bootstrap/`, about 5,600 lines of Python, is how you check it.

## The binary rebuilds itself

You don't have to take the committed `word` on trust. It proves it matches the source in the
repository:

```sh
word verify
# word verify: OK - rebuilt word is byte-identical to the committed binary
```

`word verify` compiles `compiler/word.w` for Linux x86-64 (compile, assemble and link, all in word)
and checks that the result is byte-for-byte the file named `word` in the current directory, so you
run it from the root of a checkout. It reads those two files and nothing else, and it builds the
Linux x86-64 seed whatever host runs it. So `word.exe verify` on Windows checks that the Windows
compiler produces the committed Linux seed. It doesn't check `word.exe` itself: that's what
`word version` is for. `version` rebuilds `compiler/word.w` for its own target and tells you whether
the result is the binary you're running.

The `net` library is word source that gets compiled into any program that calls a net verb, so the
compiler has to carry its text. It lives inside `compiler/word.w`, in a region the build lifts out
and embeds when it compiles the compiler, so there's no second copy of it anywhere. That means the
fixed point covers the library too: change a byte of the TLS code without rebuilding and
`word verify` fails, the same as it would for a byte of the compiler.

This fixed point is the main safety check for every change, so run it before every commit. The
`verify` job in `ci.yml` runs it on every push to main and on every pull request that isn't a draft,
and it also checks that `word bootstrap -o` reproduces the committed binary exactly, so a stale
binary can't sit in the repository unnoticed.

What `word verify` can't tell you is that the binary is what the source says it is. The binary is the
thing being asked, so one that had been tampered with could reproduce its own tampered self. That's
Ken Thompson's "trusting trust" problem, and the answer to it is a second implementation.

## Rebuilding the binary from Python (diverse double-compiling)

`bootstrap/` is a complete second implementation of `word`: lexer, parser, analyzer, code generator,
x86-64 assembler and static-ELF writer, written in Python and sharing no code with
`compiler/word.w`. It has one job, which is to rebuild the committed binary from source by a route
that has nothing in common with the binary being checked.

```sh
python3 bootstrap/wordc.py compiler/word.w -o /tmp/word_A   # Python compiles word.w
/tmp/word_A build compiler/word.w -o /tmp/word_B            # word_A compiles word.w
cmp /tmp/word_B word                                        # -> identical
```

That's the whole audit. It needs `python3` and a Linux x86-64 machine: the seed only emits Linux
x86-64, and the second step runs what it emitted. The Python step itself runs anywhere and gives the
same `word_A` (I've checked that on Windows), so on Windows you can run the first step natively and
the other two in WSL. Anywhere else, use a Linux x86-64 VM or container. On my machine the two builds
take about eight seconds. `sh dev/toolchain/test_bootstrap_seed.sh` runs the audit twice (see the
second point below), and `ci.yml` runs that suite in the same job as `word verify`.

Two things to be clear about:

- **`word_A` isn't the committed binary, and isn't meant to be.** It's the same compiler built by a
  different compiler, so its bytes differ. In 1.0.0 it's about 870 KB smaller than `word`, because
  the seed is simpler than the compiler it builds (the differences are listed below) and `word_A`
  doesn't carry the net library, which is about 280 KB of text. What has to match is what `word_A`
  emits, because a compiler's output depends on the source it reads, not on what compiled the
  compiler. That's `word_B`, and `word_B` is byte-for-byte the committed binary.
- **Two independent assemblers get used.** By default the seed assembles and links with its own
  Python code, and `--binutils` sends the same assembly text through GNU `as` and `ld` instead. The
  two routes give different `word_A` binaries, and both of them build the same `word_B`. A bug would
  have to be in both to get through.

The seed is simpler than the compiler it builds. It uses an untagged value model (a word's kind comes
from the address range it falls in, where the compiler uses a tag), one region representation for
`array`, `text` and `bytes`, maps that are searched linearly, and no optimizer at all. The top of
`bootstrap/codegen.py` lists these differences, so that someone reading both doesn't mistake a
simplification for a discrepancy. None of them changes what `word_A` does with `compiler/word.w`,
which is the only program the seed promises to compile.

There's one preprocessing step. The seed removes the `net` library's region from `compiler/word.w`
before compiling it (`_strip_netlib_region` in `wordc.py`), because the library uses parts of the
language the seed doesn't implement, `none` for one. The real compiler doesn't compile that region as
its own code either: its `netlib_embed` lifts the region out and carries the text as data. So
`word_A` doesn't carry the library, and `word_B`, which `word_A` builds from the full source, embeds
it. The audit compares `word_B`, so this changes nothing about what gets checked.

**The seed is frozen at 1.0.** It implements the language as of 1.0 and nothing newer. If a later
`compiler/word.w` uses something the seed doesn't implement, I'll retire the seed to the last tag
where this check passed instead of extending it. Keeping two compilers matched forever is a cost I
don't want this project to carry.

## Four targets from one binary

The one `word` binary builds for Linux x86-64, Linux arm64, Windows x86-64 and macOS on Apple
Silicon. `word build app.w` builds for the host, and `-linux`, `-arm64`, `-win` or `-mac` picks a
target: `word build -win app.w -o app.exe` cross-compiles a Windows PE from Linux, for example. The
`word` linker writes the PE and its import table (`link_pe`), and the compiler emits a Windows OS
layer (`emit_win_os`) whose `w_syscall` shim maps the Linux system calls the runtime makes onto
Win32. macOS gets the same treatment from an `m_syscall` shim. There's no MinGW, no Xcode and no
second compiler.

Each target's build of `word` rebuilds itself byte for byte. On Windows that holds whatever file name
the binary is written to. `windows.yml` checks it natively on a Windows runner (`word.exe version`
and `word.exe verify`, then `version` again under the release's file name, `word-windows-x64.exe`).
On a Linux machine, `dev/toolchain/test_selfhost_win.sh` has `word.exe` rebuild itself under wine,
or through WSL interop when the Linux machine is WSL on Windows (`dev/toolchain/win_runner.sh` picks
the runner). With neither, it checks only the PE's structure. `test_selfhost_a64.sh` does the same
for the arm64 `word` under qemu, and `macos.yml` has the macOS build rebuild itself on an Apple
Silicon runner.

`net` on Windows comes from the same source as everywhere else. The TLS stack is word, carried as
text in `compiler/word.w` and compiled into the program with it, so there's nothing
platform-specific to link. Sockets go through `ws2_32` behind `w_syscall`, the trust anchors come
from the Crypt32 `ROOT` store through `sys.cacerts()`, and the DNS resolver comes from
`GetNetworkParams` through `sys.nameservers()`. Those are the two places the platforms differ,
because Linux keeps both in files and Windows keeps neither there. Windows never looks for them in a
file either: a path that starts with `/` names a file under the root of the current drive, where any
signed-in user can create a directory (`docs/SECURITY.md` §5). `dev/toolchain/test_win_pe.sh` builds
the same fetcher for Linux and for Windows and checks that the PE gets a body of the same length as
the Linux build over HTTP and over HTTPS (a full TLS 1.3 handshake, with the chain verified against
the `ROOT` store), running the PE under wine, WSL interop or Windows itself. One source builds every
target, `net` included. The exception is macOS, where in 1.0.0 every `net` verb answers `none`,
because its OS layer has no socket calls yet (SPEC §15).

**A PE spends about a kilobyte on convention.** In 1.0.0 a hello-world PE is 15,872 bytes: 1,024 of
headers (five sections push the section table 16 bytes past a 512-byte boundary), 10,752 of `.text`,
1,536 of `.rdata`, 2,048 of `.rsrc`, and 512 for a `.reloc` section that holds 8 bytes. The
relocation directory is an RVA and a size in the data directory, and nothing requires it to have a
section of its own. Folding those 8 bytes onto the end of `.rdata` would drop a section, pull the
headers back to 512 bytes and save 1,024 bytes, 6.5% of the file. I don't do it. Relocations anywhere
but `.reloc` is how a packer lays out a file, and looking like a packer is the antivirus-heuristic
problem the import gating (`docs/SECURITY.md` §4) is there to reduce. I'd rather have a normal
section table than the kilobyte.

## Cutting a release

The version lives in one place, `word_version()` in `compiler/word.w`, and it's a constant instead
of something stamped in at build time. A build date or a commit hash in the binary would make two
builds of the same source differ, and `word verify` would stop holding. The cost is that bumping the
version is a source change like any other, so it goes through the bootstrap:

```sh
# 1. edit word_version() in compiler/word.w
# 2. rebuild to the fixed point and commit the new binary
./word build compiler/word.w -o /tmp/w && cp /tmp/w word && ./word verify
git commit -am "1.0.1"
# 3. tag it, signed: the release workflow refuses an unsigned tag
git tag -s v1.0.1 -m "word 1.0.1" && git push origin v1.0.1
```

Do them in that order. Changing the version constant changes nothing the compiler emits, so one
rebuild reaches the fixed point. The release workflow checks that `v` plus `word_version()` equals
the tag before it uploads anything, so a tag pushed ahead of the bump fails the job instead of
publishing a binary that reports the wrong version. `word version` is the number to trust. A Windows
build's version resource, which Explorer and PowerShell show, reads 0.0.0.0, the same as every PE
word builds, because a program declares no version of its own.

**Use `-s`, not `-a`.** The workflow asks GitHub for the tag object and refuses to publish a release
for a lightweight or unsigned tag, so an unsigned tag fails the job instead of producing an unsigned
release. The attestation (below) shows the artifacts came out of this workflow, and the tag's
signature shows the release was started by whoever holds the signing key. Without the signature,
anyone who could push a tag could start one.

Signing has to be set up once, with a GPG key or an SSH key that's already on the GitHub account:

```sh
# GPG
git config --global user.signingkey <key-id>
git config --global tag.gpgsign true

# or SSH, using a key uploaded to GitHub as a *signing* key
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
git config --global tag.gpgsign true
```

If a tag was already pushed unsigned, replace it instead of adding a second one:

```sh
git tag -d v1.0.1 && git push origin :v1.0.1
git tag -s v1.0.1 -m "word 1.0.1" && git push origin v1.0.1
```

A release has one download per target, `word-linux-x64.tar.gz`, `word-linux-arm64.tar.gz`,
`word-macos-arm64.tar.gz` and `word-windows-x64.exe`, plus `SHA256SUMS`. The three Unix targets are
archives because tar keeps the executable bit, and a bare release asset can't. From a public
repository, the release also carries a build attestation for each of those four downloads, signed
with a short-lived OIDC token, which anyone can verify:

```sh
gh attestation verify word-linux-x64.tar.gz --repo rdkempt/word
```

`SHA256SUMS` is only a convenience. The same job writes it and the binaries, so it shows that a
download arrived intact but not where it came from. The attestation is what shows that.

An attestation needs the repository to be public. GitHub offers attestations to a private repository
only on its Enterprise Cloud plan, which a personal account can't have. So while this repository is
private, the workflow skips the attest step instead of failing on it: the release still publishes,
and its notes say it carries no attestation instead of printing the command above. Making the
repository public turns attestation on with no change to the workflow, but not for a release that's
already been cut, because a re-run replays the event that started it, and that event still says
private. To attest a release cut while the repository was private, replace it after going public:

```sh
gh release delete v1.0.1 --cleanup-tag --yes && git push origin v1.0.1
```

The workflow cross-builds all four targets from the one Linux binary in the tagged commit, which is
the claim this project makes, tested on every release. Before it uploads anything, it checks that
the Linux build is byte-identical to the committed `word`, and that the `word` inside
`word-linux-x64.tar.gz` is too and passes `word verify`. So the file someone downloads is the seed
this page is about.

A push to main replaces one rolling `nightly` prerelease instead of minting a version. Its title
names the commit it was built from, and its binaries report whatever `word_version()` says at that
commit, because of the constant above.

## Changing the toolchain safely

`compiler/word.w` is the whole toolchain: the lexer, parser and analyzer, the x86-64 and arm64 code
generators, the x86-64 and AArch64 assemblers, and the ELF, PE and Mach-O linkers. It also holds the
runtime it emits. The rules below are here because breaking any of them gives you a program that runs
and gets the wrong answer, instead of one that fails.

**Verifying a change**

- A change to what the compiler emits, its code generation or its runtime, takes two rebuilds to
  settle. The first rebuild is the new compiler built by the old one, so it still emits the old
  runtime. Only the second is built by the new code generator and carries the new runtime, and a
  third build confirms it by coming out byte-identical to the second. A change that doesn't alter
  what the compiler emits (a message, the version constant, the net library's text) settles in one.
  Rebuild into scratch paths, each round with the one before, until two outputs match, then install
  that and run `word verify`:

  ```sh
  ./word bootstrap -o /tmp/w1
  /tmp/w1 bootstrap -o /tmp/w2
  /tmp/w2 bootstrap -o /tmp/w3
  cmp /tmp/w2 /tmp/w3 && cp /tmp/w2 word && ./word verify
  ```

  Then run the suites.
- `word version` tells you whether a binary matches the source beside it. A stale toolchain fails on
  the first program that uses syntax it predates, and the parse error points at that program instead
  of the compiler.
- `word verify` only exercises the Linux x86-64 back end. For a change to another back end or to the
  runtime, also run `dev/toolchain/test_selfhost_a64.sh`, `test_a64_run.sh` and `test_a64_lang.sh`
  (arm64, under qemu), `test_win_pe.sh` and `test_selfhost_win.sh` (or `word.exe version` on
  Windows), and `test_macho.sh`, which checks the Mach-O writer's structure.
- If you add or change an emitted instruction or data directive, the assembler has to encode it.
  `dev/toolchain/test_encoder_vs_as.sh` compares `word asm`'s x86-64 output with GNU `as`, and
  `dev/toolchain/test_a64_vs_llvm.sh` compares the AArch64 output with `llvm-mc`, each over a corpus
  of instruction forms (`corpus.txt`, `net_corpus.txt`, `a64_corpus.txt`). "Regenerating the corpus"
  in `dev/toolchain/README.md` shows how to find forms a change added.
- The runtime the compiler embeds lives in `compiler/word.w` as `asmput("...")` strings, and there's
  no copy of it anywhere else. `sh dev/toolchain/dump_runtime.sh` (add `-arm64` for the other
  target) prints it as plain assembly when you'd rather read that than the strings.

**The value model**

- **A word-backed region's elements are stored tagged.** A runtime routine that stores an element
  must not untag it first: the count is untagged and the elements aren't. Untagging an element
  before the store halves its value, and nothing faults.
- **The integer 0 is the word `1`.** All-zero bits have the region tag, so `xor rax, rax` as a
  "return nothing" is a null region, not zero.
- **Only routines that know about byte-backed regions handle them.** Anything that walks a region at
  word stride has to test flags bit 0 or call `rt_bytepromote` first.
- **A statically known kind lets code generation skip a runtime check.** Write that guard as "skip
  only for a kind this operation accepts", never as "check only when the kind is unknown", because a
  kind that's known and wrong has to fault too.

**Performance rules that are easy to undo**

- On x86-64, every `cvtsi2sd` needs a `pxor` of its own destination first. Without it, the
  instruction depends on the register's old value, and that false dependency serializes the loop it
  sits in.
- `out` stages its bytes in a 64 KB buffer that lives across calls. Anything that writes to
  `out_fd` directly has to flush that buffer first, or its bytes come out ahead of the staged ones.
  A new runtime routine that can block, or that hands a descriptor to another process, has to call
  `rt_osync` on the way in, or output the program already made waits behind it.
- The owned-temporary rewind (`rt_popregion`) is only safe for an expression that always allocates.
  Never pop a variable, an index load, or anything that can return a value it was handed: the same
  bytes would be handed out twice, and nothing faults when that happens.

**Portability**

- The OS boundary is one call. The runtime's `syscall` becomes `call w_syscall` on Windows, and on
  macOS the arm64 runtime branches to `m_syscall`. When you add a system call, add its case to both
  shims, and gate it on the builtins that reach it, not on the module. A call a shim doesn't map
  answers -1, and a caller that ignores the result reads its zeroed buffer back as a plausible
  answer, such as `random()` or `now()` answering 0.
- Emit a runtime block only for programs that call into it. If a gate is too tight, the linker says
  so with an undefined symbol.

**`SPEC.md` is the source of truth for the language.** Update it with every change.
