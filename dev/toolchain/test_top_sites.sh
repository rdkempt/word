#!/bin/sh
# test_top_sites.sh: how much of the popular web this client can talk to, as a
# number that may go up and not down.
#
# Every other net suite asks a question whose answer is known ahead: a fixture
# chain must be refused, a local openssl server must complete a handshake,
# twelve chosen hosts must answer. None of them caught the bug this suite was
# written for: x509_parse refused to decode any certificate whose signature
# algorithm it couldn't verify, which for a trust anchor meant dropping it from
# the store, and on Windows that removed 19 of 53 anchors. The fixtures and the
# twelve hosts passed while example.com, cloudflare.com and godaddy.com were
# "certificate not trusted" there.
#
# Breadth catches that. Fetch the top N domains and count: a trust store
# missing a third of its anchors takes a visible bite out of the count, and so
# does a profile rule that's too strict or a TLS 1.3 parameter the web has
# moved past.
#
# So the count is a gate, and the failures are sorted into buckets, which is
# the part worth reading. word speaks TLS 1.3 only and offers two cipher suites
# and three groups (SPEC 12.2). The web will move eventually: a rising `cipher`
# or `group` bucket is the sign that it has, and the reason to add one. A host in the `cert`, `word` or `tls13_other` bucket
# is a defect here, not the web changing, and those are gated at zero.
#
#   ok          the fetch returned a body
#   cert        word refused the chain and openssl, asked about the same
#               chain and the same name, accepts it   <- gated at 0, off Windows
#   name        word refused it and openssl refuses it too: the certificate
#               really is for another name, and refusing is correct
#   word        openssl handshakes with word's own parameters
#               where word doesn't                                <- gated at 0
#   cipher      TLS 1.3, but not with word's two suites
#   group       TLS 1.3, but not with word's three groups
#   tls13_other TLS 1.3 with word's suites and groups refused for some
#               other reason, most likely a signature algorithm  <- gated at 0
#   tls12       no TLS 1.3 at all: word doesn't downgrade, by design
#   declined    the peer answered our ClientHello with a close_notify and no
#               handshake: it hung up instead of negotiating
#   no_answer   the handshake finished, the request went out, and the peer
#               closed without sending a byte of response
#   flaky       word failed once and succeeded when asked again
#   slow        no answer inside the deadline
#   unreachable no TLS of any version answered: DNS, or the host
#   unexplained no bucket fits, which with no openssl is most
#               failures                                          <- gated at 0
#
# `declined` is bot management, not a defect. The peer objects to nothing: no
# alert naming a parameter, just a warning-level goodbye before it has said
# anything. A plain Go TLS 1.3 client (no ALPN, session tickets off, word's
# three groups) is hung up on by the same hosts, with and without ALPN, while
# openssl's much fuller ClientHello gets through, and curl gets a 200. These
# hosts refuse a minimal client, not anything word got wrong, so the bucket
# counts as explained. If it jumps, look again.
#
# The cert/name split has to be right, or the gate is noise. googlevideo.com
# serves a certificate for www.google.com and windows.net one for
# reroute443.microsoft.com; word refuses both, openssl refuses both, and neither
# is a defect. Only a chain openssl accepts under the same hostname is word's
# problem.
#
# openssl is what tells "the web changed" apart from "word is broken", as in
# test_x509_profile.sh, and nothing needs it to build or run word. Without it,
# a failure the stderr doesn't explain is reported as unexplained, and fails
# the run, instead of being excused.
#
#   TOP_SITES=100        how many domains (default 100; 1000 is the whole list)
#   TOP_SITES_JOBS=12    how many fetches at once
#   TOP_SITES_REQUIRE_NETWORK=1  a network that cannot reach the list fails the
#                        run, where by default it reports NETWORK-UNAVAILABLE
#
# Every run ends on one of three verdicts, TESTED, NETWORK-UNAVAILABLE or
# FAILED, and by default only the last exits non-zero. NETWORK-UNAVAILABLE is
# neither a pass nor a fail: a quarter of the list answering no TLS at all is
# the network, not word, and flaky Wi-Fi shouldn't fail the suite. It used to
# print SKIP and exit 0, which looked green in CI without having tested
# anything. Under GitHub Actions each verdict is also a line in the step
# summary, and the two that aren't TESTED are annotations.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
cd "$root"
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
LIST="$here/top_domains.txt"
[ -r "$LIST" ] || { echo "FAIL: no domain list at $LIST"; exit 1; }

N=${TOP_SITES:-100}
JOBS=${TOP_SITES_JOBS:-12}

# The baselines are measurements against the frozen list, with every host on it
# accounted for:
#
#   top 100     88 reached (2026-09-17); 9 serve no TLS 1.3, 3 serve a
#               certificate issued for another name entirely (googlevideo.com's
#               is for www.google.com, windows.net's for reroute443.microsoft.com)
#   top 1000    808 reached (2026-09-22, Linux); 129 no TLS 1.3, 40 hang up on
#               a minimal client, 17 a certificate for another name, 2 too slow
#               (justdial.com, businesswire.com), 4 gone
#
# The 1000 baseline went from 807 to 808 when the client began answering a
# CertificateRequest: bund.de, the one host on the list that asks for a client
# certificate, used to sit out the whole idle deadline and is fetched now.
#
# One baseline for both platforms. On Windows it counts `ok` plus the chains
# that failed only because the Crypt32 store lacked their anchor. That's the
# client's reach; `ok` alone there is the reach of one machine's store, which
# fills on demand (it grew by three hosts between two runs an hour apart). A CI
# runner's store is emptier than a workstation's, and a floor that moved with
# it couldn't be trusted.
#
# The tolerance is about 2% of N: one host's outage won't cross it and a
# systemic break will. When the number rises, raise the baseline so the floor
# keeps up.
case "$N" in
  100)  BASE=88;  TOL=2  ;;
  1000) BASE=808; TOL=20 ;;
  *)    BASE=0;   TOL=0  ;;   # an unmeasured N reports, and gates the rest
esac

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
res="$tmp/res"; mkdir -p "$res"
export TMPDIR="$tmp"

have_ssl=0
if command -v openssl >/dev/null 2>&1; then have_ssl=1; fi

# Are openssl and word looking at the same trust store? On Linux they are:
# openssl reads the PEM bundle net_load_roots reads, so "openssl accepts this
# chain and word doesn't" is word's problem, and it's gated at zero.
#
# On Windows they aren't. word reads the Crypt32 ROOT store, which holds what
# the machine has needed so far (53 anchors on the machine this was written on)
# and is filled on demand through an API word doesn't call, while Git for
# Windows' openssl carries its own bundle of about 150. A chain that anchors in
# one and not the other is a platform difference: uidai.gov.in's chain ends at
# emSign Root CA - G1, a root the Windows store doesn't have and a browser
# there would fetch on demand. So on Windows the bucket is reported and not
# gated, and the count guards against a store missing anchors instead.
same_store=1
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*|Windows*) same_store=0 ;;
esac
if [ "$have_ssl" = 0 ]; then
  echo "test_top_sites: note -- no openssl, so failures cannot be classified"
fi

# word's own TLS 1.3 offer, as SPEC 12.2 fixes it. openssl restricted to this
# tells whether a host can be reached with word's parameters at all.
W_SUITES=TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256
W_GROUPS=X25519:P-256:P-384

cat > "$tmp/probe.w" <<'WEOF'
a = args()
if len(a) < 2
    out("usage: probe <url>")
else
    b = get(a[1])
    if b == none
        // get() answers none on any failure and has already said which on
        // stderr, which is what the classifier reads.
        out("NONE")
    else
        out("OK " . len(b))
WEOF
"$WORD" build "$tmp/probe.w" -o "$tmp/probe" >"$tmp/buildlog" 2>&1 || {
  echo "FAIL: could not build the probe:"; sed 's/^/  /' "$tmp/buildlog"; exit 1; }

grep -v '^#' "$LIST" | grep -v '^[[:space:]]*$' | head -n "$N" > "$tmp/hosts"
got=$(tr -d ' ' < "$tmp/hosts" | grep -c .)
[ "$got" = "$N" ] || { echo "FAIL: the list has $got usable domains, not $N"; exit 1; }

echo "top $N domains over https, $JOBS at a time:"

# One host: its answer and its stderr, in two files named for it. `timeout`
# rather than word's own deadlines, because 120 s of one stalled host is not
# worth spending while the rest of the list waits.
probe_one() {
  h=$1
  timeout 30 "$tmp/probe" "https://$h/" >"$res/$h.out" 2>"$res/$h.err" \
    || echo TIMEOUT > "$res/$h.out"
}

n=0
while read -r h; do
  probe_one "$h" &
  n=$((n + 1))
  if [ $((n % JOBS)) -eq 0 ]; then wait; fi
done < "$tmp/hosts"
wait

# ---- classification ---------------------------------------------------------
# Only failures reach openssl, and each costs at most four handshakes: word's
# parameters, then unrestricted 1.3, then each restriction alone to name which
# one was the obstacle, then any version at all.
ssl_ok() { # ssl_ok <host> <extra s_client args...>
  h=$1; shift
  timeout 20 openssl s_client -connect "$h:443" -servername "$h" -brief "$@" \
    </dev/null >/dev/null 2>&1
}

classify() { # classify <host> -> prints one bucket name
  h=$1
  if grep -q 'certificate not trusted' "$res/$h.err" 2>/dev/null; then
    # word's one message covers both halves of authentication (an untrusted
    # chain, and a name the chain doesn't cover), so openssl splits them.
    # -verify_return_error makes openssl fail the connection on a verification
    # error instead of reporting it and carrying on.
    if [ "$have_ssl" = 0 ]; then echo cert; return 0; fi
    if ssl_ok "$h" -verify_hostname "$h" -verify_return_error; then
      echo cert
    else
      echo name
    fi
    return 0
  fi
  if grep -q 'closed the connection without a handshake' "$res/$h.err" 2>/dev/null; then
    echo declined; return 0
  fi
  if [ "$(cat "$res/$h.out" 2>/dev/null)" = TIMEOUT ] \
     || grep -q 'did not finish inside the deadline' "$res/$h.err" 2>/dev/null; then
    echo slow; return 0
  fi
  if grep -q 'closed without answering the request' "$res/$h.err" 2>/dev/null; then
    # The same shape as `declined`, one layer up: justdial.com hands a request
    # with no User-Agent to Akamai, which drops it rather than refusing it, and
    # answers a curl-shaped one with 403. Not a protocol failure either.
    echo no_answer; return 0
  fi
  if [ "$have_ssl" = 0 ]; then echo unexplained; return 0; fi
  if ssl_ok "$h" -tls1_3 -ciphersuites "$W_SUITES" -groups "$W_GROUPS"; then
    # openssl got there with word's own offer, so nothing about the web explains
    # this one. `word` is a gated bucket, though, and one bad minute shouldn't
    # fail the run, so ask word once more first.
    probe_one "$h"
    case "$(cat "$res/$h.out" 2>/dev/null)" in
      "OK "*) echo flaky; return 0 ;;
    esac
    echo word; return 0
  fi
  if ssl_ok "$h" -tls1_3; then
    if ! ssl_ok "$h" -tls1_3 -groups "$W_GROUPS"; then echo group; return 0; fi
    if ! ssl_ok "$h" -tls1_3 -ciphersuites "$W_SUITES"; then echo cipher; return 0; fi
    echo tls13_other; return 0
  fi
  if ssl_ok "$h"; then echo tls12; return 0; fi
  echo unreachable
}

# Classify in parallel too, with each host's bucket in its own file, because a
# subshell can't hand a variable back to its parent. One at a time, this was by
# far the slower half: a thousand domains leave a hundred-odd failures, and up
# to four openssl handshakes each, one after another, cost more than the
# thousand fetches.
n=0
while read -r h; do
  a=$(cat "$res/$h.out" 2>/dev/null || true)
  case "$a" in
    "OK "*) continue ;;
  esac
  ( classify "$h" > "$res/$h.cls" ) &
  n=$((n + 1))
  if [ $((n % JOBS)) -eq 0 ]; then wait; fi
done < "$tmp/hosts"
wait

okc=0; bytes=0
cert=""; namebad=""; wordbug=""; declined=""; noans=""; flaky=""; cipher=""; group=""; tls13o=""; tls12=""; slow=""; unreach=""; unexp=""
while read -r h; do
  a=$(cat "$res/$h.out" 2>/dev/null || true)
  case "$a" in
    "OK "*)
      okc=$((okc + 1)); bytes=$((bytes + ${a#OK }))
      continue ;;
  esac
  case "$(cat "$res/$h.cls" 2>/dev/null)" in
    cert)        cert="$cert $h" ;;
    name)        namebad="$namebad $h" ;;
    word)        wordbug="$wordbug $h" ;;
    cipher)      cipher="$cipher $h" ;;
    group)       group="$group $h" ;;
    tls13_other) tls13o="$tls13o $h" ;;
    tls12)       tls12="$tls12 $h" ;;
    declined)    declined="$declined $h" ;;
    no_answer)   noans="$noans $h" ;;
    flaky)       flaky="$flaky $h" ;;
    slow)        slow="$slow $h" ;;
    unreachable) unreach="$unreach $h" ;;
    *)           unexp="$unexp $h" ;;
  esac
done < "$tmp/hosts"

count() { set -- $1; echo $#; }

# One line per bucket that has anything in it, naming the first few hosts: the
# label says what to do about it and the names make it checkable by hand.
report() { # report <label> <hosts>
  lab=$1
  c=$(count "$2")
  if [ "$c" = 0 ]; then return 0; fi
  set -- $2
  named=$1
  if [ $# -gt 1 ]; then named="$named $2"; fi
  if [ $# -gt 2 ]; then named="$named $3"; fi
  if [ $# -gt 3 ]; then named="$named ..."; fi
  printf '  %-12s %4d  %s\n' "$lab" "$c" "$named"
}

# verdict <TESTED|NETWORK-UNAVAILABLE|FAILED> <detail>: the line a run ends on.
# The if-blocks instead of `&&` are there because this suite runs under set -e.
verdict() {
  echo "test_top_sites: $1 -- $2"
  if [ -n "$GITHUB_ACTIONS" ]; then
    case $1 in
      NETWORK-UNAVAILABLE) echo "::warning title=test_top_sites::NETWORK-UNAVAILABLE -- $2" ;;
      FAILED) echo "::error title=test_top_sites::FAILED -- $2" ;;
    esac
    if [ -n "$GITHUB_STEP_SUMMARY" ]; then
      echo "- \`test_top_sites\`, top $N: **$1** -- $2" >> "$GITHUB_STEP_SUMMARY"
    fi
  fi
  return 0
}

okc=$((okc + $(count "$flaky")))
printf '  %-12s %4d  %d bytes of body\n' ok "$okc" "$bytes"
report cert        "$cert"
report name        "$namebad"
report word        "$wordbug"
report cipher      "$cipher"
report group       "$group"
report tls13_other "$tls13o"
report tls12       "$tls12"
report declined    "$declined"
report no_answer   "$noans"
report flaky       "$flaky"
report slow        "$slow"
report unreachable "$unreach"
report unexplained "$unexp"

fail=0
nc=$(count "$cert"); nw=$(count "$wordbug"); nu=$(count "$unreach")

# A broken network isn't a regression in word. A quarter of the list answering
# no TLS at all is a broken network; one host's outage isn't.
if [ "$nu" -gt $((N / 4)) ]; then
  verdict NETWORK-UNAVAILABLE "$nu of $N answered no TLS at all: the network, not the client"
  if [ "${TOP_SITES_REQUIRE_NETWORK:-0}" = 1 ]; then exit 1; fi
  exit 0
fi

# Four gates that don't consult the baseline (cert, word, unexplained and
# tls13_other), because none of them has anything to do with the web changing.
# Every host on the list is either fetched or explained: by a design decision
# (tls12), by a certificate that really is for another name (name), by a
# parameter the web moved to (cipher, group), or by the peer or the network
# (declined, no_answer, slow, unreachable). A host that's neither fetched nor
# explained is a defect, and there must be none, whatever the totals say.
if [ "$nc" -gt 0 ]; then
  if [ "$same_store" = 1 ]; then
    echo "  FAIL: $nc popular hosts are 'certificate not trusted' where openssl accepts"
    echo "        the same chain under the same name, out of the same trust store. The"
    echo "        store or the X.509 profile refuses what the rest of the web accepts:$cert"
    fail=1
  else
    echo "  note: $nc chains anchor in openssl's own bundle and not in this platform's"
    echo "        store, which is a difference between the two stores rather than a"
    echo "        verdict about the chain:$cert"
  fi
fi
if [ "$nw" -gt 0 ]; then
  echo "  FAIL: $nw hosts where openssl completes a TLS 1.3 handshake with word's OWN"
  echo "        cipher suites and groups and word does not:$wordbug"
  fail=1
fi
nx=$(count "$unexp"); no=$(count "$tls13o")
if [ "$nx" -gt 0 ]; then
  echo "  FAIL: $nx hosts failed for a reason nothing here could name:$unexp"
  fail=1
fi
if [ "$no" -gt 0 ]; then
  echo "  FAIL: $no hosts refuse word's suites and groups for some further reason: a"
  echo "        signature algorithm, most likely. Name it before this passes:$tls13o"
  fail=1
fi

reach=$okc
if [ "$same_store" = 0 ]; then reach=$((okc + nc)); fi
if [ "$BASE" = 0 ]; then
  echo "test_top_sites: $okc of $N reached (no baseline for N=$N; cert and word gated at 0)"
else
  floor=$((BASE - TOL))
  if [ "$reach" -lt "$floor" ]; then
    echo "  FAIL: $reach of $N within reach, below the floor of $floor (baseline $BASE,"
    echo "        tolerance $TOL). Read the buckets above: cipher or group means the web"
    echo "        moved on and word should offer more; cert or word means this broke."
    fail=1
  elif [ "$reach" -gt "$BASE" ]; then
    echo "  note: $reach of $N within reach, ABOVE the baseline of $BASE; raise BASE."
  fi
  if [ "$reach" = "$okc" ]; then
    echo "test_top_sites: $okc of $N reached (baseline $BASE, floor $floor)"
  else
    echo "test_top_sites: $okc of $N reached, $reach within reach of the client itself"
    echo "                (baseline $BASE, floor $floor; the difference is $nc chains this"
    echo "                platform's store has no anchor for)"
  fi
fi

# The line that makes the count readable: what is fetched, plus what is accounted
# for by something other than a defect here. okc already counts the flaky hosts,
# which were fetched on the second try.
explained=$((okc + $(count "$namebad") + $(count "$cipher") + $(count "$group") \
             + $(count "$tls12") + $(count "$declined") + $(count "$noans") \
             + $(count "$slow") + nu))
if [ "$same_store" = 0 ]; then explained=$((explained + nc)); fi
echo "                $explained of $N fetched or explained, $((N - explained)) not"
if [ "$fail" = 0 ]; then
  verdict TESTED "$okc of $N reached, $explained fetched or explained"
else
  verdict FAILED "see the FAIL lines above"
  exit 1
fi
