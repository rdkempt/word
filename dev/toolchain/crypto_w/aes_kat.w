// FIPS 197 Appendix B and C: the worked AES-128 example, and the C.1/C.3
// vectors for 128- and 256-bit keys.
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
// A one-shot wrapper, kept here instead of in the module: every real caller
// keeps the aes_key context for a whole message, so a key setup per call only
// makes sense in a test.
aes_encrypt(key, block)
    ctx = aes_key(key)
    st = bytes(16)
    i = 0
    loop i < 16
        st[i] = block[i]
        i = i + 1
    aes_encrypt_block(st, ctx)
    return st

check(what, key, pt, want)
    got = hex_of(aes_encrypt(un_hex(key), un_hex(pt)))
    if got == want
        return 1
    err("  FAIL: " . what)
    err("    want " . want)
    err("    got  " . got)
    return 0
n = 0
// FIPS 197 Appendix B
n = n + check("B: AES-128", "2b7e151628aed2a6abf7158809cf4f3c", "3243f6a8885a308d313198a2e0370734", "3925841d02dc09fbdc118597196a0b32")
// FIPS 197 C.1
n = n + check("C.1: AES-128", "000102030405060708090a0b0c0d0e0f", "00112233445566778899aabbccddeeff", "69c4e0d86a7b0430d8cdb78070b4c55a")
// FIPS 197 C.3
n = n + check("C.3: AES-256", "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", "00112233445566778899aabbccddeeff", "8ea2b7ca516745bfeafc49904b496089")
// An all-zero key and block, which catches an S-box that is right except at 0.
n = n + check("zero key, zero block (128)", "00000000000000000000000000000000", "00000000000000000000000000000000", "66e94bd4ef8a2c3b884cfa59ca342b2e")
n = n + check("zero key, zero block (256)", "0000000000000000000000000000000000000000000000000000000000000000", "00000000000000000000000000000000", "dc95c078a2408989ad48a21492842087")

// The oracle: SubBytes, ShiftRows and MixColumns written out as three passes
// over a 16-byte region, one byte at a time, with a function call for xtime,
// which is what aes.w did before the round moved into column words. It's here
// for the same reason gcm_kat.w keeps the bit-serial multiply, and the gap was
// measured: making one of aes.w's sixteen S-box lookups wrong for one input byte
// in 256 still passes all five fixed vectors, and fails here on 5 of the 64
// pairs. Five fixed keys are five samples, and a round (or a backend) that's
// wrong only for some operand values needs more. The two implementations share
// only the S-box and the key schedule, so a change to either round has to break
// both to go unnoticed.
aesk_xt(a)
    a = a << 1
    if (a & 256) != 0
        a = a ^ 283
    return a & 255
aesk_ref_block(st, w, sb, nr)
    i = 0
    loop i < 16
        st[i] = st[i] ^ w[i]
        i = i + 1
    r = 1
    loop r <= nr
        i = 0
        loop i < 16
            st[i] = sb[st[i]]
            i = i + 1
        t = st[1]
        st[1] = st[5]
        st[5] = st[9]
        st[9] = st[13]
        st[13] = t
        t = st[2]
        st[2] = st[10]
        st[10] = t
        t = st[6]
        st[6] = st[14]
        st[14] = t
        t = st[15]
        st[15] = st[11]
        st[11] = st[7]
        st[7] = st[3]
        st[3] = t
        if r < nr
            c = 0
            loop c < 4
                a0 = st[c * 4]
                a1 = st[c * 4 + 1]
                a2 = st[c * 4 + 2]
                a3 = st[c * 4 + 3]
                x = a0 ^ a1 ^ a2 ^ a3
                st[c * 4] = a0 ^ x ^ aesk_xt(a0 ^ a1)
                st[c * 4 + 1] = a1 ^ x ^ aesk_xt(a1 ^ a2)
                st[c * 4 + 2] = a2 ^ x ^ aesk_xt(a2 ^ a3)
                st[c * 4 + 3] = a3 ^ x ^ aesk_xt(a3 ^ a0)
                c = c + 1
        i = 0
        loop i < 16
            st[i] = st[i] ^ w[r * 16 + i]
            i = i + 1
        r = r + 1
    return 0

// A 31-bit LCG, with one byte taken from the high half of each step: the low
// bits of a linear congruential generator are nearly periodic and wouldn't walk
// the S-box. Seeded from a constant so a failure is reproducible.
aesk_next(seed)
    return (seed * 1103515245 + 12345) & 2147483647
aesk_fill(b, seed)
    i = 0
    loop i < len(b)
        seed = aesk_next(seed)
        b[i] = (seed >> 8) & 255
        i = i + 1
    return seed
aesk_same(a, b)
    i = 0
    loop i < 16
        if a[i] != b[i]
            return 0
        i = i + 1
    return 1

// nk bytes of key, a random block, both rounds, compared byte for byte. The
// seed comes back so the next trial continues the stream, and a negative return
// means they disagreed. `shown` is the count of failures already reported. Only
// the first prints its operands, because a broken round breaks all 64.
aesk_trial(nk, seed, shown)
    key = bytes(nk)
    seed = aesk_fill(key, seed)
    blk = bytes(16)
    seed = aesk_fill(blk, seed)
    sb = aes_sbox()
    w = aes_expand(key, sb)
    nr = (nk >> 2) + 6
    ra = copy(blk)
    aesk_ref_block(ra, w, sb, nr)
    rb = copy(blk)
    aes_encrypt_block(rb, aes_key(key))
    if aesk_same(ra, rb) == 1
        return seed
    if shown == 0
        err("    key   " . hex_of(key))
        err("    block " . hex_of(blk))
        err("    ref   " . hex_of(ra))
        err("    got   " . hex_of(rb))
    return 0 - seed

diffs = 0
trials = 0
seed = 20260902
t = 0
loop t < 64
    nk = 16
    if (t & 1) != 0
        nk = 32
    s2 = aesk_trial(nk, seed, diffs)
    if s2 < 0
        diffs = diffs + 1
        s2 = 0 - s2
    seed = s2
    trials = trials + 1
    t = t + 1
if diffs == 0
    n = n + 1
    out("aes (word): the column round matches the byte-wise one on " . trials . " random key/block pairs")
else
    err("  FAIL: the column round disagrees with the byte-wise one on " . diffs . " of " . trials . " pairs")

out("aes (word): " . n . " of 6 vectors match")
if n == 6
    return 0
return 1
