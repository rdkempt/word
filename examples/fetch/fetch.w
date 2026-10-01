// fetch: get a URL and print it, or save it to a file.
//
// Run:
//   word run fetch.w https://ryankempt.com/                 print the body
//   word run fetch.w https://ryankempt.com/ out.html        save it instead
//   word run fetch.w -insecure https://self-signed.local/  skip certificate checks
//
// Everything under this is word's own: the resolver, the TCP connect, the
// HTTP/1.1 request and, for https, a TLS 1.3 handshake that verifies the
// server's certificate chain against the operating system's trust store. The
// built binary is about 420 KB on x86-64 Linux, statically linked.
//
// It exits 0 even when the fetch fails, because err() doesn't set the exit
// status. A script should check stderr or the output, not the exit code.

a = args()
insecure = false
ai = 1
if len(a) > 1 && a[1] == "-insecure"
    insecure = true
    ai = 2

url = ""
if ai < len(a)
    url = a[ai]
dest = ""
if ai + 1 < len(a)
    dest = a[ai + 1]

if len(url) == 0
    err("usage: fetch [-insecure] <url> [outfile]")
else
    body = get(url, insecure)
    if body == none
        // get() answers none on any failure (DNS, the connection, the
        // certificate). Most failures have already printed a "net:" line on
        // stderr saying which, but a refused connection prints nothing. none
        // equals nothing else, so comparing with it is the whole check.
        err("fetch: could not get " . url)
    else
        if len(dest) > 0
            if !write(dest, body)
                err("fetch: could not write " . dest)
            else
                out(len(body) . " code points -> " . dest)
        else
            out(body)
