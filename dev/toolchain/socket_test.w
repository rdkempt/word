// socket_test.w: the four socket primitives over loopback (run by
// test_sockets.sh, which starts a small server that replies "PONG\n"). A
// refused connection returns 0, a live one round-trips PING -> PONG, and a send
// after the server has closed answers 0 instead of ending the program.
//
// Given a port as its argument, it also connects to a peer there that never
// answers the handshake, and connect() has to give up with 0 at its ten-second
// deadline instead of waiting the kernel's two minutes.
import sys
lo = bytes(4)
lo[0] = 127
lo[1] = 0
lo[2] = 0
lo[3] = 1
n = 0
want = 3

a = args()
if len(a) > 1
    want = 4
    t0 = now()
    r = connect(lo, number(a[1]))
    took = now() - t0
    if r == 0 && took > 8000000000 && took < 18000000000
        n = n + 1
        out("  connect to a peer that never answers gives up at its deadline: ok")
    else
        err("  FAIL: connect to a silent peer answered " . r . " after " . (took >> 20) . " ms (x1.048576)")

// A connection to a port nothing listens on returns the number 0, not an fd.
if connect(lo, 1) == 0
    n = n + 1
    out("  connect to a closed port returns 0: ok")
else
    err("  FAIL: connect to port 1 unexpectedly succeeded")

fd = connect(lo, 51987)
if fd == 0
    err("  FAIL: connect to the loopback server failed")
    return 1

msg = "PING"
mb = bytes(4)
i = 0
loop i < 4
    mb[i] = msg[i]
    i = i + 1
if send(fd, mb) == 4
    n = n + 1
    out("  send returns the byte count: ok")
else
    err("  FAIL: send did not return 4")

buf = bytes(64)
g = recv(fd, buf)
if g >= 4 && buf[0] == 80 && buf[1] == 79 && buf[2] == 78 && buf[3] == 71
    n = n + 1
    out("  recv returns PONG: ok")
else
    err("  FAIL: recv did not return PONG")

// The server closes after its PONG. A send to a peer that has closed fails and
// answers 0. On Linux a send there used to raise SIGPIPE and end the program,
// and nothing the network does may do that (SPEC 12.2). The first send can
// still be accepted before the peer's reset comes back, so this sends until
// three have failed.
want = want + 1
t0 = now()
loop now() - t0 < 200000000
    k = 0
k = 0
fails = 0
loop k < 50 && fails < 3
    if send(fd, mb) == 0
        fails = fails + 1
    k = k + 1
if fails == 3
    n = n + 1
    out("  send to a peer that has closed answers 0: ok")
else
    err("  FAIL: send to a peer that has closed answered a count " . (k - fails) . " times")
cl = close(fd)

// Windows keeps a table of 64 open sockets, so read, write and close know a
// socket from a file handle. A 65th answers 0, as a failed connect does,
// instead of becoming a socket the table doesn't know. Linux has no such
// table. Either way, closing one makes room again.
want = want + 1
ip = bytes("7f000001")
fds = text(65)
opened = 0
k = 0
loop k < 65
    fds[k] = udp(ip, 9)
    if fds[k] != 0
        opened = opened + 1
    k = k + 1
k = 0
loop k < 65
    if fds[k] != 0
        cl = close(fds[k])
    k = k + 1
fd = udp(ip, 9)
again = fd != 0
if again
    cl = close(fd)
expect = 65
if os() == 1
    expect = 64
if opened == expect && again
    n = n + 1
    out("  " . opened . " of 65 UDP sockets open at once, and one more after closing them: ok")
else
    err("  FAIL: " . opened . " of 65 UDP sockets opened (want " . expect . "), and one after closing: " . again)

out("sockets: " . n . " of " . want . " checks pass")
if n == want
    return 0
return 1
