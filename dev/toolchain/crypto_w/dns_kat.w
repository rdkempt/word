// Known-answer tests for the net library's dns.w. The query encoder is checked
// against a byte-exact reference message, and the response parser against
// captured wire formats, including the shapes a careless parser gets wrong: a
// compression pointer in the answer's name, a CNAME ahead of the A record, and
// the truncations and bad RCODEs that have to fail as data, not as a crash.
dns_hex_of(b)
    d = "0123456789abcdef"
    s = bytes(len(b) * 2)
    i = 0
    loop i < len(b)
        s[i * 2] = d[(b[i] >> 4) & 15]
        s[i * 2 + 1] = d[b[i] & 15]
        i = i + 1
    return s

dns_nib(c)
    if c >= 48 && c <= 57
        return c - 48
    return c - 87

dns_un_hex(t)
    b = bytes((len(t) >> 1))
    i = 0
    loop i < len(b)
        b[i] = dns_nib(t[i * 2]) * 16 + dns_nib(t[i * 2 + 1])
        i = i + 1
    return b

dns_check(name, got, want)
    if got == want
        return 1
    err("  FAIL: " . name)
    err("    want " . want)
    err("    got  " . got)
    return 0

// An A answer is four bytes; render it dotted so a failure is readable.
dns_dotted(ip)
    if kind(ip) == "number"
        return "none"
    return "" . ip[0] . "." . ip[1] . "." . ip[2] . "." . ip[3]

n = 0

// --- the question --------------------------------------------------------
// example.com, id 0x1234: header (id, RD, qdcount 1) then 7example3com0, A, IN.
n = n + dns_check("query encodes example.com",
    dns_hex_of(dns_query("example.com", 4660)),
    "123401000001000000000000076578616d706c6503636f6d0000010001")

n = n + dns_check("a name with one label encodes",
    dns_hex_of(dns_encode_name("a")), "016100")

n = n + dns_check("an empty name is refused", "" . dns_encode_name(""), "0")

// A 64-byte label is one over the limit.
n = n + dns_check("an oversized label is refused",
    "" . dns_encode_name("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), "0")

n = n + dns_check("a doubled dot is refused", "" . dns_encode_name("a..b"), "0")

// --- the answer ----------------------------------------------------------
// One A record for example.com -> 93.184.216.34, the answer's name given as a
// compression pointer back to the question (0xc00c).
resp_a = dns_un_hex("123481800001000100000000076578616d706c6503636f6d0000010001c00c000100010000012c00045db8d822")
n = n + dns_check("an A record is found", dns_dotted(dns_parse_a(resp_a)), "93.184.216.34")

// A CNAME (type 5) ahead of the A record: skipped, not rejected.
resp_cname = dns_un_hex("123481800001000200000000076578616d706c6503636f6d0000010001c00c000500010000012c0002c00cc00c000100010000012c00045db8d822")
n = n + dns_check("a CNAME before the A record is skipped", dns_dotted(dns_parse_a(resp_cname)), "93.184.216.34")

// NXDOMAIN: RCODE 3, no answers.
resp_nx = dns_un_hex("123481830001000000000000076578616d706c6503636f6d0000010001")
n = n + dns_check("NXDOMAIN yields no address", dns_dotted(dns_parse_a(resp_nx)), "none")

// A query reflected back with QR clear is not an answer.
resp_q = dns_un_hex("123401000001000100000000076578616d706c6503636f6d0000010001c00c000100010000012c00045db8d822")
n = n + dns_check("a response without QR is refused", dns_dotted(dns_parse_a(resp_q)), "none")

// RDLENGTH says 4 but only two bytes follow: must not read past the end.
resp_short = dns_un_hex("123481800001000100000000076578616d706c6503636f6d0000010001c00c000100010000012c00045db8")
n = n + dns_check("a truncated RDATA is refused", dns_dotted(dns_parse_a(resp_short)), "none")

n = n + dns_check("a header-only buffer is refused", dns_dotted(dns_parse_a(bytes(8))), "none")

// --- the literal-address shortcut ----------------------------------------
n = n + dns_check("a dotted quad resolves to itself", dns_dotted(dns_dotted_quad("127.0.0.1")), "127.0.0.1")
n = n + dns_check("the top of the range is a dotted quad", dns_dotted(dns_dotted_quad("255.255.255.255")), "255.255.255.255")
n = n + dns_check("256 is not an octet", dns_dotted(dns_dotted_quad("256.0.0.1")), "none")
n = n + dns_check("three octets is not an address", dns_dotted(dns_dotted_quad("1.2.3")), "none")
n = n + dns_check("a name is not a dotted quad", dns_dotted(dns_dotted_quad("example.com")), "none")
n = n + dns_check("a trailing dot is not a dotted quad", dns_dotted(dns_dotted_quad("1.2.3.4.")), "none")

// dns_resolve answers a literal address itself, without a resolver or a
// socket, which is why this can run with no network.
n = n + dns_check("resolve of a dotted quad needs no network", dns_dotted(dns_resolve("10.0.0.7")), "10.0.0.7")

// --- localhost (RFC 6761 6.3) -----------------------------------------------
// The loopback address, answered without a resolver, for localhost and every
// name under it, in any case, fully qualified or not. Nothing here can reach a
// resolver, since these are answered before a socket exists.
n = n + dns_check("localhost is the loopback address", dns_dotted(dns_resolve("localhost")), "127.0.0.1")
n = n + dns_check("a name under localhost is too", dns_dotted(dns_resolve("api.localhost")), "127.0.0.1")
n = n + dns_check("in any case, with the trailing dot", dns_dotted(dns_resolve("LocalHost.")), "127.0.0.1")
n = n + dns_check("two labels under it", dns_dotted(dns_resolve("a.b.LOCALHOST")), "127.0.0.1")
// ...and only those. Asked of the predicate, not of dns_resolve, because an
// ordinary name goes to a resolver and this driver runs with no network.
n = n + dns_check("a name that merely ends in localhost is not", "" . dns_is_localhost("mylocalhost"), "false")
n = n + dns_check("localhost as a label further left is not", "" . dns_is_localhost("localhost.example.com"), "false")
n = n + dns_check("an empty label before it is not a name", "" . dns_is_localhost(".localhost"), "false")
n = n + dns_check("two trailing dots are not a name", "" . dns_is_localhost("localhost.."), "false")
n = n + dns_check("a short name is not localhost", "" . dns_is_localhost("local"), "false")

// --- the resolver the host names -----------------------------------------
// Whatever the host says (sys.nameservers() on Windows, /etc/resolv.conf
// elsewhere), or 1.1.1.1, it has to be four bytes.
srv = dns_server()
n = n + dns_check("a resolver is always named", "" . len(srv), "4")

// A resolv.conf line, read the way glibc reads it: the address is the word
// after the keyword, and anything after that is ignored. A trailing space, tab,
// comment or CR used to make the line unusable, so word asked 1.1.1.1 while the
// host's other programs asked the resolver the file named.
n = n + dns_check("a nameserver line", dns_dotted(dns_conf_line("nameserver 10.9.8.7")), "10.9.8.7")
n = n + dns_check("with a trailing space", dns_dotted(dns_conf_line("nameserver 10.9.8.7 ")), "10.9.8.7")
n = n + dns_check("with a trailing tab", dns_dotted(dns_conf_line("nameserver 10.9.8.7\t")), "10.9.8.7")
n = n + dns_check("with a trailing comment", dns_dotted(dns_conf_line("nameserver 10.9.8.7 # office")), "10.9.8.7")
n = n + dns_check("with the CR of a CRLF file", dns_dotted(dns_conf_line("nameserver 10.9.8.7\r")), "10.9.8.7")
n = n + dns_check("a tab and spaces after the keyword", dns_dotted(dns_conf_line("nameserver\t  172.16.0.1")), "172.16.0.1")
n = n + dns_check("an indented line is not a directive", dns_dotted(dns_conf_line("  nameserver 1.2.3.4")), "none")
n = n + dns_check("a longer keyword is not this one", dns_dotted(dns_conf_line("nameserverfoo 1.2.3.4")), "none")
n = n + dns_check("a comment glued to the address spoils it", dns_dotted(dns_conf_line("nameserver 10.9.8.7#office")), "none")
n = n + dns_check("an IPv6 resolver is not this one", dns_dotted(dns_conf_line("nameserver 2001:db8::53")), "none")
n = n + dns_check("an octet out of range", dns_dotted(dns_conf_line("nameserver 999.1.1.1 ")), "none")
n = n + dns_check("a keyword with no address", dns_dotted(dns_conf_line("nameserver    ")), "none")
n = n + dns_check("another directive", dns_dotted(dns_conf_line("search example.internal")), "none")

out("dns (query, response parsing, literals, localhost, resolv.conf): " . n . " of 41 vectors match")
if n == 41
    return 0
return 1
