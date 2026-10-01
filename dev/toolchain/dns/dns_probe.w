// dns_probe.w: prints the resolver dns_server() settled on, as a dotted quad,
// for dev/toolchain/test_dns_conf.sh to compare with what it wrote into
// /etc/resolv.conf.
//
// The obvious end-to-end check, pointing resolv.conf at a black hole and
// watching a lookup fail, can't be written in a sandbox that answers UDP:53
// from any destination: a wrong nameserver still resolves, and the test would
// pass while proving nothing. So this prints the address the parser chose.
//
// Given names as arguments, it resolves each instead, one `name address` line
// apiece. That's for the localhost cases, which the test runs against a
// resolver of its own that records every name it's asked for.
//
// The test builds it after the dns module (netlib_cat.py dns), never where it
// sits.
dotted(ip)
    if kind(ip) == "number"
        return "none"
    return "" . ip[0] . "." . ip[1] . "." . ip[2] . "." . ip[3]

a = args()
if len(a) > 1
    i = 1
    loop i < len(a)
        out(a[i] . " " . dotted(dns_resolve(a[i])))
        i = i + 1
else
    out(dotted(dns_server()))
    // A dotted quad answers itself, without asking anyone. Printed second so
    // the test can check that the literal path never reaches the resolver.
    out(dotted(dns_resolve("203.0.113.9")))
