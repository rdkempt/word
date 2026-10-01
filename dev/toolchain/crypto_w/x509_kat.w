// A three-certificate chain openssl built and openssl verifies: an RSA root
// that signed a P-256 intermediate (CA, pathlen 0) that signed an RSA leaf with
// two subjectAltNames, one of them a wildcard. Parsing is checked field by
// field against openssl's own reading of the same bytes, and then the chain is
// put through the failures a verifier exists to catch.
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
yes(what, ok)
    if ok != 0
        return 1
    err("  FAIL: " . what . " should have verified")
    return 0
no(what, ok)
    if ok == 0
        return 1
    err("  FAIL: " . what . " should have been rejected")
    return 0
n = 0
leaf = x509_parse(un_hex("308202c130820268a00302010202021002300a06082a8648ce3d0403023040310b300906035504061302585831153013060355040a0c0c576f726420526f6f74204341311a301806035504030c11576f726420496e7465726d656469617465301e170d3236303833313030323732395a170d3336303832383030323732395a3038310b300906035504061302585831123010060355040a0c09576f726420546573743115301306035504030c0c776f72642e6578616d706c6530820122300d06092a864886f70d01010105000382010f003082010a0282010100a7aaf98a144da191b7bf0292e3d2365b81ed295d451e7096b01f9579ba74876d2f788f14941fdbd641a20c4768ad18dba80d631aa332955687c2f72ada978ae7d069e5a2996364d3f1cbcbbb02a466c68646f357059381b161eff81be87cd6a5761c0521f6ce05e03848c03c81f652465a202b65802792a9276d16dae4884bc24937a4d9df18666dd8e35484e9396bb334e26354802dc970e458cc0edd9b87a2b80ce3a2f8719d9c98f97b826c2df2eea0f366d2d59e178b319078cc269ba4f50a9ee8c00989824546f4fa017403cd47f24adb12a408176858820525071a1fb3d634edbfa7a6649758578a1f0999d41bcfbc5eaf844746b1296f9cb7db23e7570203010001a3818e30818b300c0603551d130101ff04023000300e0603551d0f0101ff0404030205a0302b0603551d1104243022820c776f72642e6578616d706c6582122a2e7375622e776f72642e6578616d706c65301d0603551d0e04160414c16527cd367356fb98cf652594cdf0e5251936ba301f0603551d23041830168014de901da2d45be7bf51a70c0196c3b7a55ccdd125300a06082a8648ce3d0403020347003044022071c100e21d20d007b112d178dbaff4772af784b8024b72e33149b56aa9db68b5022059f0fcaa2131e6851034af6cb1530bd5b9bb8328d69b3ec7e19945903bbe3c8f"))
itm = x509_parse(un_hex("3082028f30820177a00302010202021001300d06092a864886f70d01010b05003038310b300906035504061302585831153013060355040a0c0c576f726420526f6f742043413112301006035504030c09576f726420526f6f74301e170d3236303833313030323732395a170d3336303832383030323732395a3040310b300906035504061302585831153013060355040a0c0c576f726420526f6f74204341311a301806035504030c11576f726420496e7465726d6564696174653059301306072a8648ce3d020106082a8648ce3d03010703420004be1369365af4207866b51a45d51cef5f9d5ee739dcd010150c56cc8b6de1bb0905329bfbe87caad9074b557a7d0d8a5936173f5ad138808e6c1e6798e4c0cc3da366306430120603551d130101ff040830060101ff020100300e0603551d0f0101ff040403020106301d0603551d0e04160414de901da2d45be7bf51a70c0196c3b7a55ccdd125301f0603551d23041830168014388cb6c62fc03946e233be5ce73f7cc63b339497300d06092a864886f70d01010b05000382010100137121616a92bb2e84008a8df2f1b8de3a2572cd87c97cc30fbb49272bcd23d5805ea5440d121590902a9a62cd594bf7f3fc29f2641ea3313f8c09eba0bb649cc84bc82249890de1ea2af7993c7b1b946ac64249166d631f6ab414b08af6e71522146120e7327e0f65fe132ce5d600e58a1832e5e340c25148706c4037556afe1775562b8e0a6020acdfd63cda5e3d6c399afc5912f871b996a1849b8545de8b2c566afeadd6716de38e072af27598c128af79c8929cfd5141e7201aaacfcf3a0e78e53ed3089222a13bc209bde1ba542abde110bc7ee53c98ee7ef7691e92408bcda0f17e83eaca0a9fdd6ddd04af3d52de37dc92b08196efe2cc777ed63109"))
root = x509_parse(un_hex("3082034030820228a003020102021421030ef463fcef0b9069f1747d5835d84654334b300d06092a864886f70d01010b05003038310b300906035504061302585831153013060355040a0c0c576f726420526f6f742043413112301006035504030c09576f726420526f6f74301e170d3236303833313030323732395a170d3436303832363030323732395a3038310b300906035504061302585831153013060355040a0c0c576f726420526f6f742043413112301006035504030c09576f726420526f6f7430820122300d06092a864886f70d01010105000382010f003082010a0282010100c60056a730e6d2dade917ff49ba947c0f1c1fa86b8ed593b8750e33a0906533ef340fba766c44b651a3c7147fa3f35f079cef38021460e90c9797ad562bb40f55b3e06110f260ef27b464408ce7292f0a05e26877a160884ccedb1f713f0d18814f3af8c106daf4f29ff686eb0eeb1f651cfcd9d859858e76959ffaf8b4a49024f3bce07c1b459a490b91b68d81835ad3374eb58f41f04777629df8c98bd060b23fe690504d59a7210a58d9cf96db1ed488778a9f5c46f9f4c68dab1fd049e9ff0f513ec377afa0a1ae8111ca152a232849f48c0a430dacba035405acde5627c2db14d4136b7bf47fc67306f714d949dceed7cc177f4e62ff7404050bc0814310203010001a3423040300f0603551d130101ff040530030101ff300e0603551d0f0101ff040403020106301d0603551d0e04160414388cb6c62fc03946e233be5ce73f7cc63b339497300d06092a864886f70d01010b0500038201010083cf4184f696c6ce57ec495568078f900da2213dc73e442d5d600737201fc0f5007c8495c5aae360a5fc32723bbd332174dc99945b0ff6df8f0c97e3e841c07c1d44c6629aa3a1b51d1e79f2e29964415b4c511e9bcccab77b109b5a5e9aa0cd2c869ddb04311c8609ea5635f071e0ec6c240f353d67457750356ff6c6389b9ca9ad623be885713caad3ebb142403a17683689dac59417e7af8896a96698234383f03878b9c9ab92bd8b0a92924a4fecb20964a05f2f7f23c01671d6f1776bcaaf779de1d98de4783d2b8fb3cddca29d1faedfbd7cc8255a468edbaeca9db4dc719a901609fdbd82383ca75dbb8102fd443a640f87ed864f69fac57e727acbc0"))
n = n + eq("the leaf parses", leaf != 0, true)
n = n + eq("the intermediate parses", itm != 0, true)
n = n + eq("the root parses", root != 0, true)
n = n + eq("leaf notBefore", leaf[10], 1788136049)
n = n + eq("leaf notAfter", leaf[11], 2103496049)
n = n + eq("root notAfter", root[11], 2418856049)
n = n + eq("the leaf is signed ECDSA, by the P-256 intermediate", leaf[3], 2)
n = n + eq("both are signed over SHA-256", leaf[4] + itm[4], 0)
n = n + eq("leaf key is RSA", leaf[12], 0)
n = n + eq("leaf modulus is 2048 bits", len(leaf[13]), 256)
n = n + eq("leaf exponent is 65537", len(leaf[14]), 3)
n = n + eq("the leaf is not a CA", leaf[15], 0)
n = n + eq("the leaf has two SAN names", len(leaf[17]), 2)
n = n + eq("the intermediate is signed RSA, by the root", itm[3], 1)
n = n + eq("intermediate key is P-256", itm[12], 1)
n = n + eq("the intermediate is a CA", itm[15], 1)
n = n + eq("the intermediate has pathlen 0", itm[16], 0)
n = n + eq("the root is a CA", root[15], 1)
n = n + eq("the root has no pathlen", root[16], -1)
n = n + eq("the root has no SAN", root[17], 0)
// Names.
n = n + yes("the exact name", x509_match_host(leaf, "word.example"))
n = n + yes("the exact name, differently cased", x509_match_host(leaf, "WORD.Example"))
n = n + yes("a wildcard match", x509_match_host(leaf, "a.sub.word.example"))
n = n + no("a wildcard across two labels", x509_match_host(leaf, "a.b.sub.word.example"))
n = n + no("the wildcard's own parent", x509_match_host(leaf, "sub.word.example"))
n = n + no("a name not in the certificate", x509_match_host(leaf, "other.example"))
n = n + no("a prefix of a name in the certificate", x509_match_host(leaf, "word.exampl"))
// The chain.
chain = text(2)
chain[0] = leaf
chain[1] = itm
store = text(1)
store[0] = root
t = 1945816049
n = n + yes("the chain", x509_verify_chain(chain, store, "word.example", t))
n = n + yes("the chain, wildcard name", x509_verify_chain(chain, store, "x.sub.word.example", t))
n = n + no("the chain for the wrong host", x509_verify_chain(chain, store, "evil.example", t))
n = n + no("the chain before it is valid", x509_verify_chain(chain, store, "word.example", 1788136048))
n = n + no("the chain after it expires", x509_verify_chain(chain, store, "word.example", 2103496050))
short = text(1)
short[0] = leaf
n = n + no("the leaf without its intermediate", x509_verify_chain(short, store, "word.example", t))
empty = text(0)
n = n + no("the chain against an empty trust store", x509_verify_chain(chain, empty, "word.example", t))
wrongstore = text(1)
wrongstore[0] = itm
// An intermediate placed in the trust store is an anchor: a store says what the
// relying party trusts, and this one says it trusts `itm`. This check used to
// assert the opposite, and what it really tested was an accident: the same
// store accepted [leaf] on its own and rejected [leaf, itm], so the answer
// depended on whether the peer sent a spare copy of the anchor. Go agrees with
// this. openssl wants a self-signed anchor unless told -partial_chain, and that
// divergence is written down in test_x509_profile.sh (D3, D4).
n = n + yes("the chain rooted at the intermediate in the store", x509_verify_chain(chain, wrongstore, "word.example", t))
n = n + no("but not when that intermediate is not in the store", x509_verify_chain(chain, empty, "word.example", t))
rev = text(2)
rev[0] = itm
rev[1] = leaf
n = n + no("the chain in the wrong order", x509_verify_chain(rev, store, "word.example", t))
// A leaf with one byte of a subjectAltName changed ("word.example" to
// "zord.example") still parses. Catching that is the signature's job.
tam = x509_parse(un_hex("308202c130820268a00302010202021002300a06082a8648ce3d0403023040310b300906035504061302585831153013060355040a0c0c576f726420526f6f74204341311a301806035504030c11576f726420496e7465726d656469617465301e170d3236303833313030323732395a170d3336303832383030323732395a3038310b300906035504061302585831123010060355040a0c09576f726420546573743115301306035504030c0c7a6f72642e6578616d706c6530820122300d06092a864886f70d01010105000382010f003082010a0282010100a7aaf98a144da191b7bf0292e3d2365b81ed295d451e7096b01f9579ba74876d2f788f14941fdbd641a20c4768ad18dba80d631aa332955687c2f72ada978ae7d069e5a2996364d3f1cbcbbb02a466c68646f357059381b161eff81be87cd6a5761c0521f6ce05e03848c03c81f652465a202b65802792a9276d16dae4884bc24937a4d9df18666dd8e35484e9396bb334e26354802dc970e458cc0edd9b87a2b80ce3a2f8719d9c98f97b826c2df2eea0f366d2d59e178b319078cc269ba4f50a9ee8c00989824546f4fa017403cd47f24adb12a408176858820525071a1fb3d634edbfa7a6649758578a1f0999d41bcfbc5eaf844746b1296f9cb7db23e7570203010001a3818e30818b300c0603551d130101ff04023000300e0603551d0f0101ff0404030205a0302b0603551d1104243022820c776f72642e6578616d706c6582122a2e7375622e776f72642e6578616d706c65301d0603551d0e04160414c16527cd367356fb98cf652594cdf0e5251936ba301f0603551d23041830168014de901da2d45be7bf51a70c0196c3b7a55ccdd125300a06082a8648ce3d0403020347003044022071c100e21d20d007b112d178dbaff4772af784b8024b72e33149b56aa9db68b5022059f0fcaa2131e6851034af6cb1530bd5b9bb8328d69b3ec7e19945903bbe3c8f"))
n = n + eq("the tampered leaf still parses", tam != 0, true)
n = n + no("the tampered leaf's signature", x509_check_sig(tam, itm))
n = n + yes("the untampered leaf's signature", x509_check_sig(leaf, itm))
n = n + yes("the intermediate's signature", x509_check_sig(itm, root))
n = n + no("the leaf against the root's key", x509_check_sig(leaf, root))
out("x509 (word): " . n . " of 42 checks pass")
if n == 42
    return 0
return 1
