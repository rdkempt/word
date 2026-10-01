// McGrew & Viega, "The Galois/Counter Mode of Operation (GCM)", test cases 1-4.
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
check(what, got, want)
    if hex_of(got) == want
        return 1
    err("  FAIL: " . what)
    err("    want " . want)
    err("    got  " . hex_of(got))
    return 0
n = 0
// TC1: everything empty. The tag is the encryption of the counter block alone.
n = n + check("TC1", gcm_encrypt(un_hex("00000000000000000000000000000000"), un_hex("000000000000000000000000"), bytes(0), bytes(0)), "58e2fccefa7e3061367f1d57a4e7455a")
// TC2: one zero block, no AAD.
n = n + check("TC2", gcm_encrypt(un_hex("00000000000000000000000000000000"), un_hex("000000000000000000000000"), bytes(0), un_hex("00000000000000000000000000000000")), "0388dace60b6a392f328c2b971b2fe78ab6e47d42cec13bdf53a67b21257bddf")
// TC3: 64 bytes, no AAD.
k3 = un_hex("feffe9928665731c6d6a8f9467308308")
iv3 = un_hex("cafebabefacedbaddecaf888")
p3 = un_hex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255")
n = n + check("TC3", gcm_encrypt(k3, iv3, bytes(0), p3), "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f59854d5c2af327cd64a62cf35abd2ba6fab4")
// TC4: 60 bytes (a partial final block) with 20 bytes of AAD, the shape a
// TLS 1.3 record has.
a4 = un_hex("feedfacedeadbeeffeedfacedeadbeefabaddad2")
p4 = un_hex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39")
ct4 = gcm_encrypt(k3, iv3, a4, p4)
n = n + check("TC4", ct4, "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e0915bc94fbc3221a5db94fae95ae7121a47")
// And back: the decrypt has to return the plaintext, and has to refuse a
// tampered tag instead of returning something.
p4b = gcm_decrypt(k3, iv3, a4, ct4)
n = n + check("TC4 decrypt", p4b, hex_of(p4))
bad = copy(ct4)
bad[len(bad) - 1] = bad[len(bad) - 1] ^ 1
if gcm_decrypt(k3, iv3, a4, bad) == 0
    n = n + 1
else
    err("  FAIL: a tampered tag was accepted")
// A tampered ciphertext byte has to fail too, not just a tampered tag.
bad2 = copy(ct4)
bad2[0] = bad2[0] ^ 1
if gcm_decrypt(k3, iv3, a4, bad2) == 0
    n = n + 1
else
    err("  FAIL: a tampered ciphertext was accepted")
// So does the wrong AAD.
if gcm_decrypt(k3, iv3, bytes(0), ct4) == 0
    n = n + 1
else
    err("  FAIL: the wrong AAD was accepted")
// The multiply reads a 4-bit table, and a table is easy to get slightly wrong
// in a way four published vectors don't reach: they exercise one H, and the
// likely bugs (a mis-seeded power of two, a reduction word off by a shift, the
// wrong nibble order) only show up on particular operands. So the bit-serial
// multiply the table replaced is kept here as the oracle, and the two are run
// against each other on pseudo-random inputs. That's how the fast one is shown
// to be right.
gfk_xor(z, v)
    z[0] = z[0] ^ v[0]
    z[1] = z[1] ^ v[1]
    z[2] = z[2] ^ v[2]
    z[3] = z[3] ^ v[3]
    return 0
gfk_shift(v)
    lsb = v[3] & 1
    v[3] = ((v[3] >> 1) | ((v[2] & 1) << 31)) & 4294967295
    v[2] = ((v[2] >> 1) | ((v[1] & 1) << 31)) & 4294967295
    v[1] = ((v[1] >> 1) | ((v[0] & 1) << 31)) & 4294967295
    v[0] = (v[0] >> 1) & 4294967295
    if lsb == 1
        v[0] = v[0] ^ 3774873600
    return 0
// z = x * y in GF(2^128), bit by bit, straight from NIST SP 800-38D.
gfk_ref(z, x, y)
    v = text(4)
    v[0] = y[0]
    v[1] = y[1]
    v[2] = y[2]
    v[3] = y[3]
    z[0] = 0
    z[1] = 0
    z[2] = 0
    z[3] = 0
    i = 0
    loop i < 128
        w = x[(i >> 5)]
        if ((w >> (31 - (i % 32))) & 1) == 1
            gfk_xor(z, v)
        gfk_shift(v)
        i = i + 1
    return 0
// A cheap deterministic generator, so a failure is reproducible. It's kept to
// 31 bits because word integers are 63-bit and a 32-bit seed times this
// multiplier overflows, so a cell is built from two draws instead of one.
gfk_next(seed)
    return (seed * 1103515245 + 12345) & 2147483647
gfk_cell(c, seed)
    i = 0
    loop i < 4
        seed = gfk_next(seed)
        hi = (seed >> 8) & 65535
        seed = gfk_next(seed)
        lo = (seed >> 8) & 65535
        c[i] = (hi << 16) | lo
        i = i + 1
    return seed
// z = x * H, leaving x alone. The mode multiplies its accumulator in place, so
// gcm.w has no use for this form, but the differential below drives the
// multiply directly on random operands, and needs it.
gfk_mul(z, x, tbl)
    z[0] = x[0]
    z[1] = x[1]
    z[2] = x[2]
    z[3] = x[3]
    gf_mul_y(z, tbl)
    return 0
gfk_eq(a, b)
    if a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3]
        return 1
    return 0
diffs = 0
trials = 0
seed = 20260902
x = text(4)
y = text(4)
za = text(4)
zb = text(4)
t = 0
loop t < 64
    seed = gfk_cell(x, seed)
    seed = gfk_cell(y, seed)
    gfk_ref(za, x, y)
    gfk_mul(zb, x, gf_table(y))
    if gfk_eq(za, zb) == 0
        diffs = diffs + 1
    trials = trials + 1
    t = t + 1
// The edges the generator won't produce on its own: zero, one, and the all-ones
// operand that makes every reduction word fire.
ones = text(4)
ones[0] = 4294967295
ones[1] = 4294967295
ones[2] = 4294967295
ones[3] = 4294967295
zed = text(4)
zed[0] = 0
zed[1] = 0
zed[2] = 0
zed[3] = 0
one = text(4)
one[0] = 2147483648
one[1] = 0
one[2] = 0
one[3] = 0
edge(a, b)
    p = text(4)
    q = text(4)
    gfk_ref(p, a, b)
    gfk_mul(q, a, gf_table(b))
    return gfk_eq(p, q)
diffs = diffs + (1 - edge(ones, ones))
diffs = diffs + (1 - edge(ones, one))
diffs = diffs + (1 - edge(one, ones))
diffs = diffs + (1 - edge(zed, ones))
diffs = diffs + (1 - edge(ones, zed))
diffs = diffs + (1 - edge(one, one))
trials = trials + 6
if diffs == 0
    n = n + 1
    out("aes-gcm (word): the 4-bit multiply matches the bit-serial one on " . trials . " operand pairs")
else
    err("  FAIL: the 4-bit multiply disagrees with the bit-serial one on " . diffs . " of " . trials . " pairs")

// Every message length from 0 to 48, and every AAD length from 0 to 20, so the
// two partial-block paths run at every offset instead of the one each that the
// published vectors happen to reach (TC4 is 60 bytes of plaintext and 20 of
// AAD, a 12-byte tail and a 4-byte tail).
//
// Three properties, none of which needs a second implementation:
//
//  - The ciphertext of a prefix is a prefix of the ciphertext. Counter mode
//    xors a keystream that depends only on the counter, so this has to hold
//    for every n, and it fails as soon as the tail loop writes the wrong byte
//    or stops at the wrong index.
//  - It decrypts back.
//  - Every single-byte change is caught, in the ciphertext and in the AAD
//    alike. A GHASH tail that drops bytes off the end still round-trips and
//    still agrees with itself, but it stops authenticating the bytes it
//    dropped, and this is the property that sees it.
//
// The gap over the published vectors was measured: a GHASH tail that mishandles
// a remainder of exactly seven bytes passes all four NIST vectors and the
// multiply differential, and fails only here.
lk = un_hex("feffe9928665731c6d6a8f9467308308")
liv = un_hex("cafebabefacedbaddecaf888")
lbase = bytes(48)
li = 0
loop li < 48
    lbase[li] = (li * 7 + 11) & 255
    li = li + 1
lfull = gcm_encrypt(lk, liv, bytes(0), lbase)
lbad = 0
ln = 0
loop ln <= 48
    la = ln % 21
    aad = copy(lbase, 0, la)
    pt = copy(lbase, 0, ln)
    ct = gcm_encrypt(lk, liv, aad, pt)
    if len(ct) != ln + 16
        lbad = lbad + 1
    // the keystream prefix property, checked against the no-AAD 48-byte run
    i = 0
    loop i < ln
        if ct[i] != lfull[i]
            lbad = lbad + 1
        i = i + 1
    back = gcm_decrypt(lk, liv, aad, ct)
    if back == 0
        lbad = lbad + 1
    else
        i = 0
        loop i < ln
            if back[i] != pt[i]
                lbad = lbad + 1
            i = i + 1
    // every byte of the ciphertext and tag, flipped one at a time
    i = 0
    loop i < ln + 16
        t = copy(ct)
        t[i] = t[i] ^ 1
        if gcm_decrypt(lk, liv, aad, t) != 0
            lbad = lbad + 1
        i = i + 1
    // and every byte of the AAD
    i = 0
    loop i < la
        t = copy(aad)
        t[i] = t[i] ^ 1
        if gcm_decrypt(lk, liv, t, ct) != 0
            lbad = lbad + 1
        i = i + 1
    ln = ln + 1
if lbad == 0
    n = n + 1
    out("aes-gcm (word): the partial-block paths hold at all 49 message lengths")
else
    err("  FAIL: " . lbad . " partial-block checks failed across the length sweep")

out("aes-gcm (word): " . n . " of 10 vectors match")
if n == 10
    return 0
return 1
