// x509_verdict.w: one chain in, ACCEPTED or REJECTED out.
//
// The verifier's own answer, with nothing else in the way: no socket, no
// handshake, no trust store on disk. dev/toolchain/test_x509_profile.sh runs it
// on fixture chains and compares the answer with openssl's and Go's on the
// same bytes, so "word agrees with two independent PKIX implementations" is
// something a test checks.
//
//   x509_verdict <host> <anchor.der> <leaf.der> [intermediate.der ...]
//
// The anchor is the trust store (exactly one certificate), and the rest is the
// chain as a server would send it, leaf first. Time is the clock, so the
// fixtures are made for now instead of pinned to a date that expires.
//
// The test script appends this to the crypto modules (netlib_cat.py) to make
// one program. It's never built on its own, since it calls library functions
// it only gets that way.
idiv(a, b)
    // Long division, one bit at a time, instead of `/`.
    //
    // `/` is exact, so it may answer a float, and every site emits the boxing
    // and promotion for one (when this was measured, 424 sites and 26,000 extra
    // lines of assembly in a program that fetched a URL). This stays in
    // integers. It's called only where the divisor isn't a power of two (a
    // shift covers those) and never in a loop that runs per bit, so sixty-odd
    // iterations cost nothing measurable.
    n = 0
    if a < 0
        a = 0 - a
        n = 1
    if b < 0
        b = 0 - b
        n = 1 - n
    q = 0
    r = 0
    i = 61
    loop i >= 0
        r = r * 2 + ((a >> i) & 1)
        if r >= b
            r = r - b
            q = q + (1 << i)
        i = i - 1
    if n == 1
        return 0 - q
    return q

xv_die(msg)
    err(msg)
    out("ERROR")

// The host's own trust store, counted:
//
//     x509_verdict --store <candidate path>...  ->  STORE <offered> <parsed> <pq> <source>
//
// <pq> counts the anchors that don't parse because their key is ML-DSA or
// SLH-DSA. word implements neither, so no chain it verifies can end at one,
// and losing them costs a fetch nothing. Windows carries pilot roots of both.
//
// net_load_roots keeps the anchors that parse and drops the rest without an
// error, so a store that has lost a third of its anchors still authenticates
// every site whose chain ends at one of the others. That hid a real bug once:
// 19 of a Windows machine's 53 ROOT anchors were dropped for being self-signed
// with SHA-1, MD5 or MD2 (GlobalSign Root CA and three DigiCert roots among
// them), and only the sites whose chain needed one of the 19 broke. So the
// count is the test, and the difference between the two numbers is how many
// anchors a fetch has lost.
//
// The candidate paths are net_ca_paths's own, passed in by the test script so
// the repo holds one copy of that list. The store is picked the way
// net_load_roots picks it: a region from cacerts() is the OS trust store and no
// file is read (Windows); `none` means this host keeps its anchors in a file,
// and the first of the paths that holds any is the store.
// `paths` is all of argv, so the candidates start at 2: argv[0] is the program
// and argv[1] is the --store that got us here.
xv_store(paths)
    blob = cacerts()
    r = text(2)
    if kind(blob) != "none"
        r[0] = xv_store_ders(blob)
        r[1] = "the OS trust store"
        return r
    i = 2
    loop i < len(paths)
        raw = read(paths[i])
        if kind(raw) != "none"
            certs = pem_certs(decode(raw))
            if len(certs) > 0
                r[0] = certs
                r[1] = paths[i]
                return r
        i = i + 1
    r[0] = array(0)
    r[1] = "no file at any of the paths"
    return r

// cacerts() read as the [uint32 length][DER] records it is, the same way net.w's
// net_store_ders reads it: a record that runs past the end of the region drops
// the whole store instead of being half-read.
xv_store_ders(blob)
    n = len(blob)
    cnt = 0
    off = 0
    loop off + 4 <= n
        l = blob[off] + blob[off + 1] * 256 + blob[off + 2] * 65536 + blob[off + 3] * 16777216
        off = off + 4 + l
        if off > n
            return array(0)
        cnt = cnt + 1
    r = array(cnt)
    off = 0
    i = 0
    loop i < cnt
        l = blob[off] + blob[off + 1] * 256 + blob[off + 2] * 65536 + blob[off + 3] * 16777216
        off = off + 4
        r[i] = copy(blob, off, off + l)
        off = off + l
        i = i + 1
    return r

// Does this certificate name a NIST post-quantum signature algorithm? Those are
// 2.16.840.1.101.3.4.3.17 to .46 (ML-DSA, SLH-DSA and their pre-hashed forms),
// so the DER holds 06 09 60 86 48 01 65 03 04 03 and then a byte from 17 to 46.
xv_pq(der)
    p = bytes("06096086480165030403")
    off = 0
    loop
        i = find(copy(der, off), p)
        if i == none
            return false
        j = off + i + len(p)
        if j < len(der) && der[j] >= 17 && der[j] <= 46
            return true
        off = off + i + 1

xv_args = args()
if len(xv_args) > 1 && xv_args[1] == "--store"
    xv_s = xv_store(xv_args)
    xv_ders = xv_s[0]
    xv_kept = 0
    xv_pqs = 0
    xv_k = 0
    loop xv_k < len(xv_ders)
        if kind(x509_parse(xv_ders[xv_k])) != "number"
            xv_kept = xv_kept + 1
        else if xv_pq(xv_ders[xv_k])
            xv_pqs = xv_pqs + 1
        xv_k = xv_k + 1
    out("STORE " . len(xv_ders) . " " . xv_kept . " " . xv_pqs . " " . xv_s[1])
else if len(xv_args) < 4
    xv_die("x509_verdict: need <host> <anchor.der> <leaf.der> [...], or --store <path>...")
else
    xv_host = xv_args[1]
    xv_anchor = x509_parse(read(xv_args[2]))
    if kind(xv_anchor) == "number"
        xv_die("x509_verdict: the anchor did not parse")
    else
        xv_n = len(xv_args) - 3
        xv_chain = text(xv_n)
        xv_k = 0
        xv_ok = 1
        xv_i = 0
        loop xv_i < xv_n
            xv_c = x509_parse(read(xv_args[3 + xv_i]))
            if kind(xv_c) == "number"
                // A leaf that doesn't decode is a refusal, the same one a chain
                // walk would give, so it prints the same answer and the
                // comparison has no third one to handle. Any other certificate
                // that doesn't decode is left out, the way
                // tls13_parse_certificate leaves it out of what a server sent,
                // since it could never have been a link.
                if xv_i == 0
                    xv_ok = 0
            else
                xv_chain[xv_k] = xv_c
                xv_k = xv_k + 1
            xv_i = xv_i + 1
        if xv_k < xv_n
            xv_chain = copy(xv_chain, 0, xv_k)
        if xv_ok == 0
            out("REJECTED")
        else
            xv_roots = text(1)
            xv_roots[0] = xv_anchor
            if x509_verify_chain(xv_chain, xv_roots, xv_host, idiv(now(), 1000000000)) == 1
                out("ACCEPTED")
            else
                out("REJECTED")
