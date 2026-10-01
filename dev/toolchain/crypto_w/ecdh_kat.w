// Known-answer tests for the net library's ecdh.w, against vectors openssl
// generated: for each curve a private scalar, the public point it must produce,
// a second party's public point, and the shared secret the two must agree on.
// A wrong scalar multiplication passes nothing here.
ecdh_hx(b)
    d = "0123456789abcdef"
    s = bytes(len(b) * 2)
    i = 0
    loop i < len(b)
        s[i * 2] = d[(b[i] >> 4) & 15]
        s[i * 2 + 1] = d[b[i] & 15]
        i = i + 1
    return s

ecdh_nb(c)
    if c >= 48 && c <= 57
        return c - 48
    return c - 87

ecdh_uh(t)
    b = bytes((len(t) >> 1))
    i = 0
    loop i < len(b)
        b[i] = ecdh_nb(t[i * 2]) * 16 + ecdh_nb(t[i * 2 + 1])
        i = i + 1
    return b

ecdh_check(name, got, want)
    if got == want
        return 1
    err("  FAIL: " . name)
    err("    want " . want)
    err("    got  " . got)
    return 0

n = 0

// ecdsa.w comes in for its curve arithmetic, not its verifier. Naming the
// verifier satisfies the unused-function check without testing it here
// (ecdsa_kat does that).
if 0 == 1
    out("" . ecdsa_verify(1, bytes(65), bytes(32), bytes(32), bytes(32)))

d = ecdh_uh("f928b4f13481eac743a313942fc59b832a3a3297db56e8495211360dde89b003")
n = n + ecdh_check("P-256 public point from a private scalar", ecdh_hx(ec_pubkey(1, d)), "04be7b6a39f87c53b86b936b5b4de55fc444f47cbd5cb85b0a0eb29dfbfe3806cf4b32640ae828f76264cc0822b84285608746f67835caa9b9a26c60efb5dec7e7")
n = n + ecdh_check("P-256 shared secret agrees with the peer", ecdh_hx(ec_ecdh(1, d, ecdh_uh("040f2cb4bfb1ba10becd78e11baa403b07ce22f243512cb4ec8e983a04f25ee89dd8c0e52acf557033714adb63e3e2a3381291e01f7383a15b835b9c57ce23a19d"))), "291db37d3e88bd69a03c6b0157643603025eff81e9bfb21d555181f7b3697787")

d = ecdh_uh("b75f9cb9294ecdb118fa19f937fc3f6f1e3172ac56ba0fb20c11d08dc8f60ccfa014ed94f28c9cfaec484d2156c51511")
n = n + ecdh_check("P-384 public point from a private scalar", ecdh_hx(ec_pubkey(2, d)), "040d96d7619920c15187f8d768da8be0bc29f8f4d458586b4b24f552fa4ab487c2e4a4adc40d808e2f157117677590ed3f4a206281086a9a22013d0fd3ddc7e9fed08e65c71823cb963374791dafb64cfc34b0f5d66143582e73c7adf6599f0c4d")
n = n + ecdh_check("P-384 shared secret agrees with the peer", ecdh_hx(ec_ecdh(2, d, ecdh_uh("04c3395d69b0d35aa7ec5f2abb46d0f2b2858d0a58031d9acc27a733487d3baca897303936e94f7e0f755ee6c7b901c3e985aedf7fe2a4d625cf53470ca00576089f7e7c26895489026bf7f5a50f43c93a09af672fbe6bfb41cdcade69f4c0704c"))), "17740db520c6d25d67ad27e6002fcc1a7ac122ea47c4f0b4b65379d50f44949dcb1d079e561c25d34fa99aa9e486805a")

// A point that isn't on the curve has to be refused, not multiplied: an
// invalid-curve point is how a peer gets a naive implementation to leak its
// scalar.
bad = ecdh_uh("040f2cb4bfb1ba10becd78e11baa403b07ce22f243512cb4ec8e983a04f25ee89dd8c0e52acf557033714adb63e3e2a3381291e01f7383a15b835b9c57ce23a19d")
bad[64] = bad[64] ^ 1
n = n + ecdh_check("a point off the curve is refused", "" . ec_ecdh(1, ecdh_uh("f928b4f13481eac743a313942fc59b832a3a3297db56e8495211360dde89b003"), bad), "0")
n = n + ecdh_check("a scalar of the wrong width is refused", "" . ec_pubkey(1, bytes(31)), "0")
n = n + ecdh_check("a zero scalar is refused", "" . ec_pubkey(1, bytes(32)), "0")

out("ecdh (key generation and agreement, P-256 and P-384): " . n . " of 7 vectors match")
if n == 7
    return 0
return 1
