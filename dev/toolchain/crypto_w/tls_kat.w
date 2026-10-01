// TLS 1.3 key schedule (RFC 8446 7.1), cross-checked against a separate Python
// implementation of the same schedule. The inputs are fixed (a stand-in 32-byte
// ECDHE secret 00..1f and two stand-in transcript hashes), so the vectors don't
// depend on any recorded capture. The Early Secret matches RFC 8448's fixed
// no-PSK constant (33ad0a1c...), which ties the whole tree to the standard.
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

check(what, got, want)
    if hex_of(got) == want
        return 1
    err("  FAIL: " . what)
    err("    want " . want)
    err("    got  " . hex_of(got))
    return 0

// A record that doesn't authenticate must open to the number 0 (SPEC 3.3).
check_fail(what, got)
    if got == 0
        return 1
    err("  FAIL: " . what . " should have returned 0, got " . hex_of(got))
    return 0

// A numeric field parsed off the wire.
check_eq(what, got, want)
    if got == want
        return 1
    err("  FAIL: " . what . " want " . want . " got " . got)
    return 0

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

// A server flight with its Finished made again for what it now says: `msgs` are
// the messages ahead of the Finished, `pre` everything hashed before them, and
// `s_hs` the server handshake traffic secret the Finished key comes from.
resign(s_hs, pre, msgs)
    return tls13_concat(msgs, tls13_finished(s_hs, sha256(tls13_concat(pre, msgs))))

n = 0

// The stand-in inputs, the same as tls_ref.py's (the Python script that
// computed these vectors; it isn't in the repo).
ecdhe = bytes(32)
i = 0
loop i < 32
    ecdhe[i] = i
    i = i + 1
th_hs = sha256(str_bytes("ClientHello||ServerHello"))
th_ap = sha256(str_bytes("ClientHello..serverFinished"))

// The empty transcript hash and the no-PSK Early Secret are fixed constants.
n = n + check("empty hash", tls13_empty_hash(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
n = n + check("early secret", tls13_early_secret(), "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a")

// The handshake secret and its two traffic secrets.
hs = tls13_handshake_secret(ecdhe)
n = n + check("handshake secret", hs, "ddbe37614d014a8c19db0a47955ee6930b3ee727c408386ba274344962b0e015")
n = n + check("c hs traffic", tls13_c_hs_traffic(hs, th_hs), "842046b1b8caa22ade9b11955b758a1fb726d6330258baa2fe8310748963d330")
shs = tls13_s_hs_traffic(hs, th_hs)
n = n + check("s hs traffic", shs, "3791938f67a570c59eb02771eb89d61d5b3b234c057993ff5455cccbb7b8030f")

// The master secret and its two application traffic secrets.
ms = tls13_master_secret(hs)
n = n + check("master secret", ms, "055796c9a2f048dd920b01351ba00d131ba528efa37749efb03e31b643c615b2")
n = n + check("c ap traffic", tls13_c_ap_traffic(ms, th_ap), "04f0702eda190c07a32dd7362dfb71e981492a280673869c26771de8623997c2")
n = n + check("s ap traffic", tls13_s_ap_traffic(ms, th_ap), "1047a28cedb68d9f09b7d89067ea088a8aff99386a5fcb9eb8422b96ab250d50")

// Record keys and the Finished key off the server handshake secret.
n = n + check("write key", tls13_write_key(shs, 16), "46e2f00b9a356c72efad5b234bee9933")
n = n + check("write iv", tls13_write_iv(shs), "8adf0e54074241e1ba438e55")
n = n + check("finished key", tls13_finished_key(shs), "07dc012df893459454b2484607452bf905aeb53bea483fd13e0c64913036ec83")

// ---- the record layer (RFC 8446 section 5) ----------------------------------
// The sealed records are cross-checked against a separate ChaCha20-Poly1305
// and AES-128-GCM oracle (Python's `cryptography`, in tls_rec_ref.py, also not
// in the repo) over the same stand-in inputs: a 00..1f ChaCha key, a 00..0f
// AES-128 key, an a0..ab write_iv and the plaintext "hello record layer".
ck = bytes(32)
i = 0
loop i < 32
    ck[i] = i
    i = i + 1
gk = bytes(16)
i = 0
loop i < 16
    gk[i] = i
    i = i + 1
wiv = bytes(12)
i = 0
loop i < 12
    wiv[i] = 160 + i
    i = i + 1
co = str_bytes("hello record layer")

// The framing pieces on their own.
n = n + check("record aad", tls13_aad(len(co) + 1 + 16), "1703030023")
n = n + check("record nonce", tls13_nonce(wiv, 5), "a0a1a2a3a4a5a6a7a8a9aaae")

// Sealing, ChaCha20-Poly1305 (suite 0): seq 0 unpadded, and seq 5 with 4 bytes
// of padding and a handshake content type.
r0 = tls13_seal(0, ck, wiv, 0, co, 23, 0)
n = n + check("seal chacha seq0", r0, "170303002364ce143322c6b0c8c3608170dc969c82f82cc4e843e3c9f1fc25f1f48bddf5534f3986")
r5 = tls13_seal(0, ck, wiv, 5, co, 22, 4)
n = n + check("seal chacha seq5 pad4", r5, "1703030027d8b070d0ab9b069a42540b4b60a53ef87e53f61c27ec47f596e92d3624d8400b3095c1473163fa")

// Sealing, AES-128-GCM (suite 1): seq 3 unpadded.
rg = tls13_seal(1, gk, wiv, 3, co, 23, 0)
n = n + check("seal gcm seq3", rg, "1703030023e60f1b930b4a2a7b9e0f80b0a073be9e44358cae1fb2a45496726ea9dcc669e78d4f9b")

// Opening inverts sealing: the recovered region is content || content_type.
want0 = bytes(len(co) + 1)
i = 0
loop i < len(co)
    want0[i] = co[i]
    i = i + 1
want0[len(co)] = 23
n = n + check("open chacha seq0", tls13_open(0, ck, wiv, 0, r0), hex_of(want0))
// r5 carried content type 22 and four padding bytes; open strips the padding and
// returns content || 22.
want5 = bytes(len(co) + 1)
i = 0
loop i < len(co)
    want5[i] = co[i]
    i = i + 1
want5[len(co)] = 22
n = n + check("open chacha seq5 pad4 strips padding", tls13_open(0, ck, wiv, 5, r5), hex_of(want5))
n = n + check("open gcm seq3", tls13_open(1, gk, wiv, 3, rg), hex_of(want0))

// A tampered ciphertext byte and a wrong sequence number both fail to open.
tam = bytes(len(r0))
i = 0
loop i < len(r0)
    tam[i] = r0[i]
    i = i + 1
tam[10] = tam[10] ^ 255
n = n + check_fail("open tampered", tls13_open(0, ck, wiv, 0, tam))
n = n + check_fail("open wrong seq", tls13_open(0, ck, wiv, 1, r0))

// ---- the handshake message layer (RFC 8446 section 4) -----------------------
// Driven from RFC 8448's "Simple 1-RTT Handshake": the recorded ClientHello and
// ServerHello handshake messages, and the client's ephemeral X25519 private key.
// Parsing the ServerHello, running the key exchange, hashing the transcript and
// deriving the handshake traffic keys must reproduce that trace's published
// secrets exactly, which tests the whole receive path against a real capture.
ch = un_hex("010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d0017001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001")
sh = un_hex("020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304")

// The transcript hash the key schedule consumes is SHA-256 of the two messages
// in order (4.4.1).
th_rfc = sha256(tls13_concat(ch, sh))
n = n + check("rfc transcript CH..SH", th_rfc, "860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8")

// Framing: type, length, body, and that re-wrapping the body reproduces the
// message byte-for-byte.
n = n + check_eq("hs type ServerHello", tls13_hs_type(sh), 2)
n = n + check_eq("hs body length", tls13_hs_len(sh), 86)
shb = tls13_hs_body(sh)
n = n + check("hs re-wrap round-trips", tls13_hs_message(2, shb), hex_of(sh))

// Parse the ServerHello: the negotiated suite (TLS_AES_128_GCM_SHA256 = 0x1301),
// the group (x25519 = 0x001d) and the server's key share.
psh = tls13_parse_server_hello(shb)
n = n + check_eq("parsed cipher suite", psh[0], 4865)
n = n + check_eq("parsed group x25519", psh[1], 29)
n = n + check("parsed server key share", psh[2], "c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f")

// Key exchange with the client's recorded private key reproduces the ECDHE
// secret, and the whole key schedule off it reproduces the trace.
c_priv = un_hex("49af42ba7f7994852d713ef2784bcbcaa7911de26adc5642cb634540e7ea5005")
// The client's own key share is X25519_base(private), the value it put in the
// ClientHello (RFC 8448).
n = n + check("rfc client public key", x25519_base(c_priv), "99381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c")
shared = x25519(c_priv, psh[2])
n = n + check("rfc ecdhe shared secret", shared, "8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d")
hsec = tls13_handshake_secret(shared)
n = n + check("rfc handshake secret", hsec, "1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac")
c_hs_r = tls13_c_hs_traffic(hsec, th_rfc)
n = n + check("rfc c hs traffic", c_hs_r, "b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21")
shs_r = tls13_s_hs_traffic(hsec, th_rfc)
n = n + check("rfc s hs traffic", shs_r, "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38")
n = n + check("rfc server write key", tls13_write_key(shs_r, 16), "3fce516009c21727d0f2e4e86ee403bc")
n = n + check("rfc server write iv", tls13_write_iv(shs_r), "5d313eb2671276ee13000b30")

// A ServerHello truncated mid-extensions must be rejected, not read past its
// end (fuzz_handshake found three such bugs in the old assembly TLS code).
trunc = bytes(20)
i = 0
loop i < 20
    trunc[i] = shb[i]
    i = i + 1
n = n + check_fail("truncated ServerHello", tls13_parse_server_hello(trunc))

// ---- the server flight and Finished (RFC 8446 sections 4.3, 4.4.4) -----------
// Still RFC 8448's trace: the server's second flight, decrypted, is the four
// messages EncryptedExtensions, Certificate, CertificateVerify, Finished back to
// back. Splitting it, verifying the server Finished over the transcript, forming
// the client Finished, and deriving the application traffic secrets must all
// reproduce the published values.
ee  = un_hex("080000240022000a00140012001d00170018001901000101010201030104001c0002400100000000")
crt = un_hex("0b0001b9000001b50001b0308201ac30820115a003020102020102300d06092a864886f70d01010b0500300e310c300a06035504031303727361301e170d3136303733303031323335395a170d3236303733303031323335395a300e310c300a0603550403130372736130819f300d06092a864886f70d010101050003818d0030818902818100b4bb498f8279303d980836399b36c6988c0c68de55e1bdb826d3901a2461eafd2de49a91d015abbc9a95137ace6c1af19eaa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e22a5fda430846748030530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a8002c47428a6d35a8d88d79f7f1e3f0203010001a31a301830090603551d1304023000300b0603551d0f0404030205a0300d06092a864886f70d01010b05000381810085aad2a0e5b9276b908c65f73a7267170618a54c5f8a7b337d2df7a594365417f2eae8f8a58c8f8172f9319cf36b7fd6c55b80f21a03015156726096fd335e5e67f2dbf102702e608ccae6bec1fc63a42a99be5c3eb7107c3c54e9b9eb2bd5203b1c3b84e0a8b2f759409ba3eac9d91d402dcc0cc8f8961229ac9187b42b4de10000")
cv  = un_hex("0f000084080400805a747c5d88fa9bd2e55ab085a61015b7211f824cd484145ab3ff52f1fda8477b0b7abc90db78e2d33a5c141a078653fa6bef780c5ea248eeaaa785c4f394cab6d30bbe8d4859ee511f602957b15411ac027671459e46445c9ea58c181e818e95b8c3fb0bf3278409d3be152a3da5043e063dda65cdf5aea20d53dfacd42f74f3")
sfin = un_hex("140000209b9b141d906337fbd2cbdce71df4deda4ab42c309572cb7fffee5454b78f0718")

// The flight splits into exactly the four expected messages, in order.
flight = tls13_concat(tls13_concat(tls13_concat(ee, crt), cv), sfin)
sp = tls13_hs_split(flight)
n = n + check_eq("flight message count", sp[0], 4)
n = n + check_eq("flight[0] EncryptedExtensions", tls13_hs_type(sp[1]), 8)
n = n + check_eq("flight[1] Certificate", tls13_hs_type(sp[2]), 11)
n = n + check_eq("flight[2] CertificateVerify", tls13_hs_type(sp[3]), 15)
n = n + check_eq("flight[3] Finished", tls13_hs_type(sp[4]), 20)

// The server Finished verifies over the transcript CH..CertificateVerify under
// the server handshake traffic secret, and forging one byte of it fails.
th_cv = sha256(tls13_concat(tls13_concat(tls13_concat(tls13_concat(ch, sh), ee), crt), cv))
n = n + check("rfc server verify_data", tls13_verify_data(shs_r, th_cv), "9b9b141d906337fbd2cbdce71df4deda4ab42c309572cb7fffee5454b78f0718")
n = n + check_eq("server Finished verifies", tls13_check_finished(shs_r, th_cv, sfin), 1)
bad = bytes(len(sfin))
i = 0
loop i < len(sfin)
    bad[i] = sfin[i]
    i = i + 1
bad[10] = bad[10] ^ 255
n = n + check_eq("forged server Finished rejected", tls13_check_finished(shs_r, th_cv, bad), 0)

// The client's Finished is verify_data over the transcript CH..server Finished
// under the client handshake traffic secret (RFC 8448's client Finished).
th_sf = sha256(tls13_concat(tls13_concat(tls13_concat(tls13_concat(tls13_concat(ch, sh), ee), crt), cv), sfin))
n = n + check("rfc transcript CH..serverFinished", th_sf, "9608102a0f1ccc6db6250b7b7e417b1a000eaada3daae4777a7686c9ff83df13")
n = n + check("rfc client Finished message", tls13_finished(c_hs_r, th_sf), "14000020a8ec436d677634ae525ac1fcebe11a039ec17694fac6e98527b642f2edd5ce61")

// The master secret and the application traffic secrets off it, over that same
// CH..serverFinished transcript (RFC 8448).
ms_r = tls13_master_secret(hsec)
n = n + check("rfc master secret", ms_r, "18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919")
n = n + check("rfc c ap traffic", tls13_c_ap_traffic(ms_r, th_sf), "9e40646ce79a7f9dc05af8889bce6552875afa0b06df0087f792ebb7c17504a5")
n = n + check("rfc s ap traffic", tls13_s_ap_traffic(ms_r, th_sf), "a11af9f05531f856ad47116b45a950328204b4f44bfb6b3a4b4f1f3fcb631643")

// A flight with a trailing truncated message does not split.
short_flight = bytes(len(ee) + 3)
i = 0
loop i < len(ee)
    short_flight[i] = ee[i]
    i = i + 1
n = n + check_fail("flight with truncated tail", tls13_hs_split(short_flight))

// ---- the Certificate and CertificateVerify (RFC 8446 4.4.2, 4.4.3) ----------
// The RFC 8448 server signs with a 1024-bit RSA key (rsa_pss_rsae_sha256). The
// Certificate message parses to a one-cert chain, and the CertificateVerify
// signature checks out over 0x20*64 || "TLS 1.3, server CertificateVerify" ||
// 0x00 || Transcript-Hash(ClientHello..Certificate).
chain = tls13_parse_certificate(tls13_hs_body(crt))
n = n + check_eq("certificate chain length", len(chain), 1)
n = n + check_eq("leaf key is rsa", chain[0][12], 0)
th_crt = sha256(tls13_concat(tls13_concat(tls13_concat(ch, sh), ee), crt))
n = n + check("cert-verify transcript CH..Certificate", th_crt, "764d6632b3c35c3f3205e3499ac3edbaabb88295fba751461d3678e2e5ea0687")
n = n + check_eq("server CertificateVerify verifies", tls13_check_cert_verify(chain[0], cv, th_crt, "TLS 1.3, server CertificateVerify"), 1)
// The wrong transcript and a forged signature byte are both rejected.
n = n + check_eq("CertificateVerify over wrong transcript rejected", tls13_check_cert_verify(chain[0], cv, th_sf, "TLS 1.3, server CertificateVerify"), 0)
cvbad = bytes(len(cv))
i = 0
loop i < len(cv)
    cvbad[i] = cv[i]
    i = i + 1
cvbad[30] = cvbad[30] ^ 255
n = n + check_eq("forged CertificateVerify signature rejected", tls13_check_cert_verify(chain[0], cvbad, th_crt, "TLS 1.3, server CertificateVerify"), 0)
// Full authentication also needs a trust root: with an empty store the
// self-issued test certificate is untrusted, so the server is not authenticated
// even though its CertificateVerify signature is good.
empty_roots = text(0)
n = n + check_eq("untrusted chain not authenticated", tls13_authenticate(chain, empty_roots, "rsa", 1500000000, cv, th_crt), 0)

// RFC 8446 4.4.3: an RSA signature in a CertificateVerify must be RSASSA-PSS,
// whatever signature_algorithms lists; rsa_pkcs1_* is offered for signatures
// inside certificates. One 2048-bit key signed the same content both ways
// (openssl dgst, over the transcript above): PSS is taken, and PKCS#1 v1.5 is
// refused although the signature itself is good. It used to be taken.
pk_leaf = x509_parse(un_hex("30820309308201f1a00302010202143791ec32186770ab17fb346c929cd4770fa92249300d06092a864886f70d01010b050030133111300f06035504030c08706b6373312d63763020170d3236303932333038333830325a180f32313236303833303038333830325a30133111300f06035504030c08706b6373312d637630820122300d06092a864886f70d01010105000382010f003082010a02820101009a65b4fcdbc5a886c8cc2a85be8020c1dfbc415175f3d469c3b29cbc809cb9aa8ada50b45699c39ec64f818e0e4e491e1573fcb285e78482a426ef6fa8a0051b7264552fa82200100d19f33e4d0a8e30c6d915a8409531f424e44497290a1eafdf62a92cb7d00d4b33cba7e2f2ff1bb1c51f4126dc2417c0a2016e2d8585d9afca0eac96296b7579fe0ec0f3f8ce1b944c4002bee305b0c78e4ebae8dc14dbd7d006dc1d460a51958d61c74b78ad65edc0c40a71a5d81058c9589dcb2d4e54dde1f9ce7ed3bc9bbb2a589954c869d393fd3d6549cb017e951ad69cae77fb99021ea48974a7459ef0f16de0315a9be51bc6dc69c6cc65fa09657c24c45147e91b0203010001a3533051301d0603551d0e041604141578a30383c70bfc6d0450ad3cf2559f95e05f40301f0603551d230418301680141578a30383c70bfc6d0450ad3cf2559f95e05f40300f0603551d130101ff040530030101ff300d06092a864886f70d01010b050003820101008a85ec54fd6037a5359a723b4a22de275919afde430a498e9e0e76f92d68ee6b4d087de3901b355bb40fd306ed29d6dfa26eddd0857af1077f3f7ac134af9b09654314faad6f28305bdb75e6b69174da5905247b7d325719f34bf562f5846187c08785586bda080851bb7bfab260365396015b2dcc3a3cb888a0f28aea33d497c225886bdea77a133975cdbee16a8356b1a1e254c059be4f86ae28dc10da57012d3d8c64f036f5b2c49c8bdf21adea67fd80b22ca3fcae0ff585c2147c977bb1303093bb1791f326c06092abbaf93dea7fa72f9eed365471ddd2b898c383691392c2b8d8ec9e78997002551d403df5f948e8b2485051fc99b428e28329cc07d9"))
pk_sig1 = un_hex("4210f8e6c59e48afb60bdf1d9a8e8fb9b2ed2fb961317265059a2d9ca7975597ae4171978c76b8de0fb49f0a9628bcd6ab1787848b99d65323cad845dab810b2af5d76ba5c653a3494ab6ac91ec9c05b9a476df6cc5f15f489dae0404a031193f2232da297c5ceac4dbb906ff92e8a2c381f122c51193fddd4e14488f6fce0df0735d41338f56b4cf56ef8b59622c5f5cf8d21dd0521e98f7729212932d80a35b482d27970467fa94a172767ab3ce5a517db486c4f140a7d69df1d7874e5b85be265f12e412342d5dc87e005e728628e72d08f86d2802865a697630055442f706e06f581a084c0e2457eae7ad5ffbcdf40241e0c6566e1debf661f51a61e5728")
pk_sigp = un_hex("4384c4e28b9c27ce6b1139b5b49978308c3b00b8d14f2d67ceb4fa719a55a57c7ddaea0159aa541e8f66639580ca8201ddd09378ca7c541a77abad2a55a1418d0ec77f67cb73a4bac571abc924d226b50ea08b4069c31343f03b5574752e890c933d54d7b8dc4d8dd87fe5ccc7aef6a77e8b200daf96acc0931a226cb2c56ac9854e7ae585955eb6a2386a32fcd4dfb2e3bf1eb390fcb8f916690a8860bc4990b8e31c84e00a1d82aa19a3dc6cdc30baa1b7aafffe875bbeb416d3e41afefdb98a20f38e4333374b0c1f6127df712087101ed293a6ee0737dda963c3fb6c5ba962fd1e827897e623ecc527949c3cf101f625b86cba805b0723ceec8599e97c8a")
pk_ctx = "TLS 1.3, server CertificateVerify"
n = n + check_eq("an RSA-PSS CertificateVerify from a 2048-bit key verifies", tls13_check_cert_verify(pk_leaf, tls13_hs_message(15, tls13_concat(tls13_concat(tls13_u16(2052), tls13_u16(len(pk_sigp))), pk_sigp)), th_crt, pk_ctx), 1)
n = n + check_eq("the same key's PKCS#1 v1.5 signature is a good one", rsa_pkcs1_verify(pk_leaf[13], pk_leaf[14], pk_sig1, tls13_cert_verify_content(pk_ctx, th_crt), 0), 1)
n = n + check_eq("but a PKCS#1 v1.5 CertificateVerify is refused", tls13_check_cert_verify(pk_leaf, tls13_hs_message(15, tls13_concat(tls13_concat(tls13_u16(1025), tls13_u16(len(pk_sig1))), pk_sig1)), th_crt, pk_ctx), 0)

// A certificate after the leaf that doesn't parse is left out of the chain
// instead of failing the whole Certificate message (RFC 8446 4.4.2 asks for
// extraneous ones to be tolerated). The leaf still has to parse. The extra here
// is three bytes of junk standing in for, say, an Ed448 certificate.
cx_entry = copy(tls13_hs_body(crt), 4, len(tls13_hs_body(crt)))
cx_junk = un_hex("0000036162630000")
cx_list = tls13_concat(cx_entry, cx_junk)
cx_body = tls13_concat(un_hex("00"), tls13_concat(un_hex("000000"), cx_list))
cx_body[1] = (len(cx_list) >> 16) & 255
cx_body[2] = (len(cx_list) >> 8) & 255
cx_body[3] = len(cx_list) & 255
cx_chain = tls13_parse_certificate(cx_body)
n = n + check_eq("an extra certificate that doesn't parse is left out", len(cx_chain), 1)
n = n + check_eq("and the leaf is still the leaf", cx_chain[0][12], 0)
cx_list2 = tls13_concat(cx_junk, cx_entry)
cx_body2 = tls13_concat(un_hex("00"), tls13_concat(un_hex("000000"), cx_list2))
cx_body2[1] = (len(cx_list2) >> 16) & 255
cx_body2[2] = (len(cx_list2) >> 8) & 255
cx_body2[3] = len(cx_list2) & 255
n = n + check_fail("a leaf that doesn't parse still fails the message", tls13_parse_certificate(cx_body2))

// ---- the ClientHello encoder and the client driver (RFC 8446 4.1.2, 4.4) -----
// The encoder produces a wire-valid ClientHello for fixed inputs, matching a
// separate encoder cross-checked against a TLS parser (tls_client_hello_ref,
// not in the repo).
sid = bytes(32)
i = 0
loop i < 32
    sid[i] = 255
    i = i + 1
n = n + check("client hello encodes (three groups, ECDSA before RSA)", tls13_client_hello(ecdhe, sid, un_hex("99381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c"), "example.com"), "010000b60303000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0004130313010100006900000010000e00000b6578616d706c652e636f6d000a00080006001d00170018000d00140012040305030603080408050806040105010601002b0003020304003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c")

// The driver, over RFC 8448's recorded ClientHello, private key, ServerHello and
// server flight: derive the handshake keys, then process the flight to the
// client Finished and the application secrets. That's the whole client
// handshake.
dk = tls13_client_handshake_keys(ch, c_priv, sh)
n = n + check_eq("driver negotiated suite", dk[0], 4865)
n = n + check("driver c hs traffic", dk[1], "b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21")
n = n + check("driver s hs traffic", dk[2], "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38")
df = tls13_client_process_flight(ch, sh, flight, dk[3], dk[1], dk[2])
n = n + check("driver client Finished", df[0], "14000020a8ec436d677634ae525ac1fcebe11a039ec17694fac6e98527b642f2edd5ce61")
n = n + check("driver c ap traffic", df[1], "9e40646ce79a7f9dc05af8889bce6552875afa0b06df0087f792ebb7c17504a5")
n = n + check("driver s ap traffic", df[2], "a11af9f05531f856ad47116b45a950328204b4f44bfb6b3a4b4f1f3fcb631643")
// The flight it hands back authenticates: the returned leaf's CertificateVerify
// signs the returned through-Certificate transcript.
n = n + check_eq("driver flight authenticates", tls13_check_cert_verify(df[3][0], df[4], df[5], "TLS 1.3, server CertificateVerify"), 1)
// A tampered server Finished makes the driver reject the flight.
flight_bad = tls13_concat(tls13_concat(tls13_concat(ee, crt), cv), bad)
n = n + check_fail("driver rejects tampered flight", tls13_client_process_flight(ch, sh, flight_bad, dk[3], dk[1], dk[2]))

// ---- HelloRetryRequest (RFC 8446 4.1.3, 4.1.4, 4.4.1) -----------------------
// A HelloRetryRequest is a ServerHello whose random is the SHA-256 of the
// string "HelloRetryRequest". There's no other flag, so the detector checks
// only that. This one names secp256r1 (23) and carries a cookie.
hrr_body = un_hex("0303cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c20ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff1301000015002b00020304003300020017002c00050003616263")
n = n + check_eq("a HelloRetryRequest is recognised", tls13_is_hrr(hrr_body), 1)
hp = tls13_parse_hrr(hrr_body)
n = n + check_eq("the retry names its group", hp[0], 23)
n = n + check("the cookie is taken verbatim", hp[1], "616263")
n = n + check_eq("the retry names its suite", hp[2], 4865)
n = n + check_eq("a retry this client can answer", tls13_hrr_check(hp, sid, 29), 1)
// RFC 8446 4.1.4 and 4.2.8: a retry the client must refuse instead of answer.
// Each of these used to get a second ClientHello.
n = n + check_eq("a retry for the group already sent is refused", tls13_hrr_check(tls13_parse_hrr(un_hex("0303cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c20ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff1301000015002b0002030400330002001d002c00050003616263")), sid, 29), 0)
n = n + check_eq("a retry for a group never offered is refused", tls13_hrr_check(tls13_parse_hrr(un_hex("0303cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c20ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff1301000015002b00020304003300020019002c00050003616263")), sid, 29), 0)
n = n + check_eq("a retry naming TLS_AES_256_GCM_SHA384 is refused", tls13_hrr_check(tls13_parse_hrr(un_hex("0303cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c20ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff1302000015002b00020304003300020017002c00050003616263")), sid, 29), 0)
n = n + check_eq("a retry naming TLS_AES_128_CCM_8_SHA256 is refused", tls13_hrr_check(tls13_parse_hrr(un_hex("0303cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c20ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff1305000015002b00020304003300020017002c00050003616263")), sid, 29), 0)
n = n + check_eq("a retry echoing another session id is refused", tls13_hrr_check(hp, bytes(32), 29), 0)
n = n + check_fail("a retry whose legacy_version is not 0x0303 is not one", tls13_parse_hrr(un_hex("0301cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c20ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff1301000015002b00020304003300020017002c00050003616263")))
n = n + check_fail("a retry without supported_versions is not a TLS 1.3 one", tls13_parse_hrr(un_hex("0303cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c20ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff130100000f003300020017002c00050003616263")))

// The ServerHello is taken out of its record whole, or not at all: a length that
// runs past the record, or a message that isn't a ServerHello, is refused before
// anything reads the body. The first used to reach len() as the number 0, and a
// 13-byte reply stopped the program with a fault.
n = n + check_eq("a ServerHello's body is taken whole", len(tls13_server_hello_body(sh)), 86)
n = n + check_fail("a ServerHello whose length runs past its record", tls13_server_hello_body(un_hex("02ffffff03030000")))
n = n + check_fail("a message that isn't a ServerHello", tls13_server_hello_body(ee))
// RFC 8446 4.1.3: the ServerHello echoes the session id the ClientHello sent, and
// a client that gets back anything else aborts. RFC 8448's ClientHello sent an
// empty one; the retry above echoes 32 bytes of 0xff.
n = n + check_eq("RFC 8448's ServerHello echoes the empty session id", tls13_echoes_session(tls13_hs_body(sh), bytes(0)), 1)
n = n + check_eq("and not a 32-byte one it was never sent", tls13_echoes_session(tls13_hs_body(sh), sid), 0)
n = n + check_eq("a body echoing the id that was sent", tls13_echoes_session(hrr_body, sid), 1)
n = n + check_eq("the same body against another id", tls13_echoes_session(hrr_body, bytes(32)), 0)
n = n + check_eq("a body cut off inside the id", tls13_echoes_session(copy(hrr_body, 0, 50), sid), 0)

// An ordinary ServerHello must not be taken for a retry.
n = n + check_eq("a real ServerHello is not a retry", tls13_is_hrr(tls13_hs_body(sh)), 0)

// 4.4.1: the first ClientHello is replaced in the transcript by
// message_hash || 00 00 20 || Hash(ClientHello1).
synth = tls13_hrr_transcript(ch, un_hex("0102"), un_hex("0304"))
n = n + check("the retry transcript is the message_hash construct",
    copy(synth, 0, 4), "fe000020")
n = n + check_eq("and it carries the hash of the first ClientHello",
    len(synth), 4 + 32 + 2 + 2)

// A key share for each group the retry can name, at the right width.
n = n + check_eq("a secp256r1 key share is an uncompressed point", len(ec_pubkey(1, un_hex("f928b4f13481eac743a313942fc59b832a3a3297db56e8495211360dde89b003"))), 65)
n = n + check_eq("a secp384r1 key share is an uncompressed point", len(ec_pubkey(2, un_hex("b75f9cb9294ecdb118fa19f937fc3f6f1e3172ac56ba0fb20c11d08dc8f60ccfa014ed94f28c9cfaec484d2156c51511"))), 97)

// The ClientHello offers all three groups, so a server has something to ask for.
ch3 = tls13_client_hello_g(ecdhe, sid, 23, un_hex("04"), "h", 0)
n = n + check_eq("a retry ClientHello encodes", tls13_hs_type(ch3), 1)

// The second flight in full, pinned the same way the first one is. A retry
// differs from a first flight in two places (4.1.2): the key_share carries the
// group the server named (here secp256r1, so a 65-byte uncompressed point
// instead of a 32-byte X25519 share), and the server's cookie is echoed back
// verbatim in extension 44. Everything else, including the offered suites,
// groups and signature schemes, is byte-for-byte what the first flight
// offered, which is what SPEC 12.2's surface table states and
// dev/toolchain/test_tls_surface.sh checks that table against.
ch4 = tls13_client_hello_g(ecdhe, sid, 23, ec_pubkey(1, un_hex("f928b4f13481eac743a313942fc59b832a3a3297db56e8495211360dde89b003")), "example.com", un_hex("616263"))
n = n + check("a retry ClientHello is the first flight plus a P-256 share and the cookie", ch4, "010000e00303000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0004130313010100009300000010000e00000b6578616d706c652e636f6d000a00080006001d00170018000d00140012040305030603080408050806040105010601002b00030203040033004700450017004104be7b6a39f87c53b86b936b5b4de55fc444f47cbd5cb85b0a0eb29dfbfe3806cf4b32640ae828f76264cc0822b84285608746f67835caa9b9a26c60efb5dec7e7002c00050003616263")

// ---- CertificateRequest (RFC 8446 4.3.2, 4.4.2) ------------------------------
// RFC 8448 section 6, "Client Authentication": a server that asks the client to
// authenticate too, with a CertificateRequest between its EncryptedExtensions
// and its Certificate, and an ECDSA P-256 certificate of its own. Up to the
// server's Finished every value below is the trace's.
//
// The trace's client has a certificate to send. This one has none, and answers
// the way RFC 8446 4.4.2 says such a client does: a Certificate with an empty
// list, echoing the request's context, no CertificateVerify, then its Finished
// over a transcript that ends with that Certificate. That reply isn't in the
// trace, so it's pinned to a separate computation instead (Python's hashlib
// and hmac over the trace's messages and its published client Finished key,
// sharing no code with word), and the trace's own client Finished is
// reproduced beside it, which is the same rule with a certificate in it.
//
// This client used to not recognise a five-message flight, so against a
// server that asks (openssl s_server -verify 1, or -Verify 1) every fetch
// waited out the 30 s idle deadline and answered none.
ch6 = un_hex("010000bc03036a472236328b83af40386d3a3e1f1ce624fa4ed89ab865a4ff0f4144ce3ae2330000061301130313020100008d0000000b0009000006736572766572ff01000100000a00140012001d00170018001901000101010201030104003300260024001d0020089cc2671f738d9a671e5b2e464981d05b76e361aa22aea91f1d49ca10a7a362002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001")
sh6 = un_hex("0200005603033b50fdf1c3d572e40e68953e7fff4e2758459c59afa0582c0ea032874255fe6e00130100002e00330024001d00206c2e50e865919a6b5a12dfaf918f92b442567b0f89bc54478c6921366658f062002b00020304")
ee6 = un_hex("080000240022000a00140012001d00170018001901000101010201030104001c0002400100000000")
cr6 = un_hex("0d000027000024000d0020001e040305030603020308040805080604010501060102010402050206020202")
crt6 = un_hex("0b00013b000001370001323082012e3081d5a003020102020107300a06082a8648ce3d04030230133111300f060355040313086563647361323536301e170d3136303733303031323430305a170d3236303733303031323430305a30133111300f0603550403130865636473613235363059301306072a8648ce3d020106082a8648ce3d0301070342000408d530161575f4cfe7f154ee3448180086001e88431a79ee62ee6e2f83ef38ba61e9fb37f34e007a7df4d2f5b56d1f04ece45d621f468406f5c3a15158948dd0a31a301830090603551d1304023000300b0603551d0f040403020780300a06082a8648ce3d0403020348003045022100df30fd4507f5edd22c1a6ff86db479ca693feeca3b71b3f9ef556b2937c0594d022062e2a47250d320fea83c7e2dcb5b76a50e0200c09adbd13fee946e513e011d110000")
cv6 = un_hex("0f00004b040300473045022100d7a4d34bd54f55fee1a89625678c3dd5e5f60dac73ec940c5c7b9304a02084a90220289f595ed488b9ac689a3d192b1a8bb38f34af7874c059c9806a1f38269353e8")
sfin6 = un_hex("1400002093b70cdf4781985b96345caac701b4e750d3042df1a689d8faca812251113c11")
flight6 = tls13_concat(tls13_concat(tls13_concat(tls13_concat(ee6, cr6), crt6), cv6), sfin6)

// The handshake keys, off the trace's ClientHello, ServerHello and client key.
dk6 = tls13_client_handshake_keys(ch6, un_hex("c040b2bb8f3addd20fd4058c547003a3c6f9c1cd915d5e535c87d8d191aaf071"), sh6)
n = n + check("rfc6 c hs traffic", dk6[1], "cec7a30c6872070f22a7eeb065768db67c45e29533db879908ce6dc66f5911de")
n = n + check("rfc6 s hs traffic", dk6[2], "8b02d3c00442a2722c4098ebe8675b23e801510f0d7ed778d8eb0b8f42a19a5e")

// The server's second flight as it crossed the wire: one AES-128-GCM record
// that opens, under the server handshake keys, to exactly the five messages and
// the handshake content type.
rec6 = un_hex("17030302166d0a7ac079b32a94aa68c4e2893e8bd0d3c185f549c236fbbce3d647f08f3c94a2bf424d8708883605ad8955f97718b0213dead13dfb23ebb8381da582756612bcb5a5d40847719fbe9f179bfae656f3ecfd59a4c0d35132ce418a7e46f6b6a60622f8a6c06b28d83360163563be9c37f97eb902326924a72b3ed8c8381277d1581cab9c3715ac2401398467ad7ebfab3d0c3419e750104f7d62c5027901f2e4cd4ca5b8071eb03d3c732d83215066dfc4d291d4c1ff3b8d7e4298f677d4d51dea1168d8f16cb27ba40266313a1fedf9e23cc77f765450f9e96f05d08f3da245b14d4946f07ec81eed6d56f26bd574f0b7f7c7047037c16fce3b23754e662fad73e2b7213f6af296769c99a1d38e6232e0ec8dc4f84d6aa6f7de3887be0057862f9018e0ab396705aa4090ab5f2dff6325a557e7320d4effd46bb4f997d163207cce6665294aa4465541e3fe37ee7350659ea550d6dcb6af3c518852c7a14c3cc15bc32b3273bdf1751da184203135b117d300204fb12d58ca9ac34b68eca27030832f7a4b46d2a55757f63fe8f6e85ac47469e6198da88a64586bf23c69590de822263be75fd836847240c48f8c145cd6bd698962e7edc234ebe59231351eef8d7652cf3b08ab3af6e5ec74c58a8da34b39f9b0d6c4279a9a1f82071729e7059dd7f7b95b9433c4684ce1891a6d33432d52eddb0b8cee9181d403eccc12991f1ad4aa62c36049713a7bb135fdda6661a05a93f8c16f")
n = n + check("rfc6 the recorded flight opens to its five messages", tls13_open(1, tls13_write_key(dk6[2], 16), tls13_write_iv(dk6[2]), 0, rec6), hex_of(tls13_concat(flight6, un_hex("16"))))
sp6 = tls13_hs_split(flight6)
n = n + check_eq("a flight with a CertificateRequest has five messages", sp6[0], 5)
n = n + check_eq("the request is the second of them", tls13_hs_type(sp6[2]), 13)
n = n + check_eq("and the flight is complete at its Finished", tls13_flight_complete(flight6), 1)

// The driver takes it. The request is in the transcript the server's Finished
// MACs and its CertificateVerify signs, so the Finished verifying at all shows
// the request went in, and the CertificateVerify (ECDSA P-256 over
// CH..Certificate) shows it went in in the right place. The application
// secrets are taken at the server's Finished, and they're the trace's.
df6 = tls13_client_process_flight(ch6, sh6, flight6, dk6[3], dk6[1], dk6[2])
n = n + check("rfc6 c ap traffic", df6[1], "73c2e890fa8d067258d6d50fa92fe456b098cf00d9727eed91e8892ef4e6f860")
n = n + check("rfc6 s ap traffic", df6[2], "c49a91faf57f8c545d5048a015bf849ff63942e4a7edcd319f8b438a97c52e21")
n = n + check_eq("rfc6 server CertificateVerify (ECDSA P-256) verifies over the request", tls13_check_cert_verify(df6[3][0], df6[4], df6[5], "TLS 1.3, server CertificateVerify"), 1)

// This client's reply: the empty Certificate, then the Finished over
// CH..server Finished || that Certificate. The oracle, to recompute it:
// HMAC-SHA256 keyed with the client finished key the trace publishes
// (4fddd76b...cbcbf6), over SHA-256 of the trace's ClientHello, ServerHello
// and five flight messages followed by 0b00000400000000.
n = n + check("the reply is an empty Certificate, then the Finished over it", df6[0], "0b00000400000000140000201dd3e2e214c1e24d0a0bb2f2069b9042402552bcf2290a991440bdd6d948b21f")

// The trace's own client, which had a certificate: the same rule, one
// Certificate and one CertificateVerify on, is RFC 8448's client Finished.
th6 = tls13_concat(tls13_concat(ch6, sh6), flight6)
ccrt6 = un_hex("0b0001bf000001bb0001b6308201b23082011ba003020102020101300d06092a864886f70d01010b05003011310f300d06035504031306636c69656e74301e170d3136303733303031323335395a170d3236303733303031323335395a3011310f300d06035504031306636c69656e7430819f300d06092a864886f70d010101050003818d0030818902818100c38175e004a68d093f823b9c379d201fbc0bb7a1c791905e3fbf76847e44e751ebbcd360bd945c81e5222bcc8846d3a8a0f93e9bf5bebabd92edf1de1ff19021703e7ab6c0901513f97e39b111f09c9348971c7b211984a754cd45fe095af0ea4236829bccf7a7fe9b2888e78ab477690a5b9e1ccbe91c6a4a0f97a7e02842010203010001a31a301830090603551d1304023000300b0603551d0f040403020780300d06092a864886f70d01010b0500038181001a7a5a018532b022af0767d486160cff2d167a1915d23835b54594916dc680be5d2e626076c5d52722ebcc775d7d99f980be2fc94d34acf6cc00ba90cbcfb0608aa1e7e3971ef0c07a41d47ad8345d1f81fe418a1cf41054429fd217bd777dc1cf08f05df90799c659361e0f1a8ee4ac0f7897420bdbc823da80a2f2ba23081c0000")
ccv6 = un_hex("0f00008408040080186b2223b503a759c35dba0e9721b4b579138d5f0f5e6ec7feaaf27f3ad7f386c2c7bd7cb2be52fbf5ed8393f406ee79369692ec7ac695651d858219e672a8eb7b2a677b640b46ab630edc5f3f2f8272b9c0d906f81f84ddc5b8c7bcf955c78a3cf99e5016f73e04eb7dfcb28833f13e8f75ec2ff3581e2f098ad4157fd6d6ad")
n = n + check("rfc6 the trace's client Finished, over its Certificate and CertificateVerify", tls13_finished(dk6[1], sha256(tls13_concat(tls13_concat(th6, ccrt6), ccv6))), "140000209afe2ba2f63a09d229d8a429e5b37ffd9fcc73bdb5911b82425972aa2892440f")

// Leave the request out and the transcript isn't the one the server signed:
// its Finished no longer verifies, and the flight is refused.
n = n + check_fail("a flight with its request dropped is refused", tls13_client_process_flight(ch6, sh6, tls13_concat(tls13_concat(tls13_concat(ee6, crt6), cv6), sfin6), dk6[3], dk6[1], dk6[2]))

// The rest are refused for their shape alone. Any change to a flight breaks the
// trace's Finished, which would refuse it whatever the shape checks did, so
// each has its Finished made again for what it now says (resign, with the
// server handshake secret the trace publishes): the MAC verifies, and only the
// shape is left to refuse it. A request anywhere but second, a second message
// that isn't a request, and a request whose lengths are wrong.
chsh6 = tls13_concat(ch6, sh6)
n = n + check_fail("a request after the Certificate is refused", tls13_client_process_flight(ch6, sh6, resign(dk6[2], chsh6, tls13_concat(tls13_concat(tls13_concat(ee6, crt6), cr6), cv6)), dk6[3], dk6[1], dk6[2]))
n = n + check_fail("a second message that is not a request is refused", tls13_client_process_flight(ch6, sh6, resign(dk6[2], chsh6, tls13_concat(tls13_concat(tls13_concat(ee6, tls13_hs_message(14, tls13_hs_body(cr6))), crt6), cv6)), dk6[3], dk6[1], dk6[2]))
n = n + check_fail("a flight carrying a malformed request is refused", tls13_client_process_flight(ch6, sh6, resign(dk6[2], chsh6, tls13_concat(tls13_concat(tls13_concat(ee6, un_hex("0d000003000008")), crt6), cv6)), dk6[3], dk6[1], dk6[2]))
// And the control that shows resign works, so the three above aren't passing
// on a MAC that fails anyway: re-signed and well formed, with a context in its
// request, the flight is taken, and the context comes back in the reply.
cr6_ctx = tls13_hs_message(13, tls13_concat(un_hex("03616263"), copy(tls13_hs_body(cr6), 1)))
df6x = tls13_client_process_flight(ch6, sh6, resign(dk6[2], chsh6, tls13_concat(tls13_concat(tls13_concat(ee6, cr6_ctx), crt6), cv6)), dk6[3], dk6[1], dk6[2])
n = n + check("re-signed and well formed, it is taken, and its context comes back", copy(df6x[0], 0, 11), "0b00000703616263000000")

// The Certificate the reply opens with, on its own: the context echoed and a
// zero-length list. Empty in a handshake; a context a server does send comes
// back as it was given.
n = n + check("an empty Certificate", tls13_empty_certificate(bytes(0)), "0b00000400000000")
n = n + check("an empty Certificate echoes the request's context", tls13_empty_certificate(str_bytes("abc")), "0b00000703616263000000")
n = n + check("a request's context is taken verbatim", tls13_parse_cert_request(un_hex("03616263000400000000")), "616263")

// A request is bounded like everything else a server sends: a context or an
// extension block that runs past the end, an extension block shorter than the
// extensions after it, an extension cut short, and a byte left over, inside the
// extension block or after it, are all malformed.
n = n + check_fail("a request too short to hold its lengths", tls13_parse_cert_request(un_hex("0000")))
n = n + check_fail("a request whose context runs past its end", tls13_parse_cert_request(un_hex("05616263000000")))
n = n + check_fail("a request whose extensions run past its end", tls13_parse_cert_request(un_hex("00000800000000")))
n = n + check_fail("a request whose extension block is shorter than its extensions", tls13_parse_cert_request(un_hex("000000000d0000")))
n = n + check_fail("a request with an extension cut short", tls13_parse_cert_request(un_hex("000006000d0004000000")))
n = n + check_fail("a request with a byte after its extensions", tls13_parse_cert_request(un_hex("0000040000000000")))
n = n + check_fail("a request with a stray byte among its extensions", tls13_parse_cert_request(un_hex("0000050000000000")))

// Whether a flight is over, which the driver asks on every record: once a whole
// Finished has arrived, and not before. A flight that's over is over whether or
// not it's acceptable (the tampered one is complete, and so is one with bytes
// after its Finished), so the driver refuses it there instead of reading on for
// bytes the server is never going to send.
n = n + check_eq("the RFC 8448 section 3 flight is complete", tls13_flight_complete(flight), 1)
n = n + check_eq("a flight without its Finished is not", tls13_flight_complete(tls13_concat(tls13_concat(tls13_concat(ee6, cr6), crt6), cv6)), 0)
n = n + check_eq("a flight cut off inside its Finished is not", tls13_flight_complete(copy(flight6, 0, len(flight6) - 1)), 0)
n = n + check_eq("an empty flight is not", tls13_flight_complete(bytes(0)), 0)
n = n + check_eq("a tampered flight is complete, so it is refused, not waited on", tls13_flight_complete(flight_bad), 1)
n = n + check_eq("a flight with a byte after its Finished is complete", tls13_flight_complete(tls13_concat(flight6, un_hex("00"))), 1)
n = n + check_fail("and refused", tls13_client_process_flight(ch6, sh6, tls13_concat(flight6, un_hex("00")), dk6[3], dk6[1], dk6[2]))
n = n + check_eq("a flight with a message after its Finished is complete", tls13_flight_complete(tls13_concat(flight6, ee6)), 1)
n = n + check_fail("and refused too", tls13_client_process_flight(ch6, sh6, tls13_concat(flight6, ee6), dk6[3], dk6[1], dk6[2]))

out("tls key schedule + record + handshake + flight + cert + client + retry + certificate request (word): " . n . " of 134 vectors match")
if n == 134
    return 0
return 1
