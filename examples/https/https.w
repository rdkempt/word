// https.w: an HTTPS GET with nothing but word itself (its own TLS 1.3, no
// libraries).
// Run:  word run examples/https/https.w   (the scheme defaults to https, SPEC 12.2)

body = get("api.github.com/rate_limit")
if body == none
    out("request failed")
else
    // copy(s, start, end) faults unless end <= len(s) (SPEC 9), so clamp the
    // preview. A short body, like a redirect page, mustn't fault the demo.
    n = len(body)
    if n > 60
        n = 60
    out("got " . len(body) . " characters")
    out(copy(body, 0, n))
