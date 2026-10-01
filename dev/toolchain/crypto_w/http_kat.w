// Known-answer tests for the net library's http.w: the request it builds, and the
// responses it has to read without trusting them. The fixtures are literal wire
// bytes, so a change to the request line or to a framing rule shows up here as
// a diff, not as a failed fetch against someone's server.
http_str_bytes(s)
    b = bytes(len(s))
    i = 0
    loop i < len(s)
        b[i] = s[i] & 255
        i = i + 1
    return b

http_check(name, got, want)
    if got == want
        return 1
    err("  FAIL: " . name)
    err("    want [" . want . "]")
    err("    got  [" . got . "]")
    return 0

http_show(v)
    if kind(v) == "number"
        return "none"
    return decode(v)

// The first `k` characters of the request `u` makes, which is where the request
// line and the Host header are.
http_reqhead(u, k)
    r = decode(http_request("GET", u, 0))
    if len(r) < k
        return r
    return copy(r, 0, k)

// http_parse_url's verdict, as text: the refusal is the number 0.
http_urlverdict(s)
    u = http_parse_url(s)
    if kind(u) == "number"
        return "refused"
    return "parsed"

// A whole response's body, and whether it is complete, as text.
http_bodyof(s, head)
    b = http_str_bytes(s)
    return http_show(http_body(b, len(b), head))

http_doneof(s, head)
    b = http_str_bytes(s)
    return "" . http_complete(b, len(b), head)

// Every prefix of `s`, fed to http_frame_more one byte more at a time with one
// state, against http_frame on the same prefix: "yes" when all four fields
// agree at every length.
http_frames_agree(s, head)
    b = http_str_bytes(s)
    st = text(3)
    k = 0
    loop k <= len(b)
        f = http_frame_more(b, k, head, st)
        g = http_frame(b, k, head)
        if f[0] != g[0] || f[1] != g[1] || f[2] != g[2] || f[3] != g[3]
            return "no, at " . k
        k = k + 1
    return "yes"

n = 0

// --- the URL -------------------------------------------------------------
u = http_parse_url("https://example.com/a/b?c=1")
n = n + http_check("https url: host", http_show(u[1]), "example.com")
n = n + http_check("https url: port", "" . u[2], "443")
n = n + http_check("https url: path", http_show(u[3]), "/a/b?c=1")
n = n + http_check("https url: scheme", "" . u[0], "1")

u = http_parse_url("http://example.com")
n = n + http_check("http defaults to port 80", "" . u[2], "80")
n = n + http_check("a missing path becomes /", http_show(u[3]), "/")

// The scheme is optional and defaults to https (SPEC 12.2).
u = http_parse_url("api.example.com/v1")
n = n + http_check("a bare host is https", "" . u[0], "1")
n = n + http_check("a bare host keeps its path", http_show(u[3]), "/v1")

u = http_parse_url("http://example.com:8080/x")
n = n + http_check("an explicit port is taken", "" . u[2], "8080")
n = n + http_check("an explicit port is not part of the host", http_show(u[1]), "example.com")

n = n + http_check("a url with no host is refused", "" . http_parse_url("https://"), "0")
n = n + http_check("a port of 0 is refused", "" . http_parse_url("http://h:0/"), "0")
n = n + http_check("a non-numeric port is refused", "" . http_parse_url("http://h:80x/"), "0")

// The authority ends at `?` and `#` as well as at `/`, and a fragment belongs to
// the client, so it's never part of what is sent.
u = http_parse_url("http://example.com?x=y")
n = n + http_check("a query with no path: the host stops at ?", http_show(u[1]), "example.com")
n = n + http_check("a query with no path is asked of /", http_show(u[3]), "/?x=y")
u = http_parse_url("http://example.com/x#frag")
n = n + http_check("a fragment is not sent", http_show(u[3]), "/x")
u = http_parse_url("http://example.com#frag")
n = n + http_check("a fragment with no path: the host stops at #", http_show(u[1]), "example.com")
n = n + http_check("a fragment with no path leaves /", http_show(u[3]), "/")
u = http_parse_url("https://example.com/a?b=c#d?e")
n = n + http_check("the fragment ends the query", http_show(u[3]), "/a?b=c")
u = http_parse_url("http://example.com:8080?q")
n = n + http_check("a port before a query", "" . u[2], "8080")
n = n + http_check("and the query after it", http_show(u[3]), "/?q")

// Nothing that could end a line reaches a request: such a URL is refused whole,
// not cleaned up. The first case is the injection that was reported, a path
// that wrote a header and a second request of its own.
n = n + http_check("CR LF in the path", http_urlverdict("http://h/abc\r\nX-Evil: yes\r\n\r\nGET /second HTTP/1.1\r\n\r\n"), "refused")
n = n + http_check("a bare LF in the path", http_urlverdict("http://h/a\nb"), "refused")
n = n + http_check("CR LF in the authority", http_urlverdict("http://h\r\nX: y/"), "refused")
n = n + http_check("a space", http_urlverdict("http://h/a b"), "refused")
n = n + http_check("a NUL", http_urlverdict("http://h/a\0b"), "refused")
n = n + http_check("a tab", http_urlverdict("http://h/a\tb"), "refused")
n = n + http_check("DEL", http_urlverdict("http://h/a" . char(127)), "refused")
n = n + http_check("a surrogate", http_urlverdict("http://h/" . char(55296)), "refused")
n = n + http_check("a code point past U+10FFFF", http_urlverdict("http://h/" . char(1114112)), "refused")
n = n + http_check("a userinfo", http_urlverdict("http://user@h/"), "refused")
n = n + http_check("an IPv6 literal", http_urlverdict("http://[::1]:8080/"), "refused")
n = n + http_check("a backslash in the host", http_urlverdict("http://a\\b/"), "refused")
n = n + http_check("a host outside ASCII", http_urlverdict("http://caf" . char(233) . "/"), "refused")
n = n + http_check("a port past 65535", http_urlverdict("http://h:65536/"), "refused")
// Thirty digits used to be an integer overflow, which stopped the program.
n = n + http_check("a port of thirty digits", http_urlverdict("http://h:999999999999999999999999999999/"), "refused")
n = n + http_check("an ordinary URL still parses", http_urlverdict("http://h-1.example_x.com:1/a-b_c.d~e!$&'()*+,;=:@%20/?q=a/b?c"), "parsed")

// A code point past ASCII is sent as its UTF-8 bytes, percent-encoded (RFC 3986
// 2.1). Keeping only its low byte used to let U+010D and U+010A arrive as a raw
// CR and LF.
u = http_parse_url("http://h/caf" . char(233) . "/" . char(269) . char(266) . "/" . char(128512))
n = n + http_check("non-ASCII is percent-encoded UTF-8", http_show(u[3]), "/caf%C3%A9/%C4%8D%C4%8A/%F0%9F%98%80")
u = http_parse_url("http://h/" . char(128) . char(2047) . char(2048) . char(65535) . char(65536) . char(1114111))
n = n + http_check("at every UTF-8 length boundary", http_show(u[3]), "/%C2%80%DF%BF%E0%A0%80%EF%BF%BF%F0%90%80%80%F4%8F%BF%BF")

// --- the request ---------------------------------------------------------
req = decode(http_request("GET", http_parse_url("http://example.com/"), 0))
n = n + http_check("the request line and headers",
    req,
    "GET / HTTP/1.1\r\nHost: example.com\r\nUser-Agent: word/1.0\r\nAccept: */*\r\nConnection: close\r\n\r\n")

req = decode(http_request("POST", http_parse_url("http://h/p"), http_str_bytes("hi")))
n = n + http_check("a body sets Content-Length and is appended",
    req,
    "POST /p HTTP/1.1\r\nHost: h\r\nUser-Agent: word/1.0\r\nAccept: */*\r\nConnection: close\r\nContent-Length: 2\r\n\r\nhi")

// Host includes the port whenever it isn't the scheme's own (RFC 9110 7.2).
n = n + http_check("a non-default port is in Host",
    http_reqhead(http_parse_url("http://127.0.0.1:55735/x"), 40), "GET /x HTTP/1.1\r\nHost: 127.0.0.1:55735\r\n")
n = n + http_check("https on 443 names no port", http_reqhead(http_parse_url("https://h/"), 25), "GET / HTTP/1.1\r\nHost: h\r\n")
n = n + http_check("an explicit 443 on https is still the default", http_reqhead(http_parse_url("https://h:443/"), 25), "GET / HTTP/1.1\r\nHost: h\r\n")
n = n + http_check("http on 443 is not the default", http_reqhead(http_parse_url("http://h:443/"), 29), "GET / HTTP/1.1\r\nHost: h:443\r\n")
n = n + http_check("https on 80 is not the default", http_reqhead(http_parse_url("https://h:80/"), 28), "GET / HTTP/1.1\r\nHost: h:80\r\n")
n = n + http_check("a query is sent, a fragment is not", http_reqhead(http_parse_url("http://h/?q=1#f"), 20), "GET /?q=1 HTTP/1.1\r\n")

// A record that did not come from http_parse_url is checked, not trusted.
bad = text(4)
bad[0] = 0
bad[1] = "h"
bad[2] = 80
bad[3] = "/a\r\nX: y"
n = n + http_check("a path with a CR LF builds no request", "" . http_request("GET", bad, 0), "0")
bad[3] = "/"
bad[1] = "h\r\nX: y"
n = n + http_check("a host with a CR LF builds no request", "" . http_request("GET", bad, 0), "0")

// --- the accumulator -----------------------------------------------------
// http_append is what a response is read into: a buffer with spare capacity,
// doubled when it runs out, so reading a body in n chunks copies O(total)
// instead of rebuilding the whole response on every chunk. The cases to check
// are the growth boundary, and that `used` (not len(dst)) says how much is
// live.
src = http_str_bytes("hello, world")

acc = bytes(0)
acc = http_append(acc, 0, src, 0, 5)
n = n + http_check("appending to an empty buffer", http_show(copy(acc, 0, 5)), "hello")

acc = http_append(acc, 5, src, 5, 12)
n = n + http_check("a second append lands after the first", http_show(copy(acc, 0, 12)), "hello, world")
n = n + http_check("capacity is at least what is live", "" . (len(acc) >= 12), "true")

// An append of nothing must not move `used` or disturb what is there.
acc = http_append(acc, 12, src, 3, 3)
n = n + http_check("an empty append changes nothing", http_show(copy(acc, 0, 12)), "hello, world")

// Growth across the doubling boundary, one element at a time, is where an
// off-by-one in the copy of the old contents would show.
big = bytes(300)
i = 0
loop i < 300
    big[i] = 97 + (i % 26)
    i = i + 1
acc2 = bytes(0)
used = 0
loop used < 300
    acc2 = http_append(acc2, used, big, used, used + 1)
    used = used + 1
n = n + http_check("300 single-element appends survive every doubling", "" . (copy(acc2, 0, 300) == big), "true")

// And in one go, from a buffer that had already grown.
acc3 = http_append(bytes(4), 0, big, 0, 300)
n = n + http_check("one append larger than the capacity", "" . (copy(acc3, 0, 300) == big), "true")

// --- the response --------------------------------------------------------
r200 = http_str_bytes("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\nhello")
hend = http_header_end(r200, 0, len(r200))
n = n + http_check("status is read", "" . http_status(r200, 0), "200")
n = n + http_check("a Content-Length body", http_bodyof("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\nhello", 0), "hello")
n = n + http_check("a header value is found", http_show(http_header(r200, 0, hend, "Content-Type")), "text/plain")
n = n + http_check("a header name is case-insensitive", http_show(http_header(r200, 0, hend, "content-length")), "5")
n = n + http_check("an absent header is 0", "" . http_header(r200, 0, hend, "ETag"), "0")
n = n + http_check("a Content-Length response is complete", "" . http_complete(r200, len(r200), 0), "1")
n = n + http_check("the head's end is found", "" . hend, "60")
n = n + http_check("and not past what is live", "" . http_header_end(r200, 0, 63), "-1")
n = n + http_check("but found once it is", "" . http_header_end(r200, 0, 64), "60")

// Content-Length longer than what arrived: not complete, and the body is what came.
n = n + http_check("a short body is not complete", http_doneof("HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\nhel", 0), "0")
n = n + http_check("a short body yields what arrived", http_bodyof("HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\nhel", 0), "hel")

// Chunked: two chunks then the terminator.
rchunk = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n2\r\n, \r\n5\r\nworld\r\n0\r\n\r\n"
n = n + http_check("a chunked body is reassembled", http_bodyof(rchunk, 0), "hello, world")
n = n + http_check("a finished chunked body is complete", http_doneof(rchunk, 0), "1")

// A chunked body missing its terminator is not complete.
n = n + http_check("an unterminated chunked body is not complete", http_doneof("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n", 0), "0")

// A chunk size claiming more than arrived must stop, not read past the end.
n = n + http_check("an oversized chunk stops the body", http_bodyof("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nff\r\nab\r\n", 0), "")

// A chunk extension after the size is ignored.
n = n + http_check("a chunk extension is ignored", http_bodyof("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;x=1\r\nhello\r\n0\r\n\r\n", 0), "hello")

// The body is decoded over the response itself, so only the live bytes count:
// spare capacity after them is not part of it.
rlive = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n"
rspare = http_str_bytes(rlive . "7\r\n, world\r\n0\r\n\r\n")
n = n + http_check("only the live length is decoded", http_show(http_body(rspare, len(rlive), 0)), "hello")
rmany = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n1\r\nb\r\n3\r\ncde\r\n1a\r\nfghijklmnopqrstuvwxyz01234\r\n0\r\n\r\n"
n = n + http_check("many chunks of every size, in place", http_bodyof(rmany, 0), "abcdefghijklmnopqrstuvwxyz01234")

// The completeness walk picks up where it left off. Read a byte at a time, it
// has to say "not yet" until the zero-length chunk's line is whole, and agree
// with a walk from the top on every prefix.
wb = http_str_bytes(rmany)
wst = text(2)
wst[0] = http_header_end(wb, 0, len(wb)) + 4
wst[1] = wst[0]
wfirst = 0 - 1
wagree = 1
k = wst[0]
loop k <= len(wb)
    got = http_chunks_more(wb, k, wst)
    if got != http_chunks_done(wb, http_header_end(wb, 0, len(wb)) + 4, k)
        wagree = 0
    if got == 1 && wfirst < 0
        wfirst = k
    if got == 1
        k = len(wb)
    k = k + 1
n = n + http_check("a byte at a time, the walk agrees with a walk from the top", "" . wagree, "1")
n = n + http_check("and says done when the last chunk's line is whole", "" . wfirst, "" . (len(wb) - 2))
wbad = http_str_bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\nzz\r\n0\r\n\r\n")
wst[0] = http_header_end(wbad, 0, len(wbad)) + 4
wst[1] = wst[0]
n = n + http_check("a size that is not hex is never done", "" . http_chunks_more(wbad, len(wbad), wst), "0")
n = n + http_check("and the walk remembers that", "" . wst[1] . " " . http_chunks_more(wbad, len(wbad), wst), "-1 0")

// No framing at all: the body is everything after the headers.
rclose = http_str_bytes("HTTP/1.1 200 OK\r\nServer: x\r\n\r\ntail")
n = n + http_check("a close-delimited body is the remainder", http_bodyof("HTTP/1.1 200 OK\r\nServer: x\r\n\r\ntail", 0), "tail")

// Which of the three framings this is, which the driver needs to tell a
// truncated response from a finished one. With a read deadline in place, a
// stalled peer looks the same as a peer that hung up, so "did it declare where
// the body ends?" is what separates a body from half of one.
rc = http_str_bytes(rchunk)
hb = http_str_bytes("HTTP/1.1 200 OK")
n = n + http_check("no length and no chunking is close-delimited", "" . http_close_delimited(rclose, len(rclose), 0), "1")
n = n + http_check("Content-Length is not close-delimited", "" . http_close_delimited(r200, len(r200), 0), "0")
n = n + http_check("chunked is not close-delimited", "" . http_close_delimited(rc, len(rc), 0), "0")
n = n + http_check("headerless bytes are close-delimited", "" . http_close_delimited(hb, len(hb), 0), "1")

n = n + http_check("a 404 is a status, not a failure", "" . http_status(http_str_bytes("HTTP/1.1 404 Not Found\r\n\r\n"), 0), "404")
n = n + http_check("a non-HTTP response has no status", "" . http_status(http_str_bytes("garbage\r\n\r\n"), 0), "0")
n = n + http_check("headerless bytes have no body", "" . http_body(hb, len(hb), 0), "0")

// Interim responses come first and carry no body; the answer is the response
// after them (RFC 9110 15.2). Reading the first head as the answer returned the
// real response's head as the body.
r103 = "HTTP/1.1 103 Early Hints\r\nLink: </x>; rel=preload\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
b103 = http_str_bytes(r103)
n = n + http_check("103 then 200: the body is the 200's", http_bodyof(r103, 0), "hello")
n = n + http_check("103 then 200: complete", http_doneof(r103, 0), "1")
n = n + http_check("103 then 200: the final head starts after the interim one", "" . http_final(b103, len(b103)), "" . (http_header_end(b103, 0, len(b103)) + 4))
n = n + http_check("103 then 200: its status", "" . http_status(b103, http_final(b103, len(b103))), "200")
r100 = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 102 Processing\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nworld"
n = n + http_check("two interim heads, then the answer", http_bodyof(r100, 0), "world")
n = n + http_check("an interim head and a partial answer are not complete", http_doneof("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 20", 0), "0")
n = n + http_check("an interim head alone is not complete", http_doneof("HTTP/1.1 100 Continue\r\n\r\n", 0), "0")
bmid = http_str_bytes("HTTP/1.1 103 Early Hints\r\nLink: x")
n = n + http_check("an interim head still arriving", "" . http_final(bmid, len(bmid)), "-1")
n = n + http_check("an interim head still arriving is not complete", http_doneof("HTTP/1.1 103 Early Hints\r\nLink: x", 0), "0")
r101 = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nno"
n = n + http_check("101 was never asked for: nothing more will make it complete", http_doneof(r101, 0), "-1")
n = n + http_check("101 has no body to give", http_bodyof(r101, 0), "none")

// A reply to HEAD, and any 204 or 304, ends where its head does, whatever
// Content-Length it gives, because that describes a body it doesn't send.
rhead = "HTTP/1.1 200 OK\r\nContent-Length: 500000000\r\n\r\n"
n = n + http_check("HEAD: complete at the end of the head", http_doneof(rhead, 1), "1")
n = n + http_check("HEAD: no body", http_bodyof(rhead, 1), "")
n = n + http_check("the same head for a GET is still owed its body", http_doneof(rhead, 0), "0")
bhead = http_str_bytes(rhead)
n = n + http_check("HEAD is not close-delimited", "" . http_close_delimited(bhead, len(bhead), 1), "0")
n = n + http_check("204: complete, whatever its Content-Length", http_doneof("HTTP/1.1 204 No Content\r\nContent-Length: 100\r\n\r\n", 0), "1")
n = n + http_check("204: no body", http_bodyof("HTTP/1.1 204 No Content\r\nContent-Length: 100\r\n\r\ntrailing", 0), "")
n = n + http_check("304: complete, whatever its Content-Length", http_doneof("HTTP/1.1 304 Not Modified\r\nContent-Length: 1234\r\n\r\n", 0), "1")
n = n + http_check("304: no body", http_bodyof("HTTP/1.1 304 Not Modified\r\n\r\n", 0), "")

// Content-Length is a length or the response is unusable (RFC 9112 6.3). It's
// never a reason to read until the peer closes, and never an arithmetic fault.
rhuge = "HTTP/1.1 200 OK\r\nContent-Length: 999999999999999999999999999999\r\n\r\nabc"
n = n + http_check("thirty digits: unusable, not an overflow", http_doneof(rhuge, 0), "-1")
n = n + http_check("thirty digits: no body", http_bodyof(rhuge, 0), "none")
n = n + http_check("digits then letters: unusable", http_doneof("HTTP/1.1 200 OK\r\nContent-Length: 12abc\r\n\r\nabc", 0), "-1")
n = n + http_check("a negative length: unusable", http_doneof("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\nabc", 0), "-1")
n = n + http_check("an empty length: unusable", http_doneof("HTTP/1.1 200 OK\r\nContent-Length:\r\n\r\nabc", 0), "-1")
n = n + http_check("two lengths that disagree: unusable", http_doneof("HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabcd", 0), "-1")
n = n + http_check("a list that disagrees: unusable", http_doneof("HTTP/1.1 200 OK\r\nContent-Length: 3, 4\r\n\r\nabcd", 0), "-1")
n = n + http_check("one length said twice is one length", http_bodyof("HTTP/1.1 200 OK\r\nContent-Length: 3, 3\r\n\r\nabcdef", 0), "abc")
n = n + http_check("the same header twice is one length", http_bodyof("HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\nabcdef", 0), "abc")
n = n + http_check("whitespace around a length is not part of it", http_bodyof("HTTP/1.1 200 OK\r\nContent-Length:  3 \r\n\r\nabcdef", 0), "abc")
n = n + http_check("eighteen digits are a number", "" . http_num(http_str_bytes("999999999999999999")), "999999999999999999")
n = n + http_check("nineteen are not", "" . http_num(http_str_bytes("1000000000000000000")), "-1")

// Only the last transfer coding decides the framing, and it outranks a length.
n = n + http_check("chunked last: chunked", http_bodyof("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n", 0), "abc")
bte = http_str_bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked, gzip\r\n\r\nraw")
n = n + http_check("chunked not last: read to the close", "" . http_close_delimited(bte, len(bte), 0), "1")
n = n + http_check("chunked not last: the body is what came", http_bodyof("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked, gzip\r\n\r\nraw", 0), "raw")
rtecl = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 99\r\n\r\n2\r\nok\r\n0\r\n\r\n"
n = n + http_check("chunked outranks a Content-Length", http_bodyof(rtecl, 0), "ok")
n = n + http_check("and says when it is done", http_doneof(rtecl, 0), "1")

// --- the head, looked for a read at a time --------------------------------
// A read loop asks after every read whether the head has all arrived. The head
// used to be searched from its first byte each time, so one that never ended
// cost the square of its size. http_frame_more searches only what's new, and
// has to answer what http_frame answers on every prefix of every framing.
n = n + http_check("the resumed head search agrees: Content-Length", http_frames_agree("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\nhello", 0), "yes")
n = n + http_check("the resumed head search agrees: chunked", http_frames_agree(rchunk, 0), "yes")
n = n + http_check("the resumed head search agrees: two interim heads", http_frames_agree(r100, 0), "yes")
n = n + http_check("the resumed head search agrees: 103 then 200", http_frames_agree(r103, 0), "yes")
n = n + http_check("the resumed head search agrees: 101", http_frames_agree(r101, 0), "yes")
n = n + http_check("the resumed head search agrees: a reply to HEAD", http_frames_agree(rhead, 1), "yes")
n = n + http_check("the resumed head search agrees: a length that isn't one", http_frames_agree(rhuge, 0), "yes")
n = n + http_check("the resumed head search agrees: bytes with no head", http_frames_agree("HTTP/1.1 200 OK", 0), "yes")
// Where the search picks up: past the interim head it already read, and three
// bytes short of the end, where the blank line could still begin.
hst = text(3)
hpart = http_str_bytes("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nX-Long: abcdefgh")
hf = http_frame_more(hpart, len(hpart), 0, hst)
n = n + http_check("an unfinished head: not framed yet, and the search stops where it got to", "" . hf[2] . " " . hst[1] . " " . hst[2], "0 25 " . (len(hpart) - 3))
// Once the final head has arrived the frame is kept, and asking again, even
// about fewer bytes, doesn't search anything.
hdone = http_str_bytes("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")
hst2 = text(3)
http_frame_more(hdone, len(hdone), 0, hst2)
n = n + http_check("a settled frame is kept", "" . http_frame_more(hdone, 3, 0, hst2)[2] . " " . http_frame_more(hdone, 3, 0, hst2)[3], "2 5")

// --- a large chunked body ------------------------------------------------
// 16 MiB in 1 KiB chunks: a quarter of net's response ceiling, in chunks of an
// ordinary size for a streaming server. test_crypto_w.sh runs this KAT under a
// 256 MB address-space cap where the platform has one. Decoding in place takes
// one copy of the body. Joining chunk by chunk used to keep every intermediate
// copy, about 137 GB for this one.
http_big()
    head = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
    chunk = 1024
    count = 16384
    // each chunk is "400" CRLF, the data, CRLF; then "0" CRLF CRLF ends it
    total = len(head) + count * (5 + chunk + 2) + 5
    b = bytes(total)
    i = 0
    loop i < len(head)
        b[i] = head[i]
        i = i + 1
    p = len(head)
    k = 0
    loop k < count
        b[p] = 52
        b[p + 1] = 48
        b[p + 2] = 48
        b[p + 3] = 13
        b[p + 4] = 10
        p = p + 5
        j = 0
        loop j < chunk
            b[p + j] = 97 + ((k + j) % 26)
            j = j + 1
        p = p + chunk + 2
        b[p - 2] = 13
        b[p - 1] = 10
        k = k + 1
    b[p] = 48
    b[p + 1] = 13
    b[p + 2] = 10
    b[p + 3] = 13
    b[p + 4] = 10
    if http_complete(b, total, 0) != 1
        return "not complete"
    body = http_body(b, total, 0)
    if len(body) != count * chunk
        return "" . len(body) . " bytes"
    // byte j of chunk k is 'a' + (k + j) mod 26, so the first and last byte of
    // every chunk say whether it landed where it belongs
    k = 0
    loop k < count
        if body[k * chunk] != 97 + (k % 26)
            return "chunk " . k . " out of place"
        if body[k * chunk + chunk - 1] != 97 + ((k + chunk - 1) % 26)
            return "chunk " . k . " cut short"
        k = k + 1
    return "whole"
n = n + http_check("a 16 MiB body in 1 KiB chunks decodes in place", http_big(), "whole")

total = 132
out("http (url, request, response framing): " . n . " of " . total . " vectors match")
if n == total
    return 0
return 1
