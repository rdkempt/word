// 200 HTTP GETs against a local server, one connection each, summing the bytes.
// word's net module is written from scratch (its own DNS resolver and HTTP/1.1
// client over the kernel's sockets, with no libc and nothing linked), so this
// measures that stack, not a library's. get() opens a new connection per call,
// which is why every other language here is told not to reuse connections
// either.
n = 200
i = 0
total = 0
loop i < n
    total = total + len(get("http://127.0.0.1:4491/p"))
    i = i + 1
out(total)
