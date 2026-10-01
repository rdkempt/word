// ECDSA verification against signatures openssl produced. P-256 first: two keys,
// four signatures on the same message with the same key (ECDSA picks a fresh
// nonce each time, so they're four different signatures of one digest), and
// one each over a SHA-384 and a SHA-512 digest, where e is the leftmost 256
// bits. Every one of them was also checked by a separate Python ECDSA before it
// was written down here.
//
// Then the rejections, which matter most in a verifier: a flipped bit in r, in
// s, in the digest and in the public key's y-coordinate; r or s zero or equal
// to the group order; a signature offered against the other key; and a public
// key that isn't a point on the curve.
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
pub = un_hex("04cb9f39c4296ef3c274d128605275539206dabfef1e36f9383203a9b5a3422e2714a9b00bbf3dfe05a5712e6ef539fdddfb128f4ea64449de5b83ce7e8114727d")
dg = un_hex("d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
r = un_hex("5c6d82468ff4db70720fc7d771ca4bba2daa815754af7b4cfce7334c13570080")
s = un_hex("2da52548da0b8e3ef0f9721324f879fd786a4949b3e97660d3e6c44d804bc5ef")
n = n + yes("ecs1_1.der", ecdsa_verify(1, pub, dg, r, s))
n = n + no("flipped r", ecdsa_verify(1, pub, dg, un_hex("5c6d82468ff4db70720fcfd771ca4bba2daa815754af7b4cfce7334c13570080"), s))
n = n + no("flipped s", ecdsa_verify(1, pub, dg, r, un_hex("2da52548da0b8e3ef0f9721324f879fd786a4949bbe97660d3e6c44d804bc5ef")))
n = n + no("flipped digest", ecdsa_verify(1, pub, un_hex("d7a8fbbb07d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"), r, s))
n = n + no("flipped pubkey y", ecdsa_verify(1, un_hex("04cb9f39c4296ef3c274d128605275539206dabfef1e36f9383203a9b5a3422e2714a9b00bbf3dfe0da5712e6ef539fdddfb128f4ea64449de5b83ce7e8114727d"), dg, r, s))
n = n + no("r zero", ecdsa_verify(1, pub, dg, un_hex("0000000000000000000000000000000000000000000000000000000000000000"), s))
n = n + no("s zero", ecdsa_verify(1, pub, dg, r, un_hex("0000000000000000000000000000000000000000000000000000000000000000")))
n = n + no("r equal to the order", ecdsa_verify(1, pub, dg, un_hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"), s))
n = n + no("s equal to the order", ecdsa_verify(1, pub, dg, r, un_hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")))
n = n + no("truncated public key", ecdsa_verify(1, un_hex("04cb9f39c4296ef3c274d128605275539206dabfef1e36f9383203a9b5a3422e2714a9b00bbf3dfe05a5712e6ef539fdddfb128f4ea64449de5b83ce7e811472"), dg, r, s))
n = n + no("compressed public key", ecdsa_verify(1, un_hex("02cb9f39c4296ef3c274d128605275539206dabfef1e36f9383203a9b5a3422e2714a9b00bbf3dfe05a5712e6ef539fdddfb128f4ea64449de5b83ce7e8114727d"), dg, r, s))
pub = un_hex("04cb9f39c4296ef3c274d128605275539206dabfef1e36f9383203a9b5a3422e2714a9b00bbf3dfe05a5712e6ef539fdddfb128f4ea64449de5b83ce7e8114727d")
dg = un_hex("d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
r = un_hex("912776d724047879a0fdf778a406a3a475011e851844b2ffe516920b73992ccb")
s = un_hex("6a757a3f55401609beee583e68485bb304a3b67812b32fe35bd8234e86b09d2e")
n = n + yes("ecs1_2.der", ecdsa_verify(1, pub, dg, r, s))
pub = un_hex("04cb9f39c4296ef3c274d128605275539206dabfef1e36f9383203a9b5a3422e2714a9b00bbf3dfe05a5712e6ef539fdddfb128f4ea64449de5b83ce7e8114727d")
dg = un_hex("d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
r = un_hex("1ce8f2e02092988b43913eae2526a4e30204b00212eef0cdc61259a8bbc30a13")
s = un_hex("514819ce024d4539015620a576f75144851d53a43ce8be6919a840ac0aec0d0d")
n = n + yes("ecs1_3.der", ecdsa_verify(1, pub, dg, r, s))
pub = un_hex("04cb9f39c4296ef3c274d128605275539206dabfef1e36f9383203a9b5a3422e2714a9b00bbf3dfe05a5712e6ef539fdddfb128f4ea64449de5b83ce7e8114727d")
dg = un_hex("d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
r = un_hex("f27d2979f955bfad35b8d45c5105a4c5aeeb0bc689cecfc718bbd4ace2d204b0")
s = un_hex("92b3ce27b3e8882757f52bb98f96dc5346f00298b1ee31a1a39cf2296dd1b077")
n = n + yes("ecs1_4.der", ecdsa_verify(1, pub, dg, r, s))
pub = un_hex("04303e98378bd9d3da12a806a5835a832b05a866dbeaae11964c160563b276040e34b0507dcba2e21ad6082bea574a2c788b34d1cbd73ccc8d86fc7058aee33c2b")
dg = un_hex("d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
r = un_hex("e1c483356accba2ef2777ff145c3508510e3d3aa55a539cc622171904c2b0482")
s = un_hex("b0ab8054d5bc82ba72c9e67e90be55e323c05d5820ba8b36045ddcc7da4856ff")
n = n + yes("ecs2_1.der", ecdsa_verify(1, pub, dg, r, s))
pub = un_hex("04303e98378bd9d3da12a806a5835a832b05a866dbeaae11964c160563b276040e34b0507dcba2e21ad6082bea574a2c788b34d1cbd73ccc8d86fc7058aee33c2b")
dg = un_hex("d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
r = un_hex("6eeb7eb692c50135e2ddff30c00ef1fffc30f904dd4ba9eb7028cd6ff8302570")
s = un_hex("4edc55175652b1fbad689e9da585ff690895cde20ecd8551a27cba9590d076d7")
n = n + yes("ecs2_2.der", ecdsa_verify(1, pub, dg, r, s))
pub = un_hex("04cb9f39c4296ef3c274d128605275539206dabfef1e36f9383203a9b5a3422e2714a9b00bbf3dfe05a5712e6ef539fdddfb128f4ea64449de5b83ce7e8114727d")
dg = un_hex("ca737f1014a48f4c0b6dd43cb177b0afd9e5169367544c494011e3317dbf9a509cb1e5dc1e85a941bbee3d7f2afbc9b1")
r = un_hex("66d5dac6f3ea8e098ccbf15da6b4d3c2ef8a06b5f214a9598e13be1e07f2570a")
s = un_hex("a36389db5df1a6315a648868fb23ee9972f427bc8298a1be43a74b87da2a8b21")
n = n + yes("ecs384.der", ecdsa_verify(1, pub, dg, r, s))
pub = un_hex("04cb9f39c4296ef3c274d128605275539206dabfef1e36f9383203a9b5a3422e2714a9b00bbf3dfe05a5712e6ef539fdddfb128f4ea64449de5b83ce7e8114727d")
dg = un_hex("07e547d9586f6a73f73fbac0435ed76951218fb7d0c8d788a309d785436bbb642e93a252a954f23912547d1e8a3b5ed6e1bfd7097821233fa0538f3db854fee6")
r = un_hex("7dea193d9edb0f15d79ef31fa86b134ec7a12642d2e8efb760329c53fbfb9ea9")
s = un_hex("6d5766256919f5b9e08f9e5c009761397471f4c3cbe6e82c17df469c8e594e14")
n = n + yes("ecs512.der", ecdsa_verify(1, pub, dg, r, s))
n = n + no("signature offered against the other key", ecdsa_verify(1, un_hex("04303e98378bd9d3da12a806a5835a832b05a866dbeaae11964c160563b276040e34b0507dcba2e21ad6082bea574a2c788b34d1cbd73ccc8d86fc7058aee33c2b"), un_hex("d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"), un_hex("5c6d82468ff4db70720fc7d771ca4bba2daa815754af7b4cfce7334c13570080"), un_hex("2da52548da0b8e3ef0f9721324f879fd786a4949b3e97660d3e6c44d804bc5ef")))
// P-384 and P-521, three digest lengths each: SHA-256 and SHA-384 are shorter
// than P-521's order and pass through whole, and SHA-512 against P-384 is the
// case where e is the leftmost 384 bits of a 512-bit digest. Same source:
// openssl signed them, and a separate Python ECDSA verified them.
pub = un_hex("04f755bfe1702f393bd403b910bdc5a67799a26b53620eee9f979da07bdd7541c9d7fb1372f9e6036f46b22128c894078686d1fef2f0a8bd7c4ef275eba02a5a26184b687a6b329f45efb4a1ddb3d4721947b2892cdcf15abfef59a897d0c0074d")
dg = un_hex("d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
r = un_hex("51c1eb16cc040d9774b478089c2abe7b44e1461abc3f9299a214a5c32bc0b222a4df1fb16509df49b9f8e35b71008449")
s = un_hex("fa07686ebfcdbe0299e718476092589dc9e5b5d16c844104689f09398c114ceebe9af6afb577fb9a01492cdc43271e0c")
n = n + yes("secp384r1 sha256", ecdsa_verify(2, pub, dg, r, s))
n = n + no("secp384r1 sha256, flipped s", ecdsa_verify(2, pub, dg, r, un_hex("fa07686ebfcdbe1299e718476092589dc9e5b5d16c844104689f09398c114ceebe9af6afb577fb9a01492cdc43271e0c")))
n = n + no("secp384r1 sha256, on the wrong curve", ecdsa_verify(1, pub, dg, r, s))
pub = un_hex("04f755bfe1702f393bd403b910bdc5a67799a26b53620eee9f979da07bdd7541c9d7fb1372f9e6036f46b22128c894078686d1fef2f0a8bd7c4ef275eba02a5a26184b687a6b329f45efb4a1ddb3d4721947b2892cdcf15abfef59a897d0c0074d")
dg = un_hex("ca737f1014a48f4c0b6dd43cb177b0afd9e5169367544c494011e3317dbf9a509cb1e5dc1e85a941bbee3d7f2afbc9b1")
r = un_hex("3352d50d98872772ff9d6554cc80305b5b7c97a55eb255fcd155710568778db012ba8618152e7a9a271d489e741309a6")
s = un_hex("03c68f7c51c3aee24a5de75a6b5a6fe020dc73c14a7579a1541e4a16dceb6488e3ecfcda5101235b0cf6b06feda8d754")
n = n + yes("secp384r1 sha384", ecdsa_verify(2, pub, dg, r, s))
n = n + no("secp384r1 sha384, flipped s", ecdsa_verify(2, pub, dg, r, un_hex("03c68f7c51c3aef24a5de75a6b5a6fe020dc73c14a7579a1541e4a16dceb6488e3ecfcda5101235b0cf6b06feda8d754")))
n = n + no("secp384r1 sha384, on the wrong curve", ecdsa_verify(1, pub, dg, r, s))
pub = un_hex("04f755bfe1702f393bd403b910bdc5a67799a26b53620eee9f979da07bdd7541c9d7fb1372f9e6036f46b22128c894078686d1fef2f0a8bd7c4ef275eba02a5a26184b687a6b329f45efb4a1ddb3d4721947b2892cdcf15abfef59a897d0c0074d")
dg = un_hex("07e547d9586f6a73f73fbac0435ed76951218fb7d0c8d788a309d785436bbb642e93a252a954f23912547d1e8a3b5ed6e1bfd7097821233fa0538f3db854fee6")
r = un_hex("700bbd4cfe05459862c8b50a4d09da5fa826f856abbeea2874195f45b5a93ebb32c67ee01dae3c93e763c32b88c5429e")
s = un_hex("840aecdcc07fda89935ab9c8dacac4b36c2989253fe8c5fde529d8352f94b7417db76e5be977804502121cee0574f47c")
n = n + yes("secp384r1 sha512", ecdsa_verify(2, pub, dg, r, s))
n = n + no("secp384r1 sha512, flipped s", ecdsa_verify(2, pub, dg, r, un_hex("840aecdcc07fda99935ab9c8dacac4b36c2989253fe8c5fde529d8352f94b7417db76e5be977804502121cee0574f47c")))
n = n + no("secp384r1 sha512, on the wrong curve", ecdsa_verify(1, pub, dg, r, s))
pub = un_hex("0401974773e2a4723b30acd26352b23f94bff439e2bfb5b7e2f015b469eda1a27b080b3e2ed923485776e0a8e30e46f5f0567c3e37c4dd4d96278f380aef4e102d378d001d935d9cc04b4bdc11e4db1964e8a447c2064cd5213a87638ad537127de8673c66f75999474a47ad78c568ba79716d8f86c115303a810a691a1104fdff27b46090")
dg = un_hex("d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
r = un_hex("01021a7f52c42bd2fa7df3f90a1341eecabd6380bd082edac5863e65b6c0dd2159d0f32e5dcdb09c23149767312e903b355b401c5a9662feb5a74dba0aa99ee8438b")
s = un_hex("00a47fc01a397179102504b7a1bd42890b0442efd6d32ad50187aee599f1f4140c78456b065c35bd27bd805d8378b98ed9532ba74db27f30414db8b8d9f970a86f7b")
n = n + yes("secp521r1 sha256", ecdsa_verify(3, pub, dg, r, s))
n = n + no("secp521r1 sha256, flipped s", ecdsa_verify(3, pub, dg, r, un_hex("00a47fc01a397169102504b7a1bd42890b0442efd6d32ad50187aee599f1f4140c78456b065c35bd27bd805d8378b98ed9532ba74db27f30414db8b8d9f970a86f7b")))
n = n + no("secp521r1 sha256, on the wrong curve", ecdsa_verify(1, pub, dg, r, s))
pub = un_hex("0401974773e2a4723b30acd26352b23f94bff439e2bfb5b7e2f015b469eda1a27b080b3e2ed923485776e0a8e30e46f5f0567c3e37c4dd4d96278f380aef4e102d378d001d935d9cc04b4bdc11e4db1964e8a447c2064cd5213a87638ad537127de8673c66f75999474a47ad78c568ba79716d8f86c115303a810a691a1104fdff27b46090")
dg = un_hex("ca737f1014a48f4c0b6dd43cb177b0afd9e5169367544c494011e3317dbf9a509cb1e5dc1e85a941bbee3d7f2afbc9b1")
r = un_hex("0016170a7ea64b358efbbacb764e73b7382529e8326dbd476a217d9b741f2430a3f92b2b2d09c0e2c38d21fbfb8ebd3106bf9c99b09cd0918e4687e046eb834f53bd")
s = un_hex("0056d133bd5d1d10ebb9d47ffa06dad71b44a5f26b777e12951b6a7713b9151ec84a3028792d2cdb4911a0eff84fe96179c711b95a4b510e4c95e9c87a0082bac477")
n = n + yes("secp521r1 sha384", ecdsa_verify(3, pub, dg, r, s))
n = n + no("secp521r1 sha384, flipped s", ecdsa_verify(3, pub, dg, r, un_hex("0056d133bd5d1d00ebb9d47ffa06dad71b44a5f26b777e12951b6a7713b9151ec84a3028792d2cdb4911a0eff84fe96179c711b95a4b510e4c95e9c87a0082bac477")))
n = n + no("secp521r1 sha384, on the wrong curve", ecdsa_verify(1, pub, dg, r, s))
pub = un_hex("0401974773e2a4723b30acd26352b23f94bff439e2bfb5b7e2f015b469eda1a27b080b3e2ed923485776e0a8e30e46f5f0567c3e37c4dd4d96278f380aef4e102d378d001d935d9cc04b4bdc11e4db1964e8a447c2064cd5213a87638ad537127de8673c66f75999474a47ad78c568ba79716d8f86c115303a810a691a1104fdff27b46090")
dg = un_hex("07e547d9586f6a73f73fbac0435ed76951218fb7d0c8d788a309d785436bbb642e93a252a954f23912547d1e8a3b5ed6e1bfd7097821233fa0538f3db854fee6")
r = un_hex("014bbaa12cf52a4baa30c73b6614848e07c6af90c4ca62454bb2baf90c7c0d5f1b82496b02b45637597d773e1248661c48fe7583ab79048e72d5dba4d406458b9496")
s = un_hex("000bd676658e133a2df7d95f6b1c992c83b7e8da9138cf59775f97ee66ad7d59dd2714e7b4d0efaeab69cd51fb7641bfadbb959a206806d288967e0953ffe017a162")
n = n + yes("secp521r1 sha512", ecdsa_verify(3, pub, dg, r, s))
n = n + no("secp521r1 sha512, flipped s", ecdsa_verify(3, pub, dg, r, un_hex("000bd676658e132a2df7d95f6b1c992c83b7e8da9138cf59775f97ee66ad7d59dd2714e7b4d0efaeab69cd51fb7641bfadbb959a206806d288967e0953ffe017a162")))
n = n + no("secp521r1 sha512, on the wrong curve", ecdsa_verify(1, pub, dg, r, s))
out("ecdsa (word): " . n . " of 37 checks pass")
if n == 37
    return 0
return 1
