// RFC 4231 test cases 1-4 and 6 for HMAC-SHA256, RFC 5869 test cases 1 and 3
// for HKDF-SHA256, and TLS 1.3's HKDF-Expand-Label. Case 6 is the one with a
// key longer than the block, which is the path that hashes the key first.
hex_of(b)
    d = "0123456789abcdef"
    s = bytes(len(b) * 2)
    i = 0
    loop i < len(b)
        s[i * 2] = d[(b[i] >> 4) & 15]
        s[i * 2 + 1] = d[b[i] & 15]
        i = i + 1
    return s

nib(c)
    if c >= 48 && c <= 57
        return c - 48
    return c - 87

un_hex(s)
    b = bytes((len(s) >> 1))
    i = 0
    loop i < len(b)
        b[i] = nib(s[i * 2]) * 16 + nib(s[i * 2 + 1])
        i = i + 1
    return b

str_bytes(s)
    b = bytes(len(s))
    i = 0
    loop i < len(s)
        b[i] = s[i]
        i = i + 1
    return b

rep(v, n)
    b = bytes(n)
    i = 0
    loop i < n
        b[i] = v
        i = i + 1
    return b

check(what, got, want)
    if hex_of(got) == want
        return 1
    err("  FAIL: " . what)
    err("    want " . want)
    err("    got  " . hex_of(got))
    return 0

n = 0
// RFC 4231 case 1
n = n + check("hmac case 1", hmac_sha256(rep(11, 20), str_bytes("Hi There")), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
// case 2: a short key, a longer message
n = n + check("hmac case 2", hmac_sha256(str_bytes("Jefe"), str_bytes("what do ya want for nothing?")), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
// case 3: a 20-byte key of 0xaa and 50 bytes of 0xdd
n = n + check("hmac case 3", hmac_sha256(rep(170, 20), rep(221, 50)), "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")
// case 4: a 25-byte counting key
k4 = bytes(25)
i = 0
loop i < 25
    k4[i] = i + 1
    i = i + 1
n = n + check("hmac case 4", hmac_sha256(k4, rep(205, 50)), "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b")
// case 6: a 131-byte key, longer than the block, so it is hashed first
n = n + check("hmac case 6", hmac_sha256(rep(170, 131), str_bytes("Test Using Larger Than Block-Size Key - Hash Key First")), "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
// RFC 5869 test case 1
prk = hkdf_extract(un_hex("000102030405060708090a0b0c"), rep(11, 22))
n = n + check("hkdf extract", prk, "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
n = n + check("hkdf expand", hkdf_expand(prk, un_hex("f0f1f2f3f4f5f6f7f8f9"), 42), "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
// RFC 5869 test case 3: no salt, no info
prk3 = hkdf_extract(bytes(0), rep(11, 22))
n = n + check("hkdf extract, no salt", prk3, "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04")
n = n + check("hkdf expand, no info", hkdf_expand(prk3, bytes(0), 42), "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")
// TLS 1.3's HKDF-Expand-Label (RFC 8446 7.1) on case 1's PRK, cross-checked
// against a separate implementation of the same framing.
n = n + check("expand-label key", hkdf_expand_label(prk, "key", bytes(0), 16), "f65b14c6c59da73761cd419e39d9da33")
n = n + check("expand-label iv", hkdf_expand_label(prk, "iv", bytes(0), 12), "2fbe05e2a0d8ceed3bbb5dcf")
n = n + check("expand-label with context", hkdf_expand_label(prk, "c hs traffic", sha256(str_bytes("transcript")), 32), "1d3264d92829f2a2248ed4d964d739f9d0013afa23131171a8bcde41e5636be9")
out("hmac/hkdf (word): " . n . " of 12 vectors match")
if n == 12
    return 0
return 1
