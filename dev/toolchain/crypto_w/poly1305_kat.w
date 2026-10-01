// Poly1305 and the ChaCha20-Poly1305 AEAD against RFC 8439: the section 2.5.2
// tag, the section 2.8.2 AEAD whose ciphertext and tag the RFC prints, and the
// lengths where the block loop can be wrong: empty, one byte, exactly one
// block, one past a block. Then the rejections: a flipped tag byte, a flipped
// ciphertext byte, and the wrong AAD.
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
// Poly1305 (RFC 8439 section 2.5): key is 32 bytes, r || s. Returns the 16-byte
// tag. A message that isn't a whole number of blocks ends in a short block
// carrying an explicit 0x01 where the 2^128 bit would be.
poly1305(key, msg)
    rs = poly_setup(key)
    h = text(5)
    n = len(msg)
    full = (n >> 4)
    poly_absorb(h, rs, msg, 0, full, 16777216)
    rest = n - full * 16
    if rest > 0
        blk = bytes(16)
        i = 0
        loop i < rest
            blk[i] = msg[full * 16 + i]
            i = i + 1
        blk[rest] = 1
        poly_absorb(h, rs, blk, 0, 1, 0)
    return poly_finish(h, key)

check(what, got, want)
    if hex_of(got) == want
        return 1
    err("  FAIL: " . what)
    err("    want " . want)
    err("    got  " . hex_of(got))
    return 0
n = 0
n = n + check("RFC 8439 2.5.2", poly1305(un_hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b"), un_hex("43727970746f6772617068696320466f72756d2052657365617263682047726f7570")), "a8061dc1305136c6c22b8baf0c0127a9")
n = n + check("empty message", poly1305(un_hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b"), un_hex("")), "0103808afb0db2fd4abff6af4149f51b")
n = n + check("one full block", poly1305(un_hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b"), un_hex("000102030405060708090a0b0c0d0e0f")), "a18a0de2ba299128303a398e28bde4f0")
n = n + check("one byte", poly1305(un_hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b"), un_hex("aa")), "62fc1018d20ba2b1a8b5dc84d9255477")
n = n + check("block boundary + 1", poly1305(un_hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b"), un_hex("000102030405060708090a0b0c0d0e0f10")), "37477d65160c3ca0466aac5780785ef5")
n = n + check("all-ones r", poly1305(un_hex("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"), un_hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")), "ce5b015861b53d361e4b4166e6c66ac6")
key = un_hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
nonce = un_hex("070000004041424344454647")
aad = un_hex("50515253c0c1c2c3c4c5c6c7")
pt = un_hex("4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e")
sealed = chacha20_poly1305_encrypt(key, nonce, aad, pt)
n = n + check("RFC 8439 2.8.2 AEAD", sealed, "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b61161ae10b594f09e26a7e902ecbd0600691")
n = n + check("and it opens again", chacha20_poly1305_decrypt(key, nonce, aad, sealed), "4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e")
if chacha20_poly1305_decrypt(key, nonce, aad, un_hex("d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b61161ae10b594f09e26a7e902ecbd0600690")) == 0
    n = n + 1
else
    err("  FAIL: a tampered tag was accepted")
if chacha20_poly1305_decrypt(key, nonce, aad, un_hex("d21a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b61161ae10b594f09e26a7e902ecbd0600691")) == 0
    n = n + 1
else
    err("  FAIL: a tampered ciphertext was accepted")
if chacha20_poly1305_decrypt(key, nonce, bytes(0), un_hex("d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b61161ae10b594f09e26a7e902ecbd0600691")) == 0
    n = n + 1
else
    err("  FAIL: the wrong AAD was accepted")
if chacha20_poly1305_decrypt(key, nonce, aad, bytes(4)) == 0
    n = n + 1
else
    err("  FAIL: an input too short to hold a tag was accepted")
out("chacha20-poly1305 (word): " . n . " of 12 checks pass")
if n == 12
    return 0
return 1
