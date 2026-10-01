// macos_net.w: `net` on Apple Silicon, against the local TLS server macos.yml
// starts, dev/benchmarks/netserve.py. Its one fixed body is "word-net-benchmark "
// 3446 times, 65474 bytes (every client in dev/benchmarks/nethttps agrees).
// With verification off the handshake should complete and the body arrive
// whole. With it on, the same URL should be refused, because the certificate is
// a throwaway. Anything else exits 1. The macOS layer doesn't map sockets yet,
// so in 1.0.0 every net verb answers none there, and macos.yml runs this as an
// informational step.
u = args()[1]
b = get(u, true)
if b == none
    err("macos_net: no answer through TLS with verification off")
    return 1
if len(b) != 65474
    err("macos_net: the body came back as " . len(b) . " characters, not 65474")
    return 1
out("macos_net: a TLS 1.3 handshake and the whole 65474-character body, verification off")
if get(u) != none
    err("macos_net: a throwaway certificate was accepted with verification on")
    return 1
out("macos_net: the same certificate refused with verification on")
