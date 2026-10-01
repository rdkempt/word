// 20 HTTPS GETs against a local server, one full TLS 1.3 handshake each.
//
// word has the least help here of any benchmark. Python and Node call OpenSSL,
// and Go has its own tuned crypto/tls, while word's TLS 1.3 (X25519 and
// P-256/P-384 ECDHE, RSA-PSS and ECDSA signature verification, AES-GCM and
// ChaCha20-Poly1305, HKDF, the record layer, the X.509 parser) is written in
// word itself (the net library carried in compiler/word.w) and linked against
// nothing. So this compares a stack written from scratch, compiled by the
// compiler it's measured with, against mature hand-tuned libraries.
//
// The certificate is a throwaway the setup script makes, so every client here
// is told to skip verification: word passes `true` as the `insecure` argument
// (SPEC §12.2; it's an ordinary condition, so the number 1 is refused) and the
// others their own equivalent. That keeps the comparison like for like, and
// measures the handshake and record layer instead of trust-store lookups.
n = 20
i = 0
total = 0
loop i < n
    total = total + len(get("https://127.0.0.1:4492/p", true))
    i = i + 1
out(total)
