// fuzz_net.w: the driver for test_fuzz_net.sh.
//
// The two parsers that read what a remote party sends before any of it is
// authenticated, and that the X.509 and TLS fuzzers don't reach: the DNS
// response parser, which runs on a resolver's answer before a connection even
// exists, and the HTTP response framing, which over http:// is all there is.
//
//   fuzz_net dns <file>    dns_parse_a on the bytes, and dns_conf_line on
//                          each of their lines as though they were resolv.conf
//   fuzz_net http <file>   http_frame, http_done and http_body on the bytes as
//                          a response to GET and to HEAD, and the head search
//                          and chunk walk a read loop resumes
//
// Every call has to return, and what it returns has to make sense: an address
// is four bytes, a head sits inside the response, a body is no longer than
// what arrived, the head search and the chunk walk a read loop resumes after
// every read agree with a fresh search and walk on every prefix, and bytes past
// the live length are never read. Exit 0 when all of that holds, and 1 with a
// PROPERTY line on stderr when something doesn't. Any other exit is a fault, a
// hang or a crash, and test_fuzz_net.sh counts every non-zero status as a
// failure.
//
// The test script appends this to dns.w and http.w, the same way with_netlib
// bundles them. It's never built on its own.
fz_fail(msg)
    err("PROPERTY: " . msg)
    return 1

fz_dns(b)
    ip = dns_parse_a(b)
    if kind(ip) != "number" && len(ip) != 4
        return fz_fail("dns_parse_a answered " . len(ip) . " bytes, not an address")
    lines = split(decode(b), "\n")
    i = 0
    loop i < len(lines)
        a = dns_conf_line(lines[i])
        if kind(a) != "number" && len(a) != 4
            return fz_fail("dns_conf_line answered " . len(a) . " bytes, not an address")
        i = i + 1
    // A dotted quad resolves without a resolver or a socket. Calling it keeps
    // every function in dns.w reachable, which a program has to.
    if len(b) == 0
        dns_resolve("10.0.0.7")
    return 0

fz_http(b, head)
    n = len(b)
    f = http_frame(b, n, head)
    k = f[2]
    if k < 0 || k > 5
        return fz_fail("http_frame's kind is " . k)
    if k >= 1 && k <= 4 && (f[0] < 0 || f[0] > f[1] || f[1] > n)
        return fz_fail("the head is at " . f[0] . ".." . f[1] . " in " . n . " bytes")
    // a header value, found by scanning the head's lines
    if k >= 1 && k <= 4
        h = http_header(b, f[0], f[1] - 4, "Content-Type")
        if kind(h) != "number" && len(h) > n
            return fz_fail("a header value longer than the response")
    d = http_done(b, n, f)
    if d < 0 - 1 || d > 1
        return fz_fail("http_done answered " . d)
    if http_complete(b, n, head) != d
        return fz_fail("http_complete and http_done disagree")
    c = http_close_delimited(b, n, head)
    if c != 0 && c != 1
        return fz_fail("http_close_delimited answered " . c)
    // The head search a read loop resumes, fed a little more each time, against
    // http_frame on the same prefix: a byte at a time up to 2 KiB, and in 64
    // steps past that.
    hs = text(3)
    hstep = 1
    if n > 2048
        hstep = n >> 6
    m = 0
    loop m <= n
        a = http_frame_more(b, m, head, hs)
        g = http_frame(b, m, head)
        if a[0] != g[0] || a[1] != g[1] || a[2] != g[2] || a[3] != g[3]
            return fz_fail("the resumed head search disagrees with http_frame at " . m)
        if m < n && m + hstep > n
            m = n
        else
            m = m + hstep
    if k == 3
        // The walk a read loop resumes, fed a little more of the body each
        // time, against a walk from the top of the body on the same prefix. A
        // byte at a time up to 2 KiB of body, and in 64 steps past that, since
        // the walk from the top makes this quadratic.
        st = text(2)
        st[0] = f[1]
        st[1] = f[1]
        step = 1
        if n - f[1] > 2048
            step = (n - f[1]) >> 6
        m = f[1]
        loop m <= n
            if http_chunks_more(b, m, st) != http_chunks_done(b, f[1], m)
                return fz_fail("the resumed chunk walk disagrees with a fresh one at " . m)
            if m < n && m + step > n
                m = n
            else
                m = m + step
    // The body, once from an exact copy and once from a buffer with spare
    // capacity after the live bytes, the way a read loop hands it over. The
    // spare holds a terminating chunk, so a decoder that read past the live
    // length would answer differently. http_body consumes what it's given.
    sp = http_append(bytes(0), 0, b, 0, n)
    i = n
    loop i < len(sp)
        sp[i] = 48
        if (i - n) % 5 == 1 || (i - n) % 5 == 3
            sp[i] = 13
        if (i - n) % 5 == 2 || (i - n) % 5 == 4
            sp[i] = 10
        i = i + 1
    b1 = http_body(copy(b, 0, n), n, head)
    b2 = http_body(sp, n, head)
    if kind(b1) != kind(b2)
        return fz_fail("the body depends on the bytes past the live length")
    if kind(b1) != "number"
        if b1 != b2
            return fz_fail("the body depends on the bytes past the live length")
        if len(b1) > n
            return fz_fail("a body of " . len(b1) . " bytes out of " . n)
    // The request side is the program's own and fuzzed elsewhere; building one
    // keeps every function in http.w reachable.
    if n == 0
        http_request("GET", http_parse_url("http://example.com/"), 0)
    return 0

fz_main()
    a = args()
    if len(a) < 3
        err("usage: fuzz_net dns|http <file>")
        return 2
    raw = read(a[2])
    if raw == none
        err("fuzz_net: cannot read " . a[2])
        return 2
    if a[1] == "dns"
        return fz_dns(raw)
    r = fz_http(raw, 0)
    if r == 0
        r = fz_http(raw, 1)
    return r

return fz_main()
