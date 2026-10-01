// fuzz_handshake.w: the TLS handshake fuzz driver, run by
// dev/toolchain/test_fuzz_tls.sh.
//
// fuzz_x509.w covers the certificate decoder. This covers everything that runs
// before it, on the first bytes a server sends and before any of them have
// been authenticated: the handshake framing, the ServerHello, the
// HelloRetryRequest it has to be told apart from, the CertificateRequest a
// server may send, the Certificate message that carries the chain, the record
// layer that unwraps the flight, and the client state machine that drives all
// of them.
//
// Reads one mutated message from argv[1] and puts it everywhere a server's
// bytes go. Each parser is called twice, once on the message as the record
// layer frames it and once on the raw bytes as a bare body, so a mutation that
// lands on the type byte still reaches the parser it was aimed at. Then the
// same bytes stand in for the ServerHello, the encrypted record, and the whole
// server flight, which puts the key schedule and the state machine on
// unauthenticated input too.
//
// Everything here is expected to return. It exits 0 whatever it returns; see
// fuzz_x509.w for what a failure looks like and why a bounds fault is one.
fz_argpath()
    a = args()
    if len(a) < 2
        err("fuzz_handshake: no input file")
    return a[1]

fz_msg = read(fz_argpath())

// ---- the decoders, framed and bare

tls13_hs_type(fz_msg)
tls13_hs_len(fz_msg)
tls13_hs_split(fz_msg)
tls13_flight_complete(fz_msg)
fz_body = tls13_hs_body(fz_msg)
if kind(fz_body) != "number"
    tls13_parse_server_hello(fz_body)
    tls13_parse_certificate(fz_body)
    tls13_parse_cert_request(fz_body)
    tls13_is_hrr(fz_body)
    fz_hr = tls13_parse_hrr(fz_body)
    // and what the driver asks of a retry before it answers one
    if kind(fz_hr) != "number"
        tls13_hrr_check(fz_hr, bytes(32), 29)
tls13_parse_server_hello(fz_msg)
tls13_parse_certificate(fz_msg)
tls13_parse_cert_request(fz_msg)
tls13_is_hrr(fz_msg)
fz_hr2 = tls13_parse_hrr(fz_msg)
if kind(fz_hr2) != "number"
    tls13_hrr_check(fz_hr2, bytes(32), 29)

// The two questions the driver asks of what arrives where the ServerHello
// should be, before anything else reads it: is it one whole ServerHello, and
// does it echo the session id this client sent.
fz_shb = tls13_server_hello_body(fz_msg)
if kind(fz_shb) != "number"
    tls13_echoes_session(fz_shb, bytes(32))
    tls13_echoes_session(fz_shb, bytes(0))
    tls13_is_hrr(fz_shb)
tls13_echoes_session(fz_msg, bytes(32))

// ---- and the client that calls them

// This client's own key share. It's fixed, not random: what's being tested is
// what the server sends back, and a constant keeps each run's cost to the one
// scalar multiplication the handshake needs.
fz_priv = bytes(32)
fz_priv[31] = 7
fz_ch = tls13_client_hello(bytes(32), bytes(32), x25519_base(fz_priv), "fuzz.example")

// the mutated message as the ServerHello: parsed, then its key_share handed
// straight to the key exchange, then hashed into the transcript
fz_hk = tls13_client_handshake_keys(fz_ch, fz_priv, fz_msg)
if kind(fz_hk) != "number"
    fz_key = tls13_write_key(fz_hk[2], 32)
    fz_iv = tls13_write_iv(fz_hk[2])
    // as an encrypted record, which is the shape the flight arrives in
    tls13_open(fz_hk[0], fz_key, fz_iv, 0, fz_msg)
    // and as the decrypted flight itself: four messages the client splits,
    // types, hashes and checks a MAC over
    fz_fl = tls13_client_process_flight(fz_ch, fz_msg, fz_msg, fz_hk[3], fz_hk[1], fz_hk[2])
    if kind(fz_fl) != "number"
        tls13_authenticate(fz_fl[3], text(0), "fuzz.example", 1788136049, fz_fl[4], fz_fl[5])

// the mutated message as the whole decrypted server flight, whatever the
// ServerHello above made of it. The secrets are fixed, so no Finished here will
// verify, but the split, the order of the messages and a CertificateRequest's
// framing are all read before the MAC is, so a flight seed puts every one of
// them on unauthenticated input.
tls13_client_process_flight(fz_ch, fz_ch, fz_msg, fz_priv, fz_priv, fz_priv)

// the mutated message as a HelloRetryRequest, whose transcript is rewritten
// instead of extended (4.4.1)
tls13_hrr_transcript(fz_ch, fz_msg, fz_ch)

// the record builder, on a content length it didn't choose
tls13_seal(19, bytes(32), bytes(12), 0, fz_msg, 22, 0)

// ecdh.w is carried whole because tls.w calls ec_ecdh, and word requires a
// program to use every function it defines. ec_pubkey is a client deriving a
// NIST key share, and this one offers x25519, so nothing above reaches it.
// Running it on the empty input satisfies the rule without putting a second
// scalar multiplication on the path every mutant takes.
if len(fz_msg) == 0
    ec_pubkey(1, fz_priv)
