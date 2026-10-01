// Known-answer tests for the net library's sha256.w. The vectors are FIPS 180-4's
// own, plus the two shapes careless padding gets wrong: a message whose length
// leaves no room for the 8-byte length in its last block, and one that is an
// exact multiple of the block size.
hex_of(b)
    d = "0123456789abcdef"
    s = bytes(len(b) * 2)
    i = 0
    loop i < len(b)
        s[i * 2] = d[(b[i] >> 4) & 15]
        s[i * 2 + 1] = d[b[i] & 15]
        i = i + 1
    return s

str_bytes(s)
    b = bytes(len(s))
    i = 0
    loop i < len(s)
        b[i] = s[i]
        i = i + 1
    return b

check(msg, want)
    got = hex_of(sha256(str_bytes(msg)))
    if got == want
        return 1
    err("  FAIL: sha256 of a " . len(msg) . "-byte message")
    err("    want " . want)
    err("    got  " . got)
    return 0

n = 0
n = n + check("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
n = n + check("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
n = n + check("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
n = n + check("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu", "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
// 55 bytes: the last block that still has room for the length.
n = n + check("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
// 56 bytes: it doesn't, so the padding needs a whole extra block.
n = n + check("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
// 64 bytes: an exact block, so the padding is entirely in the extra one.
n = n + check("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
big = ""
i = 0
loop i < 1000
    big = big . "a"
    i = i + 1
n = n + check(big, "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
// A message with every byte value, so no path is only ever fed ASCII.
allb = bytes(256)
i = 0
loop i < 256
    allb[i] = i
    i = i + 1
if hex_of(sha256(allb)) == "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880"
    n = n + 1
else
    err("  FAIL: sha256 of the 256 byte values")
out("sha256 (word): " . n . " of 9 vectors match")
if n == 9
    return 0
return 1
