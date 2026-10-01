// The DER reader against a real certificate (openssl made it, and every offset
// and length checked here came from walking the same bytes in Python), and
// against the malformed encodings the reader should refuse. The refusals matter
// most: a certificate is attacker-controlled input, and a reader that accepts
// an indefinite length or a non-minimal one can be made to disagree with
// whoever signed the certificate.
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
eq(what, got, want)
    if got == want
        return 1
    err("  FAIL: " . what . ": want " . want . ", got " . got)
    return 0
rejects(what, b)
    if der_read(b, 0, len(b)) == 0
        return 1
    err("  FAIL: " . what . " should have been rejected")
    return 0
accepts(what, b)
    if der_read(b, 0, len(b)) != 0
        return 1
    err("  FAIL: " . what . " should have parsed")
    return 0
n = 0
cert = un_hex("3082036030820248a00302010202146963085d3e61932ec5c449aa258aeae6c4561703300d06092a864886f70d01010b0500302b3115301306035504030c0c776f72642e6578616d706c6531123010060355040a0c09576f72642054657374301e170d3236303833313030323234305a170d3336303832383030323234305a302b3115301306035504030c0c776f72642e6578616d706c6531123010060355040a0c09576f7264205465737430820122300d06092a864886f70d01010105000382010f003082010a0282010100d96550c6f0e52491e22cc781231ecbd3932603cca77e64137ea1c89df41cc9d4ec881be0e2f47985589b095cbb4431e8e9f6bd52637643bf2f3778e679329d4ee441763a5f80cda06003487a2aef40f3a0b3fece6f872011d39497a2f3b614ec92b4c5ff31761017593bc3f71afc8da4d34c324542e627eeaf8d0a051c5abade4a06f15cfc9a3aab9244ed081f9194cd24d168fd913393902d1a7653ee370aee97637e9eb313f98f73bd2a45be478f1eda070db776ada34f8df91160c0dbb15ee7dcf8511e44d5cd9a5b41d14e4155af4155029bdac0efc282296e51e75e81314e159573c24f7f7c76aace29ab50c9bbc762b57c30ea58bf645711bf812265210203010001a37c307a301d0603551d0e04160414df08d0668017d14244f3852dbe6d188e54334d63301f0603551d23041830168014df08d0668017d14244f3852dbe6d188e54334d63300f0603551d130101ff040530030101ff30270603551d110420301e820c776f72642e6578616d706c65820e2a2e776f72642e6578616d706c65300d06092a864886f70d01010b0500038201010010d1b6edd9e2e768dfeff3ea1d3a6c83f9a2e1e23fc846e6aaaaa30cc3fa5f794874f70d807f3132a3498485c849c8f2806f0387e687ded751f866271b9982f4f6f9c6570858d43a812e69a1aa0f3f7d8e463672b81d7e843d8f1194e744e5fc78cf1b47e6f8582fd359259a29b50d40271dc18567173a4d32a96da4d3b2497befa789c63bcf0f2c67a3a1ab8884ad1280cde2c07028e7d9f14bade7ac96a1d157f4baa3bf4a61b481ab71c5103a6f188373deabe126526f932fe3c2832be982df56d0e803babe8a6ee7156f9c15ed0deeacd0b425f87365d1f9818aedafa775c89330897c0329b86c27ccf7e2435adb5efb9af7abc5e4a32363187c2785f001")
top = der_read(cert, 0, len(cert))
n = n + eq("certificate is a SEQUENCE", top[0], 48)
n = n + eq("certificate fills the file", der_end(top), len(cert))
tbs = der_expect(cert, top[1], der_end(top), 48)
n = n + eq("tbsCertificate TLV length", der_end(tbs) - top[1], 588)
sa = der_expect(cert, der_end(tbs), der_end(top), 48)
oid = der_expect(cert, sa[1], der_end(sa), 6)
n = n + eq("signature algorithm is sha256WithRSAEncryption", der_content_is(cert, oid, un_hex("2a864886f70d01010b")), 1)
n = n + eq("a different OID does not match", der_content_is(cert, oid, un_hex("2a864886f70d01010c")), 0)
sig = der_expect(cert, der_end(sa), der_end(top), 3)
n = n + eq("signature is 2048 bits", len(der_bits(cert, sig)), 256)
ver = der_expect(cert, tbs[1], der_end(tbs), 160)
n = n + eq("version is [0] EXPLICIT", hex_of(der_slice(cert, ver[1], ver[2])), "020102")
ser = der_expect(cert, der_end(ver), der_end(tbs), 2)
n = n + eq("serial number", hex_of(der_uint(cert, ser)), "6963085d3e61932ec5c449aa258aeae6c4561703")
n = n + eq("the wrong tag is refused", der_expect(cert, 0, len(cert), 49), 0)
// Malformed encodings.
n = n + rejects("the indefinite length form", un_hex("308005000000"))
n = n + rejects("a long form for a length that fits the short one", un_hex("30810105"))
n = n + rejects("a length with a leading zero byte", un_hex("308200050000000000"))
n = n + rejects("a length running past the end", un_hex("30050102"))
n = n + rejects("a high tag number", un_hex("1f010005"))
n = n + rejects("a truncated header", un_hex("30"))
n = n + accepts("a length that needs the long form", un_hex("048180aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
n = n + eq("a negative INTEGER", der_uint(un_hex("0201ff"), der_read(un_hex("0201ff"), 0, 3)), 0)
n = n + eq("an INTEGER with a leading zero", hex_of(der_uint(un_hex("020200ff"), der_read(un_hex("020200ff"), 0, 4))), "ff")
n = n + eq("a BIT STRING with unused bits", der_bits(un_hex("030204f0"), der_read(un_hex("030204f0"), 0, 4)), 0)
n = n + eq("a whole-byte BIT STRING", hex_of(der_bits(un_hex("030200f0"), der_read(un_hex("030200f0"), 0, 4))), "f0")
out("der (word): " . n . " of 20 checks pass")
if n == 20
    return 0
return 1
