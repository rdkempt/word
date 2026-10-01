#!/bin/sh
# test_tls_surface.sh: SPEC 12.2's TLS 1.3 tables against the bytes the client
# sends.
#
# Whether a server will talk to the client depends on the suites, groups,
# signature schemes and extensions in the ClientHello, and on what's missing
# from it. SPEC 12.2 lists both as tables, and this checks them against the
# wire. There are three links, and this is the middle one:
#
#   SPEC 12.2 tables  <-- here -->  the pinned ClientHello  <-- test_crypto_w -->
#   tls13_client_hello_g
#
# test_crypto_w.sh checks that the encoder produces the pinned bytes (two
# vectors in crypto_w/tls_kat.w: a first flight and a retry). This decodes the
# same bytes and checks them against the SPEC. Change what the client offers
# and the KAT fails; update the KAT and this fails until the SPEC catches up.
#
# The decoding is in awk, not word: a check written in word, next to the code
# that encodes the hello, would only restate it.
set -e
LC_ALL=C; export LC_ALL
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd); cd "$root"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1 -- $2"; }

# ---- the bytes -------------------------------------------------------------
# The two pinned ClientHellos, taken from the KAT instead of re-encoded, so
# this test and test_crypto_w can't be looking at different bytes.
# The expected value is the long hex literal on the line; the shorter ones on it
# are inputs (a key share, a cookie), so the length floor picks the hello out.
grep -F 'check("client hello encodes' "$here/crypto_w/tls_kat.w" \
  | grep -oE '[0-9a-f]{100,}' | tail -1 > "$tmp/ch1"
grep -F 'check("a retry ClientHello is the first flight' "$here/crypto_w/tls_kat.w" \
  | grep -oE '[0-9a-f]{100,}' | tail -1 > "$tmp/ch2"
[ -s "$tmp/ch1" ] || { echo "FAIL: no first-flight ClientHello vector in tls_kat.w"; exit 1; }
[ -s "$tmp/ch2" ] || { echo "FAIL: no retry ClientHello vector in tls_kat.w"; exit 1; }

# ---- the decoder -----------------------------------------------------------
# RFC 8446 4.1.2, over the handshake header: type(1) length(3), then
# legacy_version(2) random(32) session_id(u8) cipher_suites(u16)
# legacy_compression(u8) extensions(u16). Emits one `field 0xNNNN` line per code
# it finds, which is the form the tables are compared in.
decode_hello() {
  awk -v hex="$(cat "$1")" '
    # mawk has no strtonum, and this has to run wherever CI does.
    function hv(s,   i, v) { v = 0; for (i = 1; i <= length(s); i++) v = v * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1; return v }
    function u16(i) { return hv(substr(hex, i * 2 + 1, 4)) }
    function u8(i)  { return hv(substr(hex, i * 2 + 1, 2)) }
    function emit(what, v) { printf "%s 0x%04x\n", what, v }
    BEGIN {
      off = 4 + 2 + 32
      off += 1 + u8(off)                    # session_id
      cslen = u16(off); off += 2
      for (i = 0; i < cslen; i += 2) emit("suite", u16(off + i))
      off += cslen
      off += 1 + u8(off)                    # legacy_compression_methods
      extlen = u16(off); off += 2
      end = off + extlen
      while (off + 4 <= end) {
        et = u16(off); el = u16(off + 2); off += 4
        emit("ext", et)
        if (et == 10) { n = u16(off); for (i = 0; i < n; i += 2) emit("group",  u16(off + 2 + i)) }
        if (et == 13) { n = u16(off); for (i = 0; i < n; i += 2) emit("scheme", u16(off + 2 + i)) }
        if (et == 43) { n = u8(off);  for (i = 0; i < n; i += 2) emit("version", u16(off + 1 + i)) }
        if (et == 51) emit("keyshare", u16(off + 2))
        off += el
      }
      if (off != end) { print "TRAILING"; exit 1 }
    }' /dev/null
}

decode_hello "$tmp/ch1" > "$tmp/d1" || { echo "FAIL: the first-flight ClientHello does not decode"; exit 1; }
decode_hello "$tmp/ch2" > "$tmp/d2" || { echo "FAIL: the retry ClientHello does not decode"; exit 1; }
grep -q TRAILING "$tmp/d1" "$tmp/d2" && { echo "FAIL: a ClientHello has trailing bytes"; exit 1; }
sort -u "$tmp/d1" > "$tmp/wire"

# ---- the SPEC tables -------------------------------------------------------
# Each row of the offered table gives its codes as `0xNNNN`. The row is found by
# the field it names, so reordering the table does not matter.
spec_row() {
  grep -F "$1" SPEC.md | grep -oE '0x[0-9a-f]{4}' | sort -u
}
cmp_set() { # <what> <prefix> <spec codes file>
  awk -v p="$2" '$1 == p { print $2 }' "$tmp/wire" | sort -u > "$tmp/got"
  missing=$(comm -13 "$tmp/got" "$3" | tr '\n' ' ')
  extra=$(comm -23 "$tmp/got" "$3" | tr '\n' ' ')
  [ -z "$missing" ] || bad "$1: SPEC 12.2 lists what the ClientHello does not send" "$missing"
  [ -z "$extra" ]   || bad "$1: the ClientHello sends what SPEC 12.2 does not list" "$extra"
  [ -n "$missing$extra" ] || ok "$1: $(wc -l < "$tmp/got" | tr -d ' ') code(s), SPEC and wire agree"
}

spec_row '| Cipher suites |'          > "$tmp/s_suite"
spec_row '| `supported_versions` |'   > "$tmp/s_version"
spec_row '| `supported_groups` |'     > "$tmp/s_group"
spec_row '| `signature_algorithms` |' > "$tmp/s_scheme"
spec_row '| Extensions |'             > "$tmp/s_ext"
for f in suite version group scheme ext; do
  [ -s "$tmp/s_$f" ] || { echo "FAIL: SPEC 12.2 has no $f row, or it lists no codes"; exit 1; }
done

cmp_set "cipher suites"        suite   "$tmp/s_suite"
cmp_set "supported_versions"   version "$tmp/s_version"
cmp_set "supported_groups"     group   "$tmp/s_group"
cmp_set "signature_algorithms" scheme  "$tmp/s_scheme"
cmp_set "extensions"           ext     "$tmp/s_ext"

# ---- key_share and the retry ----------------------------------------------
# The one field whose value differs between the two flights. Apart from the
# cookie, it's all a retry changes.
grep -qx 'keyshare 0x001d' "$tmp/d1" \
  && ok "a first flight's key_share is x25519, as 12.2 says" \
  || bad "a first flight's key_share is not x25519" "$(grep '^keyshare' "$tmp/d1")"
grep -qx 'keyshare 0x0017' "$tmp/d2" \
  && ok "a retry's key_share is the group the server named" \
  || bad "a retry's key_share is not the retried group" "$(grep '^keyshare' "$tmp/d2")"
grep -qx 'ext 0x002c' "$tmp/d2" \
  && ok "a retry echoes the cookie (0x002c), and a first flight does not" \
  || bad "a retry does not carry the cookie extension" "$(grep '^ext' "$tmp/d2" | tr '\n' ' ')"
grep -qx 'ext 0x002c' "$tmp/d1" && bad "a first flight carries a cookie" "there is nothing to echo yet"

# Otherwise a retry must match the first flight: the same suites, groups and
# schemes. A retry that offered less would be a downgrade the tables don't
# describe.
for f in suite group scheme; do
  a=$(awk -v p="$f" '$1 == p { print $2 }' "$tmp/d1" | sort -u | tr '\n' ' ')
  b=$(awk -v p="$f" '$1 == p { print $2 }' "$tmp/d2" | sort -u | tr '\n' ' ')
  [ "$a" = "$b" ] || bad "a retry offers different ${f}s than the first flight" "[$a] vs [$b]"
done
ok "a retry offers the same suites, groups and schemes as the first flight"

# ---- the other table: what must be absent ---------------------------------
# Every code SPEC 12.2 lists as not implemented, checked against every code the
# ClientHello carries. Rows without a code (NewSessionTicket, a TLS server and
# the like) describe behaviour, not a wire value, and tls_kat.w and
# docs/SECURITY.md section 5 cover them. The client-certificate row has one of
# each: its post_handshake_auth code is checked here like any other, and
# tls_kat.w and test_net_verbs.sh check the empty Certificate that answers a
# CertificateRequest.
sed -n '/^| Not implemented |/,/^$/p' SPEC.md | grep -oE '0x[0-9a-f]{4}' | sort -u > "$tmp/absent"
[ -s "$tmp/absent" ] || { echo "FAIL: SPEC 12.2's not-implemented table lists no codes"; exit 1; }
# One space-separated line, so the membership test below has a space on both
# sides of every code. Newline-separated, it matched only the first and last
# entry, and the check passed on a ClientHello that did send one.
sent=$(awk '{ print $2 }' "$tmp/d1" "$tmp/d2" | sort -u | tr '\n' ' ')
found=""
for c in $(cat "$tmp/absent"); do
  case " $sent " in *" $c "*) found="$found $c";; esac
done
[ -z "$found" ] \
  && ok "none of the $(wc -l < "$tmp/absent" | tr -d ' ') codes 12.2 calls unimplemented is on the wire" \
  || bad "SPEC 12.2 says these are not implemented, but the ClientHello sends them" "$found"

# And the record layer must accept the two suites the first table names, and
# no others.
accepted=$(python3 "$root/dev/toolchain/netlib_cat.py" net \
           | sed -n '/^net_suite(wire)/,/return 0 - 1/p' \
           | grep -oE 'wire == [0-9]+' | grep -oE '[0-9]+' \
           | while read -r d; do printf '0x%04x\n' "$d"; done | sort -u | tr '\n' ' ')
want=$(sort -u "$tmp/s_suite" | tr '\n' ' ')
[ "$accepted" = "$want" ] \
  && ok "net_suite accepts exactly the suites the table offers" \
  || bad "net_suite and SPEC 12.2 disagree about the accepted suites" "[$accepted] vs [$want]"

echo "test_tls_surface: $pass passed, $fail failed"
[ "$fail" = 0 ]
