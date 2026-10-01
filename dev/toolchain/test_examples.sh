#!/bin/sh
# test_examples.sh: every program in examples/ except https, which needs the
# network (test_net.sh runs it). Two kinds live there: programs that show a
# feature (checked on their first line of output, or driven end to end when
# they're interactive), and programs written to be used (checked against a
# fixture, and against the GNU tool of the same name where there is one). Each
# example is built with one `word build` (compile, assemble and link), and the
# executable is run.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
# word.exe is a native Windows binary when this runs on Windows, and cannot open
# an MSYS path. One conversion here keeps every line below it working on both.
. "$here/hostpath.sh"; here=$(hostpath "$here"); root=$(hostpath "$root")
WORD=$(wordbin "${WORD:-$root/word}"); tmp=$(hostpath "$(mktemp -d)"); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

# example : arg : expected first line of output
check() {
  ex="$1"; arg="$2"; want="$3"
  if ! "$WORD" build "$root/examples/$ex.w" -o "$tmp/p" >/dev/null 2>&1; then
    echo "  FAIL $ex (build error)"; fail=$((fail+1)); return
  fi
  got=$("$tmp/p" "$arg" 2>&1 | head -1)
  if [ "$got" = "$want" ]; then echo "  OK   $ex -> $got"; pass=$((pass+1))
  else echo "  FAIL $ex -> got '$got' want '$want'"; fail=$((fail+1)); fi
}

check hello/hello       Ada "Hello, word!"
check fib/fib           Ada "0 1 1 2 3 5 8 13 21 34 "
check fizzbuzz/fizzbuzz Ada "1"
check arrays/arrays     Ada "squares: 0 1 4 9 16 "
check contracts/contracts Ada "5"
check greet/greet       Ada "Hello, Ada!"

# The RPG example is interactive, so a first-line check can't show the game
# runs. This builds it, drives two fixed playthroughs (a Warrior win and a naive
# loss) and checks the final line. That covers class selection, turn-based
# combat, potions, focus, and the deal/mend contracts end to end.
rpg="$root/examples/rpg/rpg.w"
if "$WORD" build "$rpg" -o "$tmp/rpg" >/dev/null 2>&1; then
  full=$(printf '1\n1\n1\n1\n1\n1\n1\n1\n3\n3\n4\n3\n' | "$tmp/rpg" Aria "$tmp/journal.json" 2>&1)
  win=$(echo "$full" | tail -1)
  if [ "$win" = "VICTORY" ]; then echo "  OK   rpg/rpg (Warrior playthrough -> VICTORY)"; pass=$((pass+1))
  else echo "  FAIL rpg/rpg win -> got '$win'"; fail=$((fail+1)); fi
  lose=$(printf '1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n1\n' | "$tmp/rpg" Grum "$tmp/journal2.json" 2>&1 | tail -1)
  if [ "$lose" = "DEFEAT" ]; then echo "  OK   rpg/rpg (naive playthrough -> DEFEAT)"; pass=$((pass+1))
  else echo "  FAIL rpg/rpg lose -> got '$lose'"; fail=$((fail+1)); fi
  # The example is also the language tour, so the parts that show a feature
  # are checked too: the haul is a map read back through sort(keys(...)), and
  # the journal is a map written as JSON, read from disk and parsed again in
  # the same run.
  if echo "$full" | grep -q "^Haul: Black Arrow x1  Bone Charm x1  Grave Salt x1  Lich Sigil x1$"; then
    echo "  OK   rpg/rpg (loot map, sorted keys)"; pass=$((pass+1))
  else echo "  FAIL rpg/rpg loot -> $(echo "$full" | grep -c Haul) haul lines"; fail=$((fail+1)); fi
  if echo "$full" | grep -q "^Journal written and read back: Aria the Warrior, 6 fields.$" \
     && grep -q '"hero":"Aria"' "$tmp/journal.json" \
     && grep -q '"loot":{"Bone Charm":1' "$tmp/journal.json"; then
    echo "  OK   rpg/rpg (journal: map -> JSON -> fs -> parse)"; pass=$((pass+1))
  else echo "  FAIL rpg/rpg journal -> $(head -c 120 "$tmp/journal.json" 2>&1)"; fail=$((fail+1)); fi
  # The moves have to be on screen before the game waits for one. ended() is a
  # blocking lookahead (SPEC 9.2), so calling it above the menu left the player
  # at a bare cursor. A scripted playthrough can't see that, so this sends one
  # line of input and checks the menu was already printed.
  prompt=$(printf '1\n' | "$tmp/rpg" Solo "$tmp/journal3.json" 2>&1)
  if echo "$prompt" | grep -q "^1 attack   2 defend   3 Shield Bash   4 potion$"; then
    echo "  OK   rpg/rpg (the moves are printed before input is read)"; pass=$((pass+1))
  else echo "  FAIL rpg/rpg prompt order -> the move list never printed"; fail=$((fail+1)); fi
else
  echo "  FAIL rpg/rpg (build error)"; fail=$((fail+1))
fi

# The calculator (RECKON) is interactive too. This drives a session through
# its tokenizer, recursive-descent parser and evaluator and checks the printed
# results: precedence, parentheses, division, a variable, and a bad line that
# reports an error without ending the loop.
#
# `17 / 5` is 3.4 because `/` is exact (SPEC 3.3). It also checks that a float
# reaches out() correctly rounded: it printed 3.39999999999999 when ftoa
# truncated its last digit.
calc="$root/examples/calc/calc.w"
if "$WORD" build "$calc" -o "$tmp/calc" >/dev/null 2>&1; then
  got=$(printf '2 + 3 * 4\n(2 + 3) * 4\n17 / 5\nx = 6\nx * 7\n1 / 0\nquit\n' | "$tmp/calc" 2>&1)
  if echo "$got" | grep -qx "  14" && echo "$got" | grep -qx "  20" \
     && echo "$got" | grep -qx "  3.4" && echo "$got" | grep -qx "  x = 6" \
     && echo "$got" | grep -qx "  42" && echo "$got" | grep -q "division by zero"; then
    echo "  OK   calc/calc (tokenize + parse + evaluate a session)"; pass=$((pass+1))
  else
    echo "  FAIL calc/calc session -> got: $(echo "$got" | tr '\n' '|')"; fail=$((fail+1))
  fi
else
  echo "  FAIL calc/calc (build error)"; fail=$((fail+1))
fi

# KEEP is a file-backed key/value store, so the test is persistence: one run
# writes the file, and a second process loads it and reads the values back.
# That covers the fs read/write round trip and the key=value format.
store="$root/examples/store/store.w"; sdb="$tmp/keep.db"
if "$WORD" build "$store" -o "$tmp/store" >/dev/null 2>&1; then
  printf 'set name Ada\nset lang word\nsave\nquit\n' | "$tmp/store" "$sdb" >/dev/null 2>&1
  got=$(printf 'get name\nget lang\nquit\n' | "$tmp/store" "$sdb" 2>&1)
  if echo "$got" | grep -q "Loaded 2 entries" && echo "$got" | grep -q "name = Ada" \
     && echo "$got" | grep -q "lang = word"; then
    echo "  OK   store/store (persists across runs via fs)"; pass=$((pass+1))
  else
    echo "  FAIL store/store persistence -> got: $(echo "$got" | tr '\n' '|')"; fail=$((fail+1))
  fi
else
  echo "  FAIL store/store (build error)"; fail=$((fail+1))
fi

# LIFE is Conway's Game of Life. It animates in place by default, so these
# checks pass --plain for the scrolling text form. The invariants: a glider
# always has 5 live cells, a block is a still life of 4, and the pulsar returns
# to its start after 3 generations (period 3). Together they cover the grid,
# the neighbour count and the step.
life="$root/examples/life/life.w"
if "$WORD" build "$life" -o "$tmp/life" >/dev/null 2>&1; then
  gl=$("$tmp/life" glider 3 --plain 2>&1 | grep -c "population 5" || true)
  bl=$("$tmp/life" block 2 --plain 2>&1 | grep -c "population 4" || true)
  "$tmp/life" pulsar 3 --plain 2>&1 > "$tmp/pu.txt"
  awk '/generation 0/{f=1} /generation 1/{f=0} f&&/^\|/{print}' "$tmp/pu.txt" > "$tmp/p0"
  awk '/generation 3/{f=1} f&&/^\|/{print}' "$tmp/pu.txt" > "$tmp/p3"
  if [ "$gl" = 4 ] && [ "$bl" = 3 ] && cmp -s "$tmp/p0" "$tmp/p3"; then
    echo "  OK   life/life (glider pop 5, block still, pulsar period 3)"; pass=$((pass+1))
  else
    echo "  FAIL life/life -> glider5x4=$gl block4x3=$bl pulsarP3=$(cmp -s "$tmp/p0" "$tmp/p3" && echo ok || echo no)"; fail=$((fail+1))
  fi
else
  echo "  FAIL life/life (build error)"; fail=$((fail+1))
fi

# SQRT shows floating point: Newton's method converging on square roots. It's
# deterministic, so this checks a couple of known results and its self-check.
sq="$root/examples/sqrt/sqrt.w"
if "$WORD" build "$sq" -o "$tmp/sqrt" >/dev/null 2>&1; then
  got=$("$tmp/sqrt" 2>&1)
  if echo "$got" | grep -q -- "-> 1.41421356237309" && echo "$got" | grep -q -- "-> 3.0" \
     && echo "$got" | grep -q "checks out"; then
    echo "  OK   sqrt/sqrt (Newton's method in floating point)"; pass=$((pass+1))
  else echo "  FAIL sqrt/sqrt -> got: $(echo "$got" | tr '\n' '|')"; fail=$((fail+1)); fi
else
  echo "  FAIL sqrt/sqrt (build error)"; fail=$((fail+1))
fi

# INVENTORY is the {} and JSON example: records as brace literals, array()
# arrays, keys/has/len to walk them, and a parse(stringify(...)) round trip
# that compares equal. It's deterministic, so this checks the JSON text and
# the round-trip result.
inv="$root/examples/inventory/inventory.w"
if "$WORD" build "$inv" -o "$tmp/inventory" >/dev/null 2>&1; then
  got=$("$tmp/inventory" 2>&1)
  wire='{"shop":"Ada'"'"'s Parts","items":[{"name":"gear","price":12,"tags":["brass","small"],"in-stock":true},{"name":"spring","price":3,"tags":["steel","small"],"in-stock":true},{"name":"crank","price":40,"tags":["iron","large"],"in-stock":true}]}'
  if echo "$got" | grep -qF "$wire" \
     && echo "$got" | grep -q "total value: 55" \
     && echo "$got" | grep -q "round trip equal: true" \
     && echo "$got" | grep -q "has 'colour': false" \
     && echo "$got" | grep -q "broken payload rejected"; then
    echo "  OK   inventory/inventory (maps, JSON round trip, absent keys)"; pass=$((pass+1))
  else echo "  FAIL inventory/inventory -> got: $(echo "$got" | tr '\n' '|')"; fail=$((fail+1)); fi
else
  echo "  FAIL inventory/inventory (build error)"; fail=$((fail+1))
fi

# --- the tool-shaped examples ------------------------------------------------
#
# wc, find, hexdump, jsonq and fetch were written to be used, so they're tested
# like tools: against a fixture with a known answer, and against the standard
# tool's output where it's installed. examples/README.md lists where they
# differ from the real tools.
ok()   { pass=$((pass+1)); echo "  OK   $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1 -- $2"; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }

# `word run` builds a temporary binary under $TMPDIR. Pointing it at ours means
# those get cleaned up with everything else this script made.
export TMPDIR="$tmp"
cd "$root"


# A fixture with multi-byte UTF-8 in it, where these tools are most likely to
# go wrong.
printf 'alpha beta gamma\ncaf\303\251 \342\200\224 dash\nbeta again\n' > "$tmp/f.txt"

echo "== wc =="
got=$("$WORD" run examples/wc/wc.w "$tmp/f.txt" | tr -s ' ')
want=" 3 8 43 $tmp/f.txt"
same "counts lines, words and bytes" "$got" "$want"
if command -v wc >/dev/null 2>&1; then
  # GNU wc in a UTF-8 locale is the reference. The locale changes how it splits
  # words on multi-byte input.
  ref=$(LC_ALL=C.UTF-8 wc "$tmp/f.txt" 2>/dev/null | tr -s ' ' | cut -d' ' -f2-4)
  mine=$("$WORD" run examples/wc/wc.w "$tmp/f.txt" | tr -s ' ' | cut -d' ' -f2-4)
  same "agrees with GNU wc" "$mine" "$ref"
fi

echo "== find =="
got=$("$WORD" run examples/find/find.w beta "$tmp/f.txt")
same "prints matching lines with numbers" "$got" "1:alpha beta gamma
3:beta again"
got=$("$WORD" run examples/find/find.w -c beta "$tmp/f.txt")
same "-c counts" "$got" "2"
got=$("$WORD" run examples/find/find.w -i -c BETA "$tmp/f.txt")
same "-i ignores case" "$got" "2"
# The line with multi-byte UTF-8 has to come back as itself: a slice of a file
# must print as its own bytes.
got=$("$WORD" run examples/find/find.w dash "$tmp/f.txt")
same "a matched line keeps its UTF-8" "$got" "2:café — dash"

echo "== hexdump =="
printf 'Hi\000\377' > "$tmp/b.bin"
got=$("$WORD" run examples/hexdump/hexdump.w "$tmp/b.bin")
same "hex, offsets and the printable column" "$got" "00000000  48 69 00 ff                                       |Hi..|
00000004"
if command -v hexdump >/dev/null 2>&1; then
  head -c 64 /dev/urandom > "$tmp/r.bin"
  a=$("$WORD" run examples/hexdump/hexdump.w "$tmp/r.bin" | head -4 | cut -c11-58)
  b=$(hexdump -C "$tmp/r.bin" | head -4 | cut -c11-58)
  same "agrees with hexdump -C" "$a" "$b"
fi

echo "== jsonq =="
printf '{"user":{"name":"Aria","roles":["dev","ops"]},"items":[{"id":1},{"id":7}],"n":42}' > "$tmp/d.json"
same "a nested field" "$("$WORD" run examples/jsonq/jsonq.w "$tmp/d.json" user.name)" "Aria"
same "an array element by index" "$("$WORD" run examples/jsonq/jsonq.w "$tmp/d.json" items.1.id)" "7"
same "an array renders as JSON" "$("$WORD" run examples/jsonq/jsonq.w "$tmp/d.json" user.roles)" '["dev","ops"]'
same "-keys lists the keys of an object" "$("$WORD" run examples/jsonq/jsonq.w "$tmp/d.json" -keys user)" "name
roles"
same "a missing path is 0, not a fault" "$("$WORD" run examples/jsonq/jsonq.w "$tmp/d.json" user.nope.deeper)" "0"

echo "== fetch =="
# Built but not run, since the network isn't this suite's job. The tool has to
# compile, and its size is worth watching.
#
# The net library is word, bundled into the program's own source and compiled
# with it, so an HTTPS client carries its whole TLS stack and comes to about
# 450 KB. The bound sits just above that to catch runaway growth.
if "$WORD" build examples/fetch/fetch.w -o "$tmp/fetch" >/dev/null 2>&1; then
  sz=$(wc -c < "$tmp/fetch" | tr -d ' ')
  if [ "$sz" -lt 470000 ]; then ok "a TLS 1.3 HTTP client builds, and is ${sz} bytes"
  else bad "fetch size" "${sz} bytes, expected under 470 KB"; fi
else bad "fetch builds" "build failed"; fi

echo "examples: $pass passed, $fail failed"
[ "$fail" = 0 ]
