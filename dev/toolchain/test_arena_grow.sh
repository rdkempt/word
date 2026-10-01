#!/bin/sh
# test_arena_grow.sh: the arena grows on demand, so one allocation bigger than
# the old fixed 256 MiB arena works. text(39000000) is about 312 MB (8 bytes an
# element), and the fixed arena ran out well before that.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

cat > "$tmp/grow.w" <<'EOF'
a = text(39000000)
a[0] = 7
a[38999999] = 123
out(a[0] . " " . a[38999999] . " " . len(a))
EOF
"$WORD" build "$tmp/grow.w" -o "$tmp/grow" >/dev/null 2>&1
got=$("$tmp/grow" 2>&1)

if [ "$got" = "7 123 39000000" ]; then
  echo "test_arena_grow: PASS (allocated + used a ~312 MB region, past the original 256 MB cap)"
  exit 0
else
  echo "test_arena_grow: FAIL (got '$got', want '7 123 39000000')"
  exit 1
fi
