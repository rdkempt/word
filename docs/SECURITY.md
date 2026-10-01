# Security

word's largest attack surface is its TLS 1.3 client, which is written from scratch in word itself:
the `net` library, carried as text in `compiler/word.w` and compiled into any program that fetches.
The code a remote server reaches (the DNS and HTTP response parsers, the TLS handshake decoders, the
X.509 parser and chain verification) is bounds-checked by the language, fuzzed, and tested against
certificate chains it has to refuse. What the verifier accepts is a profile written out in SPEC
§12.2 and checked case by case against openssl and Go, not a claim of general PKIX conformance.
Memory safety rests on a bounds check on every region access, a tagged value model, and the
compiler's proof that nothing else holds a region before the runtime reuses its memory. Programs
get heap ASLR and W^X on every target, and the ELF states that its stack isn't executable. The build
is reproducible and checks itself, a release tag has to be signed, and a tagged release is attested
when the repository is public (§9).

Nobody else has audited it. It doesn't check certificate revocation. It doesn't implement name or
policy constraints, so it refuses every certificate that carries one. Its AES-GCM uses lookup tables
on every CPU, and its RSA and NIST-curve code isn't constant time. It has no post-quantum key
exchange. The literal pool sits at a fixed address in writable pages, and the Linux executable isn't
position-independent. Those are real, and they're below with everything else.

Every defence here names the test that holds it.

## What is tested, and by what

| Surface | Test | What it would catch |
|---|---|---|
| X.509 and DER parsing | `test_fuzz.sh`: about 4,400 mutated certificates through the parser, the host match, the signature check and the chain walk | a length field walking the parser off the end of a region |
| TLS handshake decoders | `test_fuzz_tls.sh`: about 11,000 mutated messages through the handshake framing, the ServerHello and HelloRetryRequest parsers and the checks made on them, the CertificateRequest and Certificate parsers, record decryption and the client state machine | the same, one layer earlier, where nothing has been authenticated yet |
| DNS and HTTP responses | `test_fuzz_net.sh`: 22 seed answers and responses, truncated, corrupted and stretched into about 5,500 cases | a resolver's or a server's reply read past its end, before any certificate is involved |
| JSON parser | `test_fuzz_json.sh`: seed documents, truncations, byte corruptions and structural abuse | a malformed payload that faults, hangs, or doesn't survive the round trip |
| Chain verification | `test_tls_reject.sh`: 12 chains that must be refused, 6 positive controls, each served by openssl's `s_server` | a non-CA certificate signing another, an expired or not yet valid certificate, a name mismatch, a pathlen violation, an unprocessed critical extension, a `clientAuth`-only leaf, a leaf whose `keyUsage` doesn't allow signing |
| The X.509 profile, compared | `test_x509_profile.sh`: every rule of SPEC §12.2's profile and each of its six divergences, put to word, openssl and Go's `crypto/x509` on the same bytes, and a count of the host's own trust store (60 cases in all) | a verifier that's right about signatures and wrong about what a certificate is allowed to do |
| Network bounds | `test_net_limits.sh`: peers that never answer, stall, trickle or never stop sending; a body short of its declared length; a head that never ends; a 16 MiB chunked body under a memory cap; ServerHellos and HelloRetryRequests the client has to refuse; a thirty-digit `Content-Length`; URLs that try to carry a header | a fetch with no deadline or ceiling, a truncated body passed off as whole, or a handshake the client should have refused |
| Where the resolver and the anchors come from | `test_win_netconf.sh`, natively on Windows: the resolver against `Get-DnsClientServerAddress`, `localhost` fetched from a loopback server, and all seven Unix paths planted at the root of a `subst` drive. `test_dns_conf.sh`: `resolv.conf` parsing, and a resolver of its own that must never hear of `localhost` | a Windows program taking its resolver or its whole trust store from a file any signed-in user can create, or a lookup of `localhost` sent to a DNS server |
| The ELF word writes | `test_elf.sh`: W^X `PT_LOAD` segments and a non-executable `PT_GNU_STACK`, on both instruction sets and on the committed seed | a writable and executable segment, or a stack permission left to the loader's default |
| The PE word writes | `test_win_pe.sh`: W^X sections, the NX and ASLR flags with the relocation directory they need, a computed checksum, the 8 MB stack reserve, the imports each feature brings in, and CPUID asked before `rdrand` | a PE that loads writable code, loads at a fixed base, or imports what it can't call |
| Reusing memory | `test_alias.sh`: programs that reach one region two ways, on both backends and natively on Windows | the runtime growing or giving back a region something else still holds |
| Kinds at every boundary | `test_kinds.sh`: every argument of every builtin and `sys` verb against every kind, on both backends | a primitive that trusts an argument's kind: a number read as a pointer, or raw bytes written over a region's tagged words |
| Handshake against a real server | `test_tls_server.sh`: openssl with ECDSA and RSA leaves, direct and via an intermediate, a HelloRetryRequest, a CertificateRequest the server insists on and one it doesn't | anything that only works against itself |
| Crypto primitives | `test_crypto_w.sh`: known answers for 18 of the net library's 19 modules, on x86-64 and arm64 and natively on Windows. They're published vectors where a standard has them (FIPS 180-4 and 197, RFC 7748, 8439 and 8448 among them), values openssl produced for the rest of the crypto and for the certificates, and hand-built cases for DNS and HTTP. The 19th module is `net` itself, which the local-server suites run, so all 19 modules are tested | a primitive that's subtly wrong, or wrong on one target only |
| Interop | `test_net_live.sh`: twelve independent public hosts | a client that only talks to one stack |
| Reach, as a number | `test_top_sites.sh`: the top 100 (or 1,000) domains fetched, and every failure classified against openssl | what a fixture suite can't see: a trust store that shrank, a handshake a strict server rejects, a profile rule stricter than the web |
| The toolchain itself | `word verify` (a byte-identical rebuild), `test_encoder_vs_as.sh` (about 2,400 instructions against GNU `as`, byte for byte, and lines `as` refuses that word has to refuse too), `test_a64_vs_llvm.sh` (the AArch64 encoder against llvm-mc) | a miscompile, or an encoder that disagrees with GNU `as` or llvm-mc |

## 1. Threat model

- **The design point is a trusted author and trusted input.** You write a word program and run it on
  your own machine. There, word is about as safe as C with mandatory bounds checks: most mistakes
  stop the program with a file and line number instead of corrupting memory.
- **The risk is in untrusted input.** Two parts of word read bytes someone else chose: the TLS and
  HTTP client (a remote server, or anyone in the network path), and to a lesser degree the compiler
  and assembler (if you build source you didn't write). Both are written from scratch in word, where
  every region access is bounds-checked.
- **Not done:** no outside audit, no sandbox and no stack canaries. Fuzzing is done on every network
  decoder (`test_fuzz.sh`, `test_fuzz_tls.sh`, `test_fuzz_net.sh`), on the compiler front end
  (`test_fuzz_frontend.sh`) and on `json.parse` (`test_fuzz_json.sh`).
- **Exploit mitigations:** heap ASLR (the arena's base is randomized on every run, on every target)
  and W^X. The ELF loads as R-X text, R-- read-only data and RW data; the PE has the same split
  across `.text`, `.rdata` and `.data`, with NX_COMPAT and DYNAMIC_BASE set and a relocation
  directory so the loader honours them; the Mach-O splits its segments the same way. Two things stay
  at fixed addresses: the literal pool, whose pages are writable (§3), and on Linux the program image,
  because the ELF isn't position-independent (§4).
- **Four targets, one source.** The same source builds Linux x86-64 and AArch64 (static ELF),
  Windows x86-64 (PE) and macOS on Apple Silicon (Mach-O). `test_elf.sh` checks the ELF's
  mitigations on both instruction sets, `test_win_pe.sh` the PE's, and `test_macho.sh` the Mach-O's
  segment permissions. Linux x86-64 has the most testing behind it, because that's what the test
  machines run, and Windows is tested natively (§10). On macOS, `net` doesn't work in 1.0.0 (§10).

## 2. Memory model

word has one value type, a 64-bit word, and its kind is carried in the word as a low tag: a number
sets the low bit, and the pointer kinds share a 3-bit tag in the bits their 8-byte alignment leaves
free (SPEC §3.6). On top of that:

- **Every region access is bounds-checked.** `p[i]` and `copy` fault with `index out of bounds` for
  anything outside the region. There's no pointer arithmetic in the language, so a program can't
  make an out-of-bounds reference the way C can.
- **Operations that need a kind check it.** Arithmetic, indexing, conditions, `len`, `out`, `.`
  (join) and comparisons check at run time that their operands are what they need, wherever the
  compiler can't prove it, and fault otherwise.
- **There's no `free` a program can call.** The arena is a bump allocator. The runtime still gives
  memory back in a few places, by moving the bump pointer back over an allocation the compiler has
  proved nothing else holds: an argument temporary nobody keeps, a region a name is about to
  overwrite, and an append that grows the most recent region in place (SPEC §3.5). So the absence of
  use-after-free rests on that proof. The proof doesn't assume a builtin returns a fresh region,
  since `decode`, `pad` and `number` can hand back their argument. `test_alias.sh` checks it with
  programs that reach one region two ways, on both backends. The other exception is `reset()`,
  which frees whatever was allocated after a mark, whether or not something still holds it (§4).

All of this rests on the kind test being sound, which is what the tagged value model is for (§3).

## 3. The value model

A word's kind is a low tag carried in the word itself. A number sets the low bit. The other kinds
use the three low bits that 8-byte alignment leaves free: `000` for a region, `010` for a boxed
float and `100` for a boxed extension (the map), each a pointer, and `110` for the four singletons
(`null`, `false`, `true` and `none`), where the whole word is the value and there's no pointer at
all. So `is_region(w)` is `(w & 7) == 0`, and no integer can carry a region's tag however large it
is. A number can't be read as a pointer, and that follows from the representation, whatever
addresses integers happen to land on. What it rules out is an attacker-influenced number reaching a
sink like `out(x)` or `x[i]` and being dereferenced as a region. That would have been a read at
worst, since word has no indirect calls driven by data.

The cost is described in `VALUE_MODEL.md` and SPEC §3.1. A number spends one bit on the tag, so
integer values are 63-bit, from -2^62 to 2^62 - 1. A written literal is capped lower, at 2^61 - 1
(SPEC §2.6), and larger values are reachable by arithmetic up to the 63-bit limit. Past that limit,
arithmetic traps (§8). The other cost is that `array(n)` and `text(n)` fill their cells when they're
made, because the number 0 is the machine word 1, so a large untouched array commits its pages
instead of reserving them.

`dev/toolchain/test_tag.sh` guards the model: it sweeps a thousand address-valued integers and checks
that every one reads as a number, and it checks a region nested in a region and the exit status.
The 63-bit bounds and the overflow faults are tested in `test_gaps.sh`, `test_builtins.sh` and
`test_json.sh`.

The heap is at an unpredictable address: on every target the arena is mapped at a base chosen at
random on each run (§4), so a memory bug elsewhere has to get past heap ASLR. The literal pool isn't.
It stays at `0x600000000000`, because literal addresses are built into the code as absolute
constants. It holds only compile-time constants, but its pages are mapped read-write and stay that
way. What stops a program writing to a literal is the runtime's own check, which faults with
`write to a literal` (SPEC §10.2). Nothing at the page level backs it up, so a bug in the compiler or
the runtime that wrote through a literal's address would change the literal instead of faulting
(SPEC §15).

## 4. Arena and allocator

- **The arena's base is randomized, on every target.** The arena holds every dynamic allocation,
  which is all the data an attacker can influence. Each run maps it at a random base within 256 GiB
  above the literal pool: page-aligned with 26 bits of entropy on Linux (x86-64 and AArch64), 64
  KiB-aligned with 22 bits on Windows (VirtualAlloc's allocation granularity), and 16 KiB-aligned
  with 24 bits on macOS (Apple Silicon's page size). The entropy comes from `getrandom` on Linux,
  `getentropy` on macOS and the `rdrand` instruction on Windows (a hardware generator that needs no
  import), each mixed with the stack pointer's own ASLR, so the base still varies if the generator
  fails. On Windows the runtime asks CPUID before it runs `rdrand`, because on a CPU without RDRAND
  the instruction is illegal and the program would die before `main`. Without RDRAND, the stack's
  ASLR is the only entropy.
- **Two things are at fixed addresses.** One is the literal pool, at `0x600000000000` and writable
  (§3). The other is the program image on Linux: the ELF is a non-PIE executable loaded at
  `0x400000`, so its writable data and bss, which hold the arena's base and bump pointer among the
  runtime's other state, are at fixed addresses too. Heap ASLR hides the arena and does nothing for
  those two. A PE is moved by Windows' ASLR and a Mach-O is slid by dyld, so neither image has this
  problem.
- **An allocation can't wrap, and growth can't overwrite.** A count of 2^40 elements or more is
  `out of memory` before it becomes a size, in `array`, `text` and `pad` alike, so a byte size
  can't wrap to a small block that the zero fill then runs past. The arena grows by the whole
  shortfall in one mapping that won't replace
  an existing one (`MAP_FIXED_NOREPLACE`; a VirtualAlloc at an occupied address fails the same way),
  and it never spans more than 16 TiB, so no request walks it over whatever lies above. macOS has no
  no-replace flag, so there growth maps with `MAP_FIXED`, inside the same cap and in the `0x60...`
  window that nothing else on macOS uses.
- **W^X on every target.** The Linux executable loads as three page-aligned segments (R-X text, R--
  read-only data, RW data and
  bss), so no page is both writable and executable. The arena is mapped RW and never executable, and
  the compiler builds a target's code in the arena and writes it to a file without ever running it
  there, so nothing needs a page that's both. The Mach-O has the same split (`__TEXT` r-x,
  `__RODATA` r--, `__DATA` rw-).

  The ELF also says its stack isn't executable, with a `PT_GNU_STACK` program header (flags RW,
  nothing mapped). Leaving it out wouldn't be neutral: a loader that finds no `PT_GNU_STACK` falls
  back to a target-dependent default (GNU ld documents it that way), and `checksec` and the
  distributions' hardening checks treat a missing header as a defect for that reason. word emits no
  code onto the stack, so the header costs 56 bytes and settles the question.
  `dev/toolchain/test_elf.sh` checks it along with the segment permissions, on both
  instruction sets and on the committed seed.

  The Windows PE has the same split: `.text` RX, `.rdata` R (literals, import
  descriptors, the IAT), `.data` RW with `.bss` as its virtual tail, plus `.rsrc` R and `.reloc`.
  `DllCharacteristics` is `0x8160` (HIGH_ENTROPY_VA, DYNAMIC_BASE, NX_COMPAT and
  TERMINAL_SERVER_AWARE). NX_COMPAT is what makes the split mean anything at run time, and the two
  ASLR bits are honoured only because a relocation directory is present. It's an empty block,
  because nothing in the image refers to the image by an absolute address: every reference the code
  generator emits is rip-relative, and every import goes through the IAT. Without the directory the
  loader ignores DYNAMIC_BASE and the image loads at its preferred base every time.
- **Windows imports follow what the program can reach.** Each import is behind the flag for the
  feature that reaches it (`args()`, `env()`,
  `exec`, `writex`, reading files, writing or renaming them, `dir()`, stdin, `random()`, `now()`,
  the socket verbs and `net`), so a hello world declares six: `GetStdHandle`, `GetFileType` (to see
  whether its output is a console), `WriteFile`, `GetLastError`, `VirtualAlloc` and `ExitProcess`.
  That's less to audit, and less for an antivirus heuristic to draw conclusions from. A program
  that uses the socket verbs directly doesn't import `BCryptGenRandom` or `GetSystemTimeAsFileTime`
  unless it asks for randomness or the time, and `test_win_pe.sh` checks it.
- **The PE carries a checksum and a manifest.** The `CheckSum` is computed, because a zero one is one
  of the oldest packer tells there is. The manifest declares `requestedExecutionLevel asInvoker` (so
  Windows' installer detection can't decide a program called `update.exe` wants elevation),
  `longPathAware`, and `activeCodePage` UTF-8. The last one is as much for correctness as for
  hardening: word calls the ANSI entry points, and without it they use the legacy code page.
- **A built program doesn't carry its build path.** The runtime's fault prefix holds the source
  file's name only, so a binary leaks no compile-time path: no user name, checkout layout or CI
  token. Compile errors still show the path.
- **A fetch keeps its memory, and that brings in `reset()`.** The arena has no `free`, so a fetch
  keeps everything it allocated (SPEC §12.2). A plain `http://` fetch keeps about 7.6 KB besides its
  response, and `dev/toolchain/test_net_verbs.sh` holds 4,000 of them inside a 200 MB cap with no
  `sys` in the program. An `https://` fetch keeps more: on Linux x86-64 I measured about 113 KB a
  fetch to `https://example.com/`, and verifying the chain adds nothing to it. Each verified fetch
  reads and parses the whole trust store again, but it rewinds the arena over the store before it
  returns. Still, a program that polls for long enough runs out of memory, and SPEC §12.2 tells a
  loop that fetches without end to wrap each fetch in `mark()` and `reset()`. That puts ordinary
  programs within reach of an unsafe primitive.
- **`reset()` is an opt-in use-after-free.** `mark()` answers how many 8-byte words of the arena are
  in use, and `reset(m)` frees everything allocated since, by moving the bump pointer back. A region
  created after the mark is dangling after the reset, and using it reads or writes memory that later
  allocations own. The bounds check doesn't protect that access, because it reads the region's own
  header, and after a reset the header can belong to something else. What `reset()` does check is
  its argument: a whole number from 0 up to the count in use now, and anything else faults with
  `index out of bounds`. Because the mark counts words, any value it accepts leaves the next
  allocation 8-byte aligned, so a made-up mark can't knock a region off its tag. SPEC §12.5
  documents both as unsafe.
- **The net library uses `mark()` and `reset()` itself.** Every program that fetches runs 20 mark
  windows inside the bundled library: in the hashes, the bignum, RSA and ECDSA arithmetic, X25519,
  the two AEADs, the TLS key schedule and record sealing, the loop that collects the server's
  handshake flight, which runs on bytes nobody has authenticated yet, and the chain check, which
  gives back the trust store it parsed. Each window is written so that what it hands back is
  allocated before its mark or survives its reset. The flight loop, for one, leaves the loop without
  resetting once the flight is complete, so its result stays. That's trusted code: a region escaping
  one of those windows would be a dangling reference on the remote attack surface, and no test
  checks for that directly.
- **Running out of memory is a denial of service.** The arena grows on demand. Its one fixed ceiling
  is the 16 TiB span (above), which keeps growth from walking over other mappings and is far past
  any machine's memory. A single request larger than the OS will map or commit is refused at once as
  `out of memory` (exit 70) on every target. Gradual growth ends differently: on Linux the OOM killer
  usually ends the process first (SIGKILL, with no message), and on Windows the commit fails once
  the commit limit is reached, which gives the same clean `out of memory`. So a program, or input
  that drives its allocation, can exhaust memory. I think that's the right trade, since the
  alternative is an artificial cap on real use.

## 5. TLS 1.3 and X.509, written from scratch

This is the most security-relevant code in the project, and the part a remote attacker reaches. It's
the `net` library, word source carried as text in `compiler/word.w` and compiled into any program
that calls `get`, `post`, `put`, `delete` or `head`.

- **The decoders are word, and that changes how they fail.** The DNS and HTTP response parsers, the
  TLS record and handshake layer and the X.509 and DER parser all read whatever a server sends (or
  anyone in the path, up to certificate verification). Hand-written ASN.1 with manual lengths has a
  long history as a source of memory-corruption CVEs, because a length field the parser believes
  becomes a pointer the parser follows. Here it can't: every region access is bounds-checked by the
  language (SPEC §10.2), so a decoder that trusts a length too far stops with `index N out of bounds`
  instead of reading the memory next to the buffer. That turns memory corruption into a denial of
  service, but for the whole program: the fault ends it with exit 70, and word has no way to catch a
  fault, so one hostile server stops a crawler or a poller at the first bad response. That's why the
  fuzzers below count exit 70 as a failure.
- **The DER reader is strict**, because a lenient one can be made to disagree with the issuer.
  `der_read` rejects what DER rejects: the indefinite length form, a long form used for a length the
  short form could hold, a length with a leading zero byte, a length whose bytes run past the end of
  the enclosing value, and a tag number that needs more than one byte. `der_read` and `der_expect`
  copy nothing: a parsed value is a tag, an offset and a length into the buffer it came from, and the
  offsets are bounded by the value that contained them. The few values that have to outlive the
  parse (a signature, a key, an INTEGER) are copied by `der_slice` into regions allocated at exactly
  their length, so there's no fixed-size destination to overflow.
- **The response body is decoded strictly too.** A body comes back as text, and only well-formed
  UTF-8 decodes: an overlong form, an encoded surrogate or a value past U+10FFFF passes through as
  the bytes it is (SPEC §12.2).
- **Every decoder a server reaches is fuzzed.** `dev/toolchain/test_fuzz.sh` mints real certificates
  (RSA-2048 and RSA-4096, P-256, P-384, Ed25519) with openssl, truncates and corrupts them at
  offsets spread across each file, and drives every mutant through `x509_parse`, `x509_match_host`,
  `x509_check_sig` and the chain walk, the same entry points a server's certificate reaches.
  `dev/toolchain/test_fuzz_tls.sh` does the same for what runs before those: the handshake framing,
  the ServerHello and HelloRetryRequest parsers and the checks made on them, `tls13_parse_cert_request`,
  `tls13_parse_certificate`, record decryption, and the client state machine that drives them.
  `dev/toolchain/test_fuzz_net.sh` covers the two parsers that come first of all: `dns_parse_a`,
  which reads a resolver's unauthenticated answer before any connection exists, and the HTTP
  response framing, which over `http://` is all there is between a server and the caller. It checks
  what comes back as well as that something did: an address is four bytes, a body is no longer than
  what arrived, and the chunk walk a read loop resumes agrees with a walk from the top. Each mutant
  has to be rejected by returning, and a hang, a signal or a bounds fault is a failure. To make sure
  the fuzzers aren't vacuous, I removed a bound and ran them. Without the content-length check in
  `der_read`, `test_fuzz.sh` reported 1,450 bounds faults, and without the body-length check in
  `tls13_hs_body`, `test_fuzz_tls.sh` reported 2,367.
- **Path validation checks more than signatures.** Checking only each link's signature is an
  authentication bypass: any ordinary end-entity certificate, the kind anyone can get for a
  domain they own, could sign a certificate for any other name. openssl calls it `error 79: invalid
  CA certificate`. Every issuer on the path has to carry `basicConstraints` with `cA TRUE`, can't
  declare a `keyUsage` without `keyCertSign`, has to be inside its validity dates, and has to have a
  `pathLenConstraint` that leaves room for the intermediates beneath it. The leaf has to be in date
  as well, and its names have to cover the host, through an `iPAddress` SAN for a request to a
  literal address. `dev/toolchain/test_tls_reject.sh` serves each of those chains from
  openssl's `s_server` and requires a refusal, with positive controls so that a client which refused
  everything would fail the suite too.
- **The two rules about extensions.** A chain can be correctly signed at every link by a trusted
  root, in date, with the right name, and still be one no verifier should accept. There are two
  ways that happens.

  The first is a certificate carrying a critical extension word doesn't process. RFC 5280 §4.2
  doesn't make that optional: a system that uses certificates has to reject one carrying a critical
  extension it can't process. word refuses it, and openssl refuses the same chain with `error 34:
  unhandled critical extension`.

  The second is a leaf whose `extendedKeyUsage` says `clientAuth` and not `serverAuth`, a
  certificate its issuer has limited to acting as a client. word refuses it, and openssl with
  `-purpose sslserver` refuses it with `error 26: unsuitable certificate purpose`.

  Neither is a cryptographic failure, which is what makes them easy to miss. "Is this chain valid?"
  isn't the question a TLS client has. Its question is "is this certificate allowed to be this
  server?". The two rules are slots 20 and 21 of a parsed certificate, enforced by `x509_path` on
  every certificate on the validated path (the leaf, and each issuer above it that the peer sent).
  Certificates the peer sent that aren't on the path are ignored, as SPEC §12.2 rule 8 says.
  `test_tls_reject.sh` (N9, N10, N11) and `test_x509_profile.sh` (C1, C2, E1 to E4) have the
  cases.
- **Name and policy constraints are refused, critical or not.** word doesn't implement name
  constraints, policy constraints or inhibit-any-policy, so a certificate carrying any of them is
  refused whether the extension is marked critical or not. RFC 5280 says a CA must mark name
  constraints critical, but some constrained sub-CAs don't, and a verifier that skipped a
  non-critical one would let an intermediate that excludes `.profile.test` vouch for
  `word.profile.test`, which openssl and Go both refuse. The price is that a
  constrained CA is refused even when the chain satisfies its constraints, where openssl and Go
  accept it (one of the divergences below).
- **An anchor's own signature is not a link.** No signature algorithm older than SHA-256 is
  implemented, so a leaf or an intermediate signed with SHA-1 is refused: the link can't be checked,
  and an unchecked link isn't a link. A trust anchor's self-signature is different. RFC 5280 §6.1.1
  makes the anchor an input to path validation, a name and a key that are already trusted, and
  openssl and Go don't check its self-signature either. So a certificate whose `signatureAlgorithm`
  nothing here verifies still parses, as a scheme of its own, and `x509_check_sig` has no case for
  it, so the refusal happens at the link, where the security property is. That matters because
  `net_load_roots` keeps only what parses, and an anchor that didn't parse would simply be missing.
  On Windows, whose ROOT store is small, the oldest anchors are self-signed with SHA-1, MD5 or MD2:
  19 of the 53 anchors on the machine I measured, including `GlobalSign Root CA`, three DigiCert
  roots and `AAA Certificate Services`. `https://example.com/` and `https://cloudflare.com/` need
  them there, where Linux's PEM bundle has a newer self-signed root for the same chains.

  On an anchor, word checks `cA TRUE`, the validity dates and the `pathLenConstraint` (SPEC §12.2
  rules 2 and 4). It doesn't check the self-signature, the `keyUsage`, the `extendedKeyUsage` or
  the critical extensions. Two things follow. An anchor whose `keyUsage` leaves out `keyCertSign`
  still anchors a chain, where openssl and Go refuse it; that's a place word accepts more than they
  do, and `test_x509_profile.sh` has no case for it yet. And an anchor with no `basicConstraints`
  (an old version 1 root, say) parses but can never anchor anything, and nothing reports it. On the
  Windows machine I measured, 6 of the 56 anchors in ROOT were like that. The Linux bundle had none.

  Some certificates still don't parse at all: one whose own key isn't RSA, P-256, P-384, P-521 or
  Ed25519 (an Ed448 or brainpool key, say). As the leaf, such a certificate fails the handshake.
  Anywhere else in the server's chain it's left out, and the chain is judged without it. In the
  trust store the anchor is lost. An RSA-PSS signature whose parameters leave the hash at its SHA-1
  default isn't in that list: it parses, as an algorithm word doesn't verify.
  `test_x509_profile.sh` holds the algorithm cases
  (S1 to S6, D8, D9) and counts the host's own trust store: every anchor the platform offers has to
  parse, because an anchor lost at the parse is a fetch that fails with no message to explain it.
- **The profile is in the SPEC, and checked against two other implementations.** SPEC §12.2 states
  its eight rules as a table, so "verifies the certificate chain" isn't left to interpretation, and
  lists six places where the profile gives a different answer from openssl or Go. In five of them word refuses a chain one or both of them accept: `anyExtendedKeyUsage` doesn't
  stand in for `serverAuth`; a certificate with `nameConstraints` is refused even when the chain
  satisfies them, critical or not, and so is one with a non-critical `policyConstraints`; a leaf
  whose `keyUsage` leaves out `digitalSignature` is refused even when it allows `keyEncipherment`; a
  `keyUsage` with no bits in it is refused; and a link signed with SHA-1 is refused, which openssl
  still verifies at its default security level. In the sixth, word accepts what openssl refuses: a
  certificate in the trust store is an anchor whether or not it's self-signed, as it is for Go,
  where openssl wants `-partial_chain`. `dev/toolchain/test_x509_profile.sh` puts every rule and
  every divergence to word, to openssl and to Go's `crypto/x509` on the same bytes, 60 cases in all,
  and fails if any of the three gives a different verdict from the one recorded for it. Go is there
  because openssl is the implementation a hand-written verifier is most likely to have learned
  from, and Go's PKIX code shares no history with it, so a case all three agree on is one that three
  independent readings of RFC 5280 agree on.
- **DNS follows the host, and that's a trust decision.** The resolver is the one the host names: on
  Linux and macOS the first `nameserver` line in `/etc/resolv.conf` that holds an IPv4 address, read
  the way glibc reads it, and on Windows the first IPv4 server the OS lists through
  `GetNetworkParams` (the `sys` primitive `nameservers()`, SPEC §12.5). 1.1.1.1 is used only when
  the host names no IPv4 resolver, and that includes a host whose resolvers are all IPv6 (an
  IPv6-only network, or a local `nameserver ::1`): there every lookup leaves the machine, and
  internal names don't resolve. Resolving names the way the rest of the machine does is the right
  default, since it covers internal and split-horizon zones, but it means a host with a hostile
  resolver can steer where a connection goes. The resolver can't forge the certificate at the other
  end, so the worst it can do is deny service or point you at a server that then fails
  verification. `localhost` and every name under it are `127.0.0.1`, answered without a query (RFC
  6761 §6.3), so no resolver is asked a name only this machine can answer, or told what a program on
  it is connecting to. The hosts file isn't read. Queries go over UDP and are asked again over TCP
  when the answer comes back truncated or doesn't come, and the answer is parsed with the same
  length discipline as everything else here and fuzzed by `test_fuzz_net.sh`, because a resolver's
  answer is unauthenticated too.
- **On Windows, `net` reads no Unix path.** `/etc/resolv.conf` on Windows is `\etc\resolv.conf` on
  whichever drive is current, and the root of `C:` lets any signed-in user create a directory
  (`icacls C:\` grants Authenticated Users `AD`). If `net` read that file for its resolver, or the
  six PEM bundles `net_ca_paths` lists for its trust store, any local user could create
  `C:\etc\ssl\certs\ca-certificates.crt` and become the only trust anchor of every word program run
  from `C:`, whoever ran it, and choose its resolver too. So the `sys` primitives `cacerts()` and
  `nameservers()` answer `none` where the store is a file (Linux, macOS) and a region where the OS
  provides it (Windows), and where the OS provides it, no file is read, first or as a fallback. An
  empty ROOT store fails closed, and an empty resolver list falls to 1.1.1.1. `word version` on
  Windows doesn't read `/proc/self/exe` either. It asks for the running image (`sys.image()`,
  through `GetModuleFileNameW`), so it judges the binary that's running however it was started, by a
  bare name through PATH included. `test_win_netconf.sh` plants all seven files and a
  `\proc\self\exe` at the root of a `subst` drive, shows they're readable at those paths from there,
  and requires the resolver, the anchor count and the version to be what they are from the system
  drive.
- **Every fetch has deadlines and ceilings.** SPEC §12.2 gives them as a table: 10 s to connect,
  30 s idle, 120 s for the whole fetch with the TLS handshake included, 64 KiB for the server's
  handshake flight and 64 MiB for the response. A response short of its declared length is a
  failure, not a short body. `test_net_limits.sh` puts each one to a peer that stalls, trickles or
  never stops sending.
- **No revocation, by choice.** OCSP and CRLs aren't implemented, so a revoked certificate is
  accepted while it still chains to a trusted root and is in date. I decided against classic OCSP:
  it puts a synchronous network round trip in front of every connection, tells the CA which sites
  you visit, and every mainstream client soft-fails it anyway, so it stops nobody who can already
  intercept the traffic. Chrome dropped it in 2012. The version I'd want is OCSP stapling, where
  the server brings the proof and there's no extra round trip or privacy leak, and that's a
  reasonable thing to add later. Until then, a certificate that was compromised and then revoked is
  accepted for the rest of its validity period.
- **Timing side channels, including one that's worse than it would be with AES instructions.** The
  crypto is written to be correct against test vectors, not to run in constant time, and word source
  has no way to reach AES-NI or PCLMULQDQ. So AES-GCM runs a table-driven S-box on every CPU, and
  the classic S-box cache-timing attack applies on every machine, however new. GHASH reads
  two tables of its own: sixteen multiples of H as a 64-word region (512 bytes, eight cache lines),
  indexed by a nibble of the value being multiplied, and sixteen reduction words (128 bytes, two
  lines), indexed by a nibble of the running product. They're there for speed, not hardening: a
  table lookup in place of a branch on each bit of the operand is a cache channel instead of a
  branch channel, and one observed line of the larger table gives away three of a
  nibble's four bits. The tables are built from H, so what they could leak is the authentication
  key, not the encryption key.

  The AES S-box stays a 256-byte byte region (four cache lines) and won't become a T-table. Folding
  MixColumns into it is the usual next speed step, and I measured it at 1.25x on the mode, but it
  buys that with an 8 KiB table indexed by a state byte, the textbook cache-attack target (Bernstein;
  Osvik, Shamir and Tromer). It would be worse here than in the literature, because a word region
  holds 8 bytes per element: a 256-entry table spans 32 cache lines, twice what C's 4-byte entries
  take, so one observed line pins five bits of the index, one more than in C. I've decided against
  it for good.
  ChaCha20-Poly1305 has no tables, and it's the suite offered first for that reason as much as for
  speed.

  The RSA code isn't constant time. Neither is the P-256 and P-384 key exchange a server gets by
  asking for it in a HelloRetryRequest: it uses the signature verifier's double-and-add, whose
  running time follows the bits of the client's secret scalar. That scalar is used for one
  handshake only, which limits what a timing observer can do with it. The X25519 ladder is the one
  primitive written to be constant time, with a masked swap in place of a branch. The AEAD tag
  checks and the Finished check are fine: each XORs every byte of the difference together and
  branches once at the end, so neither is a forgery oracle. For a client this is lower risk than for
  a server, but it isn't hardened.
- **What the signature side covers.** Certificate signatures are checked for RSA PKCS#1 v1.5,
  RSA-PSS (with its hash and width as parameters) and ECDSA on P-256, P-384 and P-521, over SHA-256,
  SHA-384 or SHA-512. A handshake's CertificateVerify has to be RSA-PSS, or ECDSA on the leaf key's
  own curve. RFC 8446 §4.4.3 doesn't allow PKCS#1 v1.5 there, and word aborts a
  handshake that uses it, as OpenSSL, BoringSSL and Go do. The ClientHello offers only schemes
  this code can verify. All of it is checked against published vectors and real certificates
  (`dev/toolchain/test_crypto_w.sh`), EC trust anchors included. Ed25519 is recognized and not
  verified: `x509_sigalg` decodes the OID and `x509_check_sig` has no branch for it, so an
  Ed25519-signed certificate is refused. That fails closed, and it's also a gap, because a
  chain a browser accepts won't verify here. A scheme nothing implements always fails closed
  (`get()` answers `none`), and keeping up with new ones is ongoing work.
- **The TLS surface is stated in the SPEC.** SPEC §12.2 gives it as two tables: every cipher suite, group,
  signature scheme and extension the ClientHello offers, and a list of what's absent (PSK and
  resumption, 0-RTT, `KeyUpdate`, client certificates, ALPN, OCSP stapling, TLS 1.2, post-quantum key
  exchange). `dev/toolchain/test_tls_surface.sh` decodes the ClientHello the client actually sends
  and fails if it and those tables disagree either way, so what follows is commentary on a surface
  that's pinned elsewhere.
- **Ciphers and key exchange.** word offers two of the three TLS 1.3 AEADs,
  `TLS_CHACHA20_POLY1305_SHA256` first and then `TLS_AES_128_GCM_SHA256` (the RFC 8446
  mandatory-to-implement suite), negotiated per connection. `TLS_AES_256_GCM_SHA384` isn't offered.
  Key exchange sends an X25519 key share and lists secp256r1 (P-256) and secp384r1 (P-384) beside
  it, so a server that wants a NIST curve asks for one with a HelloRetryRequest and gets it. Before
  answering a retry, the client checks it the way RFC 8446 §4.1.4 asks: `legacy_version` 0x0303, no
  compression, `supported_versions` naming 0x0304, a cipher suite it offered, the session id it
  sent, and a group it offered and hasn't already sent a share for. The ServerHello after a retry
  has to use the retry's suite, and every ServerHello has to echo the client's session id (RFC 8446
  §4.1.3) and has to arrive as one whole message in its record. A P-256 or P-384 point from the
  peer is checked to be on the curve and in range before any scalar multiplication, because an
  invalid-curve point is how a peer talks a careless implementation into leaking its private
  scalar. **There's no post-quantum hybrid key exchange.** Someone recording traffic today to
  decrypt later with a quantum computer isn't defended against here, and that's the largest known
  gap in this list.
- **The `insecure` escape hatch.** For an endpoint whose certificate this verifier can't check (a
  self-signed certificate, or an Ed25519 chain), `get(url, true)` (SPEC §12.2) skips certificate
  verification. The connection is still encrypted, but the peer isn't authenticated, and anyone in
  the middle can read and change it. It has to be written into the call, it's never the default, and
  plain `get(url)` always verifies. Nothing is printed when it's used, so for threat modelling, treat
  any call with `insecure` set as `http://`. It doesn't help with a leaf the decoder can't parse,
  which fails the handshake either way.
- **Trust anchors come from the OS.** Verification is against the system trust store, read at run
  time. On Linux and macOS that's the PEM bundle at the first of `net_ca_paths` that holds a
  certificate that parses, and on Windows it's the Crypt32 ROOT store, through `cacerts()`, with no
  file read at all. Nothing is built in. A host with no readable bundle, or an empty ROOT store, has
  an empty trust store, which authenticates nothing and makes every verifying request fail: the safe
  direction, and a failure you'll notice. On Windows, ROOT holds only the roots the machine has
  already needed. Windows downloads the rest of Microsoft's root program on demand through its own
  chain engine, which word doesn't call, so a site whose root hasn't been fetched yet fails in word
  while a browser on the same machine reaches it. That's part of why fewer of the top 100 domains
  verify on Windows (83) than on Linux (88).

**The bottom line for TLS.** It's fine for talking to endpoints you control, and for learning how TLS
works end to end. For fetching from the ordinary internet it's reasonable: certificates are verified
properly, the chains that should be refused are refused, and every decoder a server reaches is
bounds-checked and fuzzed. What it hasn't had is an outside audit, and until it has, I wouldn't use it
where the cost of a remaining bug is high.

## 6. Compiler and assembler

If you compile or `word asm` source you didn't write, that input is untrusted too.

- **The compiler's working lists grow as they need to.** The token list, the indentation stack, the
  assembler's lists and its label table all grow. The only fixed capacity is three stated limits,
  each a compile error with a line number: 256 levels of nested expression, 512 of nested block and
  1,024 operators in one chain (SPEC §10.1). A scope holds any number of names. The front
  end is fuzzed by `test_fuzz_frontend.sh`, but fuzzing isn't proof, and for a service that compiles
  source it didn't write, a limit someone can reach is still a denial of service.
- **The x86-64 assembler refuses what it can't encode.** Operands are parsed strictly, and each
  instruction's operand kinds, sizes and immediate ranges are checked before a byte is written.
  Anything else is refused with a `wasm:` line that quotes the instruction, and no output file is
  written. Its encodings are checked against a foreign assembler: `test_encoder_vs_as.sh` compares
  about 2,400
  instructions with GNU `as`, byte for byte, and requires the lines `as` refuses to be refused. The
  16-bit forms of `mov`, the ALU instructions, `test`, the shifts, the one-operand instructions,
  `imul`, `push` and `pop` assemble; other 16-bit forms are refused.
- **The AArch64 assembler is less strict.** Its encodings are checked against llvm-mc
  (`test_a64_vs_llvm.sh`), but it still reads an immediate leniently, so `mov x0, #12abc` assembles
  as `mov x0, #12`.
- Practically, you compile your own code, so this is a lower priority than the network path. But
  "compile this untrusted `.w`" isn't a safe service to offer.

## 7. Syscalls and capabilities

- **No libc.** On Linux and macOS every OS interaction is a raw system call. On Windows it's a
  direct call into the system DLLs (kernel32, ws2_32, bcrypt, crypt32 and iphlpapi) through a shim
  that maps the Linux calls onto them, and each import is there only for a feature the program uses
  (§4). On macOS dyld maps the image, but it loads no library. Nothing from a third party is linked,
  which also means every OS interaction is word's own code.
- **Powerful primitives, no sandbox.** `exec` runs any program and `write` writes any path. A word
  program has the full authority of the user running it, like any C program.
- **Sockets are six typed primitives, not a general syscall.** `connect` (four IPv4 bytes and a
  port), `udp`, `timeout`, `send`, `recv` and `close` are the whole transport. Each is a short,
  fixed sequence of socket calls (`socket`, `connect`, `setsockopt`, a read, a write, `close`),
  emitted by the compiler the same way on every target, which is how the TLS client in the net
  library reaches the network without knowing which OS it's on. Every argument is checked before any
  of those calls: a socket, a port and a timeout have to be whole numbers, and an address or a
  buffer has to be a byte-backed region, so `recv` can't write raw bytes over a region's tagged
  words and `send` can't write those words out. I decided against a general `syscall(n, ...)`
  primitive: it would make every word program a possible arbitrary-kernel-call program, and the
  reachability argument below would come down to "trust the source". Named primitives stay
  auditable, and the generality given up is generality no ordinary program should want.

  `udp` and `timeout` are there because DNS needs them. `udp(ip, port)` is `connect` with
  `SOCK_DGRAM`, which does no handshake,
  so `send` and `recv` work on the result unchanged, with no address on every call. `timeout(fd, ms)`
  sets `SO_RCVTIMEO` and `SO_SNDTIMEO`, and without it a peer that accepts a connection and then
  says nothing would hang the program forever. `connect` puts a ten-second deadline on its own
  handshake the same way (`SO_SNDTIMEO` on Linux, `TCP_MAXRT` on Windows), because a program has no
  socket to give `timeout` until `connect` has returned one. Name resolution isn't among them: DNS
  runs in word above `connect`, so the primitive never takes a hostname.
- **There's no source-level capability manifest.** Module functions resolve on first use (SPEC §12),
  so nothing makes a program declare at the top what it can reach. A required `import` line wouldn't
  have been an enforcement boundary either, since nothing stops a program writing it, and reading the
  calls is what tells you what a program can do.
- **The binary-level one exists, and it's the stronger of the two.** The compiler emits a module's
  runtime only for a program that calls into it, and the call is the gate, not the import line. A
  program that never calls `net` contains no socket or DNS code and no HTTP request
  template, so there's nothing for a scanner (or an attacker with a code-reuse gadget) to find, and
  `word build -asm` shows exactly what a binary carries. The same goes inside `sys` and `fs`: the
  emit buffer, `writex`, `exec` and the sockets are four pieces, each emitted only for a program
  that calls into it, and the file writer (with `rename`) only for a program that writes, appends or
  renames. So a net program carries no `execve` and no file writer, and a program that only calls
  `exec` carries no sockets. `test_lang.sh` checks what each kind of program carries, on all four
  targets. This comes from the emit gating and isn't a
  sandbox: a program that does call a module has that module's full authority.

## 8. Integers

`+`, `-` and `*` are checked: a result past the integer range stops the program with
`file.w:N: integer overflow` and exit 70, instead of wrapping into a wrong answer. `MIN / -1` and
`MIN % -1` stop with the same fault, and division by zero stops with `divide by zero`.

The bitwise operators work on the value's two's-complement bits and don't check the result, since a
64-bit mask, or a shift that drops high bits, is the reason to use them. The assembler's `parse_num_r`
relies on that to build immediates above the integer range. So `1 << 62` is
`-4611686018427387904`, and `x << 1` can give a wrapped value where `x * 2` would trap. The shift
count is checked: one outside 0 to 63 is a fault (`shift out of range`), because masking it to six
bits, as the hardware does, would be a surprise (SPEC §3.1). Either way this isn't a memory-safety
issue, since the value model keeps the result a number, never a region (§3).

## 8a. `json.parse`

`json.parse` is in the same position as the X.509 decoder (§5): a parser whose input usually came
off the network. It's much smaller and simpler (no crypto and no length-prefixed framing), but the
rule is the same: a malformed payload has to fail as data, and never crash the program.

- **It reads RFC 8259 and nothing else.** Anything that isn't JSON is `none`: a bare `-`, a leading
  zero, a `.` or an `e` with no digits after it, an escape JSON doesn't have, a raw control character
  in a string, and a number past the range of a double.
- **Depth is capped at 1000.** The parser is recursive, so nesting depth is stack depth, and without
  a cap `[[[[...` a couple of million deep would overflow the stack. Only objects and arrays count,
  so a document exactly 1000 deep parses, and past that `parse` returns `none` like any other syntax
  error. `json.stringify` shares the counter, which turns a cyclic structure (`m["self"] = m`) from
  a segfault into a clear `json: value nests too deeply (a cycle?)` fault.
- **The exponent is clamped.** `1e999999999` would otherwise scale the mantissa a billion times. The
  combined exponent, the written one plus the shift the digits themselves make, is clamped at 400,
  where the answer is already past a double's range (so `none`) or 0.
- **A lone surrogate becomes U+FFFD.** `"\ud83d"` with no low half isn't a character, and `encode`,
  `write` and a `post` body stop the program on one (`not a character`). Substituting the
  replacement character keeps a malformed payload from being a remote kill switch. A well-formed
  pair combines into the single code point word stores.
- **Every cursor read is bounds-checked** against the source length and returns -1 past the end,
  which every loop treats as a syntax error.
- **Everything is arena memory**, so a parse that fails part way leaks (there's no `free`) instead
  of corrupting anything, and §4 applies unchanged.

`dev/toolchain/test_fuzz_json.sh` fuzzes it: seed documents are truncated and mutated, then
structural cases cover deep nesting, malformed escapes, huge payloads and invalid UTF-8. Its input is
simpler than DER's, but fuzzing isn't an audit, and all this claims is that those malformed inputs
fail as data and don't crash the program.

## 9. Supply chain

- **The committed `word` binary is a reproducible seed that checks itself.** `word verify` rebuilds
  it from source and checks the result is byte-identical. `ci.yml` runs it on every push to main and
  on every pull request that isn't a draft.
- **A second implementation rebuilds it.** `bootstrap/` (Python, sharing no code with word) rebuilds
  the same binary from source by an independent route, and `ci.yml` runs that too
  (`dev/toolchain/test_bootstrap_seed.sh`, `docs/BOOTSTRAP.md`). A tampered binary reproduces its
  tampered self under `word verify`, but it doesn't survive this diverse double compilation. That's
  stronger provenance than most projects offer.
- **The release path is pinned, signed and attested,** because everything above is about the source
  and says nothing about how a download was made:
  - Every `uses:` in `.github/workflows/` names an immutable commit SHA, with the release it belongs
    to in a trailing comment. A tag is a pointer its own maintainer can move, and the release job
    holds a token that can publish, so `@v4` would mean whatever that repository calls v4 on the day
    the job runs.
  - A tagged release doesn't publish without a verifiable signature on the tag. The workflow asks
    GitHub for the tag object and refuses a lightweight or unsigned one.
  - A tagged release made while the repository is public carries a build attestation
    (`actions/attest-build-provenance`), signed with a short-lived OIDC token and verifiable against
    this repository and the workflow run that produced it:
    `gh attestation verify word-linux-x64.tar.gz --repo rdkempt/word`. `SHA256SUMS` is still
    published, and it's only a convenience: the same job writes it and the binaries, so anyone who
    could replace one could replace the other. The attestation is the part a checksum file can't do
    for itself. GitHub only attests from a private repository on Enterprise Cloud, which a personal
    account can't have, so a release cut while this one is private has none: the workflow skips the
    step, and the release notes say there's no attestation instead of printing the command above.
  - The rolling `nightly` prerelease, which every push to main replaces, has neither: no signed tag
    and no attestation.
- **What's left is Thompson's "trusting trust" problem** at the root, the very first compiler, the
  same as for Go and rustc. It isn't specific to word.

## 10. Durability and platforms

- **Line endings.** `.gitattributes` forces LF, and the lexer and the assembler accept a stray `\r`
  at the end of a line, so a CRLF checkout builds and runs.
- **Error handling.** Most run-time errors end the process, and only the `== none` convention is
  recoverable. A long-running service written in word can't catch a fault and carry on. Nothing is
  planned for that, and leaving it is a decision, which SPEC §15 records too.
- **A failed write answers false.** `write()` and `append()` answer false when a write fails part
  way (a full disk, a pipe whose reader has gone, a file past its size limit), on every target, and
  a `send()` to a closed peer answers 0 instead of raising SIGPIPE. `out()` and `err()` into a pipe
  whose reader has gone end the program with status 141 everywhere, the way SIGPIPE does on Linux.
  Any other failed write of standard output or standard error, a full disk say, is a located fault
  (`could not write standard output`, exit 70), so output is never lost without a word. The macOS
  halves of this (`F_SETNOSIGPIPE`, and the `sigaction` step for SIGXFSZ) have never run on a Mac.
- **Paths go to the OS as they were written.** A path is sent as UTF-8 when it's text and as its
  bytes when it's byte-backed. A NUL or a path too long for the OS fails the call instead of opening
  something else, and a surrogate in a path is a `not a character` fault.
- **File I/O and memory.** I/O is chunked and the arena grows on demand, so there's no fixed limit on
  file size or allocation other than the arena's own: a 16 TiB span, and 2^40 elements in any one
  region. A request past either is `out of memory` before any size can wrap (§4).
- **Platforms.** Linux x86-64, Linux AArch64, Windows x86-64 and macOS on Apple Silicon. `net` and TLS
  are one implementation on all four, word source compiled into each program with no library per
  target, so the cipher suites, the handshake, the X.509 verifier and the record layer are the same
  code everywhere. Four things differ per target: the syscall shim, the socket layer, where the trust
  anchors come from (a PEM file on Linux and macOS, read with `read` and parsed in word; the Crypt32
  ROOT store on Windows, through `cacerts()`, SPEC §12.5), and where the resolver comes from
  (`/etc/resolv.conf` on Linux and macOS; `GetNetworkParams` on Windows, through `nameservers()`). On
  Windows neither is ever looked for in a file (§5). On macOS, `net` doesn't work in 1.0.0: the macOS
  OS layer maps no socket calls yet, so every `net` verb answers `none` there.

  What's executed on each target is a different question from what's shared, and the table below
  answers it. "One implementation" means a bug found on one target is a bug on all of them; it
  doesn't show that the parts that differ per target work. Only the Linux x86-64 and Windows rows
  are verified HTTPS fetches, end to end, on the hardware the target runs on.

  | target | where it runs | crypto KATs | sockets | full TLS 1.3 handshake and chain verification |
  |---|---|---|---|---|
  | Linux x86-64 | natively (`ci.yml`) | yes | yes | yes: local ECDSA and RSA servers, 12 must-reject chains, 12 live public hosts, the top 100 domains |
  | Linux AArch64 | under qemu-user (`ci.yml`) | yes | yes (loopback) | yes, under qemu-user: `test_tls_a64.sh` runs both suites, all three groups (two through a HelloRetryRequest), RSA and ECDSA leaves, a CertificateRequest answered with an empty Certificate, and the refusals; with verification on, chains under a local root, directly and through an intermediate, and a name that doesn't match |
  | macOS Apple Silicon | a `macos-14` runner (`macos.yml`) | in `macos.yml`, but never run | no: not in 1.0.0 | no: every `net` verb answers `none` in 1.0.0 |
  | Windows x86-64 | natively, on a `windows-latest` runner (`windows.yml`) | yes, natively | yes, natively | yes: a live fetch through the ROOT store and the top 100 domains, both gating; every `net` verb against a local TLS server; the whole profile against openssl and Go; 12 live public hosts, informational |

  The results above come from running the same suites the workflows run on my own machines: in WSL
  for both Linux rows (AArch64 under qemu-user), and natively on a Windows 11 machine for the
  Windows row. `macos.yml`'s socket, TLS and live HTTPS steps are marked informational, because they
  can't pass until the macOS layer maps sockets.

  qemu-user runs the arm64 instructions on an x86-64 machine's network stack, so it shows the arm64
  code is right without showing that an arm64 host completes a handshake. `test_tls_a64.sh` compares
  the arm64 client with the x86-64 one, so as written it needs an x86-64 host, and nothing has run a
  handshake on arm64 hardware.

- **Windows is tested on Windows.** `windows.yml` builds the PE on Linux and hands it to a
  `windows-latest` runner, which self-hosts it, runs the examples, and runs the PE suite natively:
  argv through `GetCommandLineA`, `rename` through `MoveFileExA` and `GetFileAttributesA`, the
  clock, the random source, a socket fetch and the ROOT store. It also runs the crypto known
  answers, the socket primitives, every `net` verb against local servers, the network-bounds and
  X.509 profile suites, all three decoder fuzzers (at a quarter of the Linux inputs), live HTTPS
  through ROOT, the suite that shows the resolver and the trust store come from Windows and not from
  the drive root, and `test_lang.sh`, `test_gaps.sh`, `test_guarantees.sh` and `test_alias.sh`. A
  structural check of a cross-built PE can't tell you `setsockopt` accepted the option numbers it
  was handed, and running the suite natively can. `timeout()` puts a working deadline on every
  socket, and the run-time faults SPEC §10.2 promises as `file:line: message` with exit 70 arrive
  that way on Windows too:

  - **`write to a literal`** is an address test: anything below `litpool_top` is a literal. It fires
    for `kind()`'s answers and the four singleton names because they're handed out from the pool's
    runtime copy (`litfix`) instead of from the image, which under a PE with `HIGH_ENTROPY_VA` sits
    around `0x7ff6_0000_0000`, above the pool, where the guard wouldn't see them. `test_txt.sh` has
    the case (`k = kind(1)`, then `k[0] = 65`), but `windows.yml` doesn't run `test_txt.sh`, so on
    Windows it's checked by hand; I checked it natively for this release.
  - **`stack exhausted`** is `cmp rsp, stack_limit; jb rt_stack` in every function prologue, and the
    same two instructions in `rt_eq` and on `rt_order`'s element path, where they report
    `comparison nests too deeply (a cycle?)` instead: a structure with no end, not the program's own
    recursion (SPEC §3.3). On Windows `stack_limit` comes from the `SizeOfStackReserve` word's own
    linker writes into the image, 8 MB, the same as Linux's default stack, so it can't disagree with
    the header and needs no `getrlimit`, which the Win32 shim doesn't have. `test_gaps.sh`, which
    `windows.yml` runs natively, checks both faults, and `test_win_pe.sh` checks the header.

## 11. Risk summary

| Area | Class | Severity | Notes |
|---|---|---|---|
| No outside audit | Unknown unknowns | Medium | Nobody outside this project has looked. Every test here was written from inside, which says nothing about how many bugs are left. |
| No certificate revocation (§5) | Auth bypass, bounded | Medium | A revoked certificate is accepted until it expires. A choice (§5); stapling is the sane fix. |
| Crypto timing side channels (§5) | Information leak | Medium | There's no AES-NI or PCLMULQDQ path and word source can't reach one, so every CPU runs the software AES-GCM: a 256-byte S-box indexed by a state byte, and GHASH tables of 512 and 128 bytes indexed by nibbles of the data. All three are cache channels, on every machine. ChaCha20-Poly1305 has no tables and is offered first, but a peer that only does AES-GCM gets AES-GCM. RSA and the P-256 and P-384 key exchange aren't constant time. The AEAD tag and Finished comparisons are. |
| Hand-written X.509 and DER parsing (§5) | Memory corruption from remote input, held to denial of service | Low to medium | Bounds-checked and fuzzed (`test_fuzz.sh`, about 4,400 inputs). Fuzzing isn't proof. |
| TLS record and handshake decoders (§5) | Memory corruption from remote input, held to denial of service | Low to medium | Fuzzed (`test_fuzz_tls.sh`, about 11,000 inputs). Fuzzing isn't proof. |
| DNS and HTTP response parsers (§5) | Memory corruption from remote input, held to denial of service | Low | Fuzzed (`test_fuzz_net.sh`, about 5,500 cases). Over `http://` the framing is all that stands between a server and the program. |
| `reset()` and dangling references (§4) | Use after free | Low to medium | Documented as unsafe. A loop that fetches without end needs it to stay inside its memory (SPEC §12.2), which brings it into ordinary programs, and the net library's 20 windows of its own are trusted code no test checks directly. |
| Exploit mitigations (§4) | Hardening | Low | Heap ASLR and W^X on every target; the PE sets NX and ASLR, has a relocation directory, gates its imports and carries a checksum. The literal pool is writable at a fixed address, and the Linux ELF isn't position-independent. |
| Compiler on untrusted source (§6) | Denial of service | Low to medium | The front end is fuzzed (`test_fuzz_frontend.sh`) and not audited. You normally compile your own code. |
| A trust anchor's `keyUsage` isn't read (§5) | Auth, narrow | Low | An anchor whose `keyUsage` leaves out `keyCertSign` still anchors a chain; openssl and Go refuse it. `test_x509_profile.sh` has no case for it yet. |
| Certificates the decoder can't parse (§5) | Reach | Low | An Ed448 or brainpool key doesn't parse. As the leaf it fails the handshake even with `insecure`, and in the trust store the anchor is lost. |
| DNS follows the host (§5) | Redirection | Low | A hostile resolver can steer a connection but can't forge the certificate at the end of it. A host with only IPv6 resolvers sends every lookup to 1.1.1.1. |
| Wrapping bitwise results (§8) | Correctness | Low | A shift wraps its result; a correctness issue, not a memory-safety one. |
| `json.parse` on remote payloads (§8a) | Crash, resource exhaustion | Low | RFC 8259 only, depth-capped, exponent-clamped, bounds-checked, safe with surrogates, and fuzzed (`test_fuzz_json.sh`). |

**The most valuable work left, in order:** (1) an outside audit, since no amount of testing from
inside substitutes for one; (2) OCSP stapling, so revocation is checked without a round trip or a
privacy leak; (3) a constant-time RSA path; (4) an independent review of the compiler and the
parsers.

**Where word stands.** It's reasonable for fetching from the ordinary internet: certificates are
verified properly, chains that should be refused are refused, and the decoders that read an
attacker's bytes are fuzzed. It's a poor choice where
revocation matters (a compromised certificate stays good until it expires), where an attacker can
measure your timing against the AES, RSA or NIST-curve code, or where the cost of an unknown bug is high, because
it hasn't been audited, and a TLS stack this young hasn't earned the assumption that the last bug has
been found. Between those, judge it the way you'd judge any young implementation: on what its tests
actually cover, which is the table at the top of this page.

For trusted input from a trusted author it's safe, and it's a good way to see how all of this works
from the inside.
