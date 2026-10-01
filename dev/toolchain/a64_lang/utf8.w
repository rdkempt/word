// The one UTF-8 decoder, at every boundary: what's well formed decodes, and the
// lead byte of anything else (an overlong form, a surrogate, a value past
// U+10FFFF, a sequence cut short) passes through as itself. Each target has its
// own copy of the decoder, so this is where they have to agree.
nib(c)
    if c >= 97
        return c - 87
    if c >= 65
        return c - 55
    return c - 48

unhex(h)
    b = bytes(len(h) >> 1)
    i = 0
    loop i < len(b)
        b[i] = nib(h[2 * i]) * 16 + nib(h[2 * i + 1])
        i = i + 1
    return b

show(hex)
    s = decode(unhex(hex))
    r = ""
    i = 0
    loop i < len(s)
        if i > 0
            r = r . ","
        r = r . s[i]
        i = i + 1
    out(hex . " -> " . r)

cases = split("00 7F C280 DFBF E0A080 ED9FBF EE8080 EFBFBF F0908080 F48FBFBF C0AF C1BB E08080 E09FBF EDA080 EDBFBF F08080AF F08FBFBF F4908080 F5808080 F8888080 FF 80 E282 E28241 F09F98 F09F9880 616263", " ")
loop c in cases
    show(c)
