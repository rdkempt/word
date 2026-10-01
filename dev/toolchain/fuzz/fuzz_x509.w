// fuzz_x509.w: the X.509 fuzz driver, run by dev/toolchain/test_fuzz.sh.
//
// Reads one mutated certificate from the path in argv[1] and puts it through
// every decoder a server-supplied certificate reaches: the DER walk, the field
// extraction, hostname matching, and the signature check itself with the
// certificate standing in as its own issuer, so the RSA and ECDSA paths run on
// attacker-shaped key and signature bytes too. It exits 0 whatever the answer,
// because the answer isn't what's being tested: a malformed certificate must
// be rejected, and rejection is a return value.
//
// A failure here is the program not returning at all, in one of two ways:
//
//   exit 70   a length field was wrong and a decoder indexed past the end of a
//             region. In word that's a bounds fault with a line number, not
//             silent memory corruption, but it's still a decoder trusting a
//             number it read off the wire, which is the bug.
//   a hang    a length that walks backwards, or an entry count that doesn't
//             shrink, and the parse loop never ends.
//
// The test script appends this to the crypto modules to make one program. It's
// never built on its own, since it calls library functions it only gets that
// way.
fz_argpath()
    a = args()
    if len(a) < 2
        err("fuzz_x509: no input file")
    return a[1]

fz_der = read(fz_argpath())
fz_c = x509_parse(fz_der)
if kind(fz_c) != "number"
    // Everything a verifier does with a parsed certificate, on bytes that were
    // never authenticated. x509_check_sig(c, c) is the important one: it
    // dispatches on the certificate's own claimed algorithm and hands its own
    // claimed key and signature to rsa_pkcs1_verify / rsa_pss_verify /
    // ecdsa_verify.
    x509_match_host(fz_c, "fuzz.example")
    x509_match_host(fz_c, "10.0.0.1")
    x509_check_sig(fz_c, fz_c)
    // and the chain walk over it: name chaining, validity, basicConstraints,
    // keyUsage and pathlen, on the same unauthenticated fields. The trust store
    // is empty: an anchor is local, not server-supplied, and leaving it out
    // keeps this from repeating the signature check above.
    fz_chain = text(2)
    fz_chain[0] = fz_c
    fz_chain[1] = fz_c
    x509_verify_chain(fz_chain, text(0), "fuzz.example", 1788136049)
