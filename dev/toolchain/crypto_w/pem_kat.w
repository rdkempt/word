// RFC 4648 section 10's base64 vectors, the malformed encodings the decoder
// should refuse, and a PEM file holding the three certificates of the x509 test
// chain, with a comment before them and junk after, the way a real trust store
// looks.
hex_of(b)
    d = "0123456789abcdef"
    s = bytes(len(b) * 2)
    i = 0
    loop i < len(b)
        s[i * 2] = d[(b[i] >> 4) & 15]
        s[i * 2 + 1] = d[b[i] & 15]
        i = i + 1
    return s
eq(what, got, want)
    if got == want
        return 1
    err("  FAIL: " . what . ": want " . want . ", got " . got)
    return 0
dec(s)
    return pem_b64(s, 0, len(s))
n = 0
n = n + eq("base64 of ''", dec(""), "")
n = n + eq("base64 of 'f'", dec("Zg=="), "f")
n = n + eq("base64 of 'fo'", dec("Zm8="), "fo")
n = n + eq("base64 of 'foo'", dec("Zm9v"), "foo")
n = n + eq("base64 of 'foob'", dec("Zm9vYg=="), "foob")
n = n + eq("base64 of 'fooba'", dec("Zm9vYmE="), "fooba")
n = n + eq("base64 of 'foobar'", dec("Zm9vYmFy"), "foobar")
n = n + eq("a length that is not a multiple of four", dec("Zm9vY"), 0)
n = n + eq("a character outside the alphabet", dec("Zm9v*g=="), 0)
n = n + eq("padding in the middle", dec("Zm=9dmFy"), 0)
n = n + eq("three pad characters", dec("Zg==="), 0)
n = n + eq("base64 wrapped across lines", dec("Zm9v\nYmFy\n"), "foobar")
certs = pem_certs("# a comment line the parser has to walk past\n-----BEGIN CERTIFICATE-----\nMIIDQDCCAiigAwIBAgIUIQMO9GP87wuQafF0fVg12EZUM0swDQYJKoZIhvcNAQEL\nBQAwODELMAkGA1UEBhMCWFgxFTATBgNVBAoMDFdvcmQgUm9vdCBDQTESMBAGA1UE\nAwwJV29yZCBSb290MB4XDTI2MDgzMTAwMjcyOVoXDTQ2MDgyNjAwMjcyOVowODEL\nMAkGA1UEBhMCWFgxFTATBgNVBAoMDFdvcmQgUm9vdCBDQTESMBAGA1UEAwwJV29y\nZCBSb290MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxgBWpzDm0tre\nkX/0m6lHwPHB+oa47Vk7h1DjOgkGUz7zQPunZsRLZRo8cUf6PzXwec7zgCFGDpDJ\neXrVYrtA9Vs+BhEPJg7ye0ZECM5ykvCgXiaHehYIhMztsfcT8NGIFPOvjBBtr08p\n/2husO6x9lHPzZ2FmFjnaVn/r4tKSQJPO84HwbRZpJC5G2jYGDWtM3TrWPQfBHd2\nKd+MmL0GCyP+aQUE1ZpyEKWNnPltse1Ih3ip9cRvn0xo2rH9BJ6f8PUT7Dd6+goa\n6BEcoVKiMoSfSMCkMNrLoDVAWs3lYnwtsU1BNre/R/xnMG9xTZSdzu18wXf05i/3\nQEBQvAgUMQIDAQABo0IwQDAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIB\nBjAdBgNVHQ4EFgQUOIy2xi/AOUbiM75c5z98xjszlJcwDQYJKoZIhvcNAQELBQAD\nggEBAIPPQYT2lsbOV+xJVWgHj5ANoiE9xz5ELV1gBzcgH8D1AHyElcWq42Cl/DJy\nO70zIXTcmZRbD/bfjwyX4+hBwHwdRMZimqOhtR0eefLimWRBW0xRHpvMyrd7EJta\nXpqgzSyGndsEMRyGCepWNfBx4OxsJA81PWdFd1A1b/bGOJucqa1iO+iFcTyq0+ux\nQkA6F2g2idrFlBfnr4iWqWaYI0OD8Dh4ucmrkr2LCpKSSk/ssglkoF8vfyPAFnHW\n8Xdryq93neHZjeR4PSuPs83cop0frt+9fMglWkaO267KnbTccZqQFgn9vYI4PKdd\nu4EC/UQ6ZA+H7YZPafrFfnJ6y8A=\n-----END CERTIFICATE-----\n-----BEGIN CERTIFICATE-----\nMIICjzCCAXegAwIBAgICEAEwDQYJKoZIhvcNAQELBQAwODELMAkGA1UEBhMCWFgx\nFTATBgNVBAoMDFdvcmQgUm9vdCBDQTESMBAGA1UEAwwJV29yZCBSb290MB4XDTI2\nMDgzMTAwMjcyOVoXDTM2MDgyODAwMjcyOVowQDELMAkGA1UEBhMCWFgxFTATBgNV\nBAoMDFdvcmQgUm9vdCBDQTEaMBgGA1UEAwwRV29yZCBJbnRlcm1lZGlhdGUwWTAT\nBgcqhkjOPQIBBggqhkjOPQMBBwNCAAS+E2k2WvQgeGa1GkXVHO9fnV7nOdzQEBUM\nVsyLbeG7CQUym/vofKrZB0tVen0Nilk2Fz9a0TiAjmweZ5jkwMw9o2YwZDASBgNV\nHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwIBBjAdBgNVHQ4EFgQU3pAdotRb\n579RpwwBlsO3pVzN0SUwHwYDVR0jBBgwFoAUOIy2xi/AOUbiM75c5z98xjszlJcw\nDQYJKoZIhvcNAQELBQADggEBABNxIWFqkrsuhACKjfLxuN46JXLNh8l8ww+7SScr\nzSPVgF6lRA0SFZCQKppizVlL9/P8KfJkHqMxP4wJ66C7ZJzIS8giSYkN4eoq95k8\nexuUasZCSRZtYx9qtBSwivbnFSIUYSDnMn4PZf4TLOXWAOWKGDLl40DCUUhwbEA3\nVWr+F3VWK44KYCCs39Y82l49bDma/FkS+HG5lqGEm4VF3ossVmr+rdZxbeOOByry\ndZjBKK95yJKc/VFB5yAaqs/POg545T7TCJIioTvCCb3hulQqveEQvH7lPJjufvdp\nHpJAi82g8X6D6soKn91t3QSvPVLeN9ySsIGW7+LMd37WMQk=\n-----END CERTIFICATE-----\n-----BEGIN CERTIFICATE-----\nMIICwTCCAmigAwIBAgICEAIwCgYIKoZIzj0EAwIwQDELMAkGA1UEBhMCWFgxFTAT\nBgNVBAoMDFdvcmQgUm9vdCBDQTEaMBgGA1UEAwwRV29yZCBJbnRlcm1lZGlhdGUw\nHhcNMjYwODMxMDAyNzI5WhcNMzYwODI4MDAyNzI5WjA4MQswCQYDVQQGEwJYWDES\nMBAGA1UECgwJV29yZCBUZXN0MRUwEwYDVQQDDAx3b3JkLmV4YW1wbGUwggEiMA0G\nCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCnqvmKFE2hkbe/ApLj0jZbge0pXUUe\ncJawH5V5unSHbS94jxSUH9vWQaIMR2itGNuoDWMaozKVVofC9yral4rn0Gnloplj\nZNPxy8u7AqRmxoZG81cFk4GxYe/4G+h81qV2HAUh9s4F4DhIwDyB9lJGWiArZYAn\nkqknbRba5IhLwkk3pNnfGGZt2ONUhOk5a7M04mNUgC3JcORYzA7dm4eiuAzjovhx\nnZyY+XuCbC3y7qDzZtLVnheLMZB4zCabpPUKnujACYmCRUb0+gF0A81H8krbEqQI\nF2hYggUlBxofs9Y07b+npmSXWFeKHwmZ1BvPvF6vhEdGsSlvnLfbI+dXAgMBAAGj\ngY4wgYswDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCBaAwKwYDVR0RBCQwIoIM\nd29yZC5leGFtcGxlghIqLnN1Yi53b3JkLmV4YW1wbGUwHQYDVR0OBBYEFMFlJ802\nc1b7mM9lJZTN8OUlGTa6MB8GA1UdIwQYMBaAFN6QHaLUW+e/UacMAZbDt6VczdEl\nMAoGCCqGSM49BAMCA0cAMEQCIHHBAOIdINAHsRLReNuv9Hcq94S4Akty4zFJtWqp\n22i1AiBZ8PyqITHmhRA0r2yxUwvVubuDKNabPsfhmUWQO748jw==\n-----END CERTIFICATE-----\ntrailing junk with no block\n")
n = n + eq("three certificates in the file", len(certs), 3)
n = n + eq("certificate 0 round-trips", len(certs[0]), 836)
n = n + eq("certificate 1 round-trips", len(certs[1]), 659)
n = n + eq("certificate 2 round-trips", len(certs[2]), 709)
n = n + eq("certificate 0 is the root", hex_of(certs[0]), "3082034030820228a003020102021421030ef463fcef0b9069f1747d5835d84654334b300d06092a864886f70d01010b05003038310b300906035504061302585831153013060355040a0c0c576f726420526f6f742043413112301006035504030c09576f726420526f6f74301e170d3236303833313030323732395a170d3436303832363030323732395a3038310b300906035504061302585831153013060355040a0c0c576f726420526f6f742043413112301006035504030c09576f726420526f6f7430820122300d06092a864886f70d01010105000382010f003082010a0282010100c60056a730e6d2dade917ff49ba947c0f1c1fa86b8ed593b8750e33a0906533ef340fba766c44b651a3c7147fa3f35f079cef38021460e90c9797ad562bb40f55b3e06110f260ef27b464408ce7292f0a05e26877a160884ccedb1f713f0d18814f3af8c106daf4f29ff686eb0eeb1f651cfcd9d859858e76959ffaf8b4a49024f3bce07c1b459a490b91b68d81835ad3374eb58f41f04777629df8c98bd060b23fe690504d59a7210a58d9cf96db1ed488778a9f5c46f9f4c68dab1fd049e9ff0f513ec377afa0a1ae8111ca152a232849f48c0a430dacba035405acde5627c2db14d4136b7bf47fc67306f714d949dceed7cc177f4e62ff7404050bc0814310203010001a3423040300f0603551d130101ff040530030101ff300e0603551d0f0101ff040403020106301d0603551d0e04160414388cb6c62fc03946e233be5ce73f7cc63b339497300d06092a864886f70d01010b0500038201010083cf4184f696c6ce57ec495568078f900da2213dc73e442d5d600737201fc0f5007c8495c5aae360a5fc32723bbd332174dc99945b0ff6df8f0c97e3e841c07c1d44c6629aa3a1b51d1e79f2e29964415b4c511e9bcccab77b109b5a5e9aa0cd2c869ddb04311c8609ea5635f071e0ec6c240f353d67457750356ff6c6389b9ca9ad623be885713caad3ebb142403a17683689dac59417e7af8896a96698234383f03878b9c9ab92bd8b0a92924a4fecb20964a05f2f7f23c01671d6f1776bcaaf779de1d98de4783d2b8fb3cddca29d1faedfbd7cc8255a468edbaeca9db4dc719a901609fdbd82383ca75dbb8102fd443a640f87ed864f69fac57e727acbc0")
n = n + eq("a file with no blocks", len(pem_certs("nothing to see here")), 0)
n = n + eq("a block with no end line", len(pem_certs("-----BEGIN CERTIFICATE-----\nQUFB\n")), 0)
out("pem (word): " . n . " of 19 checks pass")
if n == 19
    return 0
return 1
