#!/bin/sh
# test_folder.sh: a folder is the program (SPEC 11). Building app.w compiles
# every .w file beside it as one program, in any order, on x86-64 and (under
# qemu) arm64. It also checks that a diagnostic points at the right file (the
# line map) and so does a run-time fault, that a duplicate definition across
# files is an error naming both places, that the other files hold definitions
# only, and that building a file other than app.w pulls in nothing else.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# A three-file program: app.w uses functions defined in two siblings.
mkdir -p "$tmp/prog"
printf 'out(hi() . " " . bye())\nreturn 0\n' > "$tmp/prog/app.w"
printf 'hi()\n    return "hello"\n'          > "$tmp/prog/greet.w"
printf 'bye()\n    return "goodbye"\n'        > "$tmp/prog/part.w"

run_prog() {
  tgt="$1"; qemu="$2"; label="$3"
  if ! "$WORD" build $tgt "$tmp/prog/app.w" -o "$tmp/prog/app.$label" >"$tmp/err" 2>&1; then
    echo "  FAIL: $label build of the folder program"; sed 's/^/    /' "$tmp/err"; fail=1; return
  fi
  got=$($qemu "$tmp/prog/app.$label" 2>&1 || true)
  if [ "$got" = "hello goodbye" ]; then
    echo "  $label: folder program prints 'hello goodbye': ok"
  else
    echo "  FAIL: $label folder program printed [$got]"; fail=1
  fi
}

run_prog "" "" "x86"
QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
[ -n "$QEMU" ] && run_prog "-arm64" "$QEMU" "arm64"

# A diagnostic inside a sibling names that sibling, not app.w (the line map).
mkdir -p "$tmp/diag"
printf 'out(g())\nreturn 0\n'                 > "$tmp/diag/app.w"
printf 'g()\n    return no_such_fn()\n'        > "$tmp/diag/helper.w"
msg=$("$WORD" build "$tmp/diag/app.w" -o "$tmp/diag/x" 2>&1 || true)
case "$msg" in
  *helper.w:2:*"no_such_fn"*) echo "  a diagnostic names the sibling file and line: ok" ;;
  *) echo "  FAIL: cross-file diagnostic was [$msg]"; fail=1 ;;
esac

# A byte order mark at the top of a sibling gets the message one at the top of
# app.w does, located in the sibling (SPEC 2.1). It used to be skipped.
mkdir -p "$tmp/bom"
printf 'out(f(1))\n'                          > "$tmp/bom/app.w"
printf '\357\273\277f(a)\n    return a\n'     > "$tmp/bom/lib.w"
msg=$("$WORD" build "$tmp/bom/app.w" -o "$tmp/bom/x" 2>&1 || true)
case "$msg" in
  *lib.w:1:1:*"byte order mark"*) echo "  a byte order mark in a sibling is an error located there: ok" ;;
  *) echo "  FAIL: a sibling with a byte order mark gave [$msg]"; fail=1 ;;
esac

# A run-time fault names the file its statement is in, with that file's own line
# (SPEC 10.2). The files are compiled as one text, app.w first, and a fault used
# to print that text's line under app.w's name: `app.w:6` for line 3 of a
# sibling, a line past the end of a three-line app.w. Each case runs on both
# targets and has to print exactly its one line.
fault_case() { # fault_case <dir> <want> ; the files are already in $tmp/<dir>
  for tgt in x86 arm64; do
    flag=; runner=
    if [ "$tgt" = arm64 ]; then
      [ -n "$QEMU" ] || continue
      flag=-arm64; runner=$QEMU
    fi
    if ! "$WORD" build $flag "$tmp/$1/app.w" -o "$tmp/$1/app.$tgt" >"$tmp/err" 2>&1; then
      echo "  FAIL: $tgt build of $1"; sed 's/^/    /' "$tmp/err"; fail=1; continue
    fi
    rc=0; got=$($runner "$tmp/$1/app.$tgt" 2>&1 >/dev/null) || rc=$?
    if [ "$rc/$got" = "70/$2" ]; then echo "  $tgt: a fault names its file: $2: ok"
    else echo "  FAIL: $tgt $1 exit $rc [$got], want exit 70 [$2]"; fail=1; fi
  done
}
# The faulting functions below take two statements on purpose: a body that's
# one `return <expression>` is substituted into its caller (SPEC 14), and a
# fault inside it then names the caller's line, in app.w, not the sibling's.
mkdir -p "$tmp/fsib"
printf 'out(a() . b(0))\n'            > "$tmp/fsib/app.w"
printf 'a()\n    return "a"\n'          > "$tmp/fsib/a.w"
printf '// b\nb(n)\n    d = 7 / n\n    return d\n' > "$tmp/fsib/b.w"
fault_case fsib 'b.w:3: divide by zero'
mkdir -p "$tmp/fentry"
printf 'x = 1\nout(x)\ny = array(2)\nout(y[5])\nout(h())\n' > "$tmp/fentry/app.w"
printf 'h()\n    return 1\n'                                > "$tmp/fentry/h.w"
fault_case fentry 'app.w:4: index 5 out of bounds for a region of length 2'
# The net library is compiled in after the last file, and a fault inside it
# names the statement that called the verb, here one in a sibling.
mkdir -p "$tmp/fnet"
printf 'out(fetchit())\n' > "$tmp/fnet/app.w"
printf 'fetchit()\n    u = array(8)\n    u[0] = "h"\n    r = get(u)\n    return r\n' > "$tmp/fnet/w.w"
fault_case fnet 'w.w:4: cannot order-compare a number and text'
# A file's name goes into the binary as a string, and a name can hold a quote.
mkdir -p "$tmp/fquote"
printf 'out(q(0))\n' > "$tmp/fquote/app.w"
if printf 'q(n)\n    d = 1 / n\n    return d\n' > "$tmp/fquote/we\"ird.w" 2>/dev/null; then
  fault_case fquote 'we"ird.w:2: divide by zero'
fi
# And a name past ASCII goes in as its UTF-8, counted in bytes: written as code
# points it came out as Latin-1, a byte short for every accent.
mkdir -p "$tmp/futf"
printf 'out(u(0))\n' > "$tmp/futf/app.w"
if printf 'u(n)\n    d = 1 / n\n    return d\n' > "$tmp/futf/ünï.w" 2>/dev/null; then
  fault_case futf 'ünï.w:2: divide by zero'
fi
# The entry file's own name goes in the same way, in a one-file program too.
mkdir -p "$tmp/fone"
if printf 'x = 0\nout(1 / x)\n' > "$tmp/fone/naïve.w" 2>/dev/null; then
  for tgt in x86 arm64; do
    flag=; runner=
    if [ "$tgt" = arm64 ]; then
      [ -n "$QEMU" ] || continue
      flag=-arm64; runner=$QEMU
    fi
    if ! "$WORD" build $flag "$tmp/fone/naïve.w" -o "$tmp/fone/p.$tgt" >"$tmp/err" 2>&1; then
      echo "  FAIL: $tgt build of naïve.w"; sed 's/^/    /' "$tmp/err"; fail=1; continue
    fi
    rc=0; got=$($runner "$tmp/fone/p.$tgt" 2>&1 >/dev/null) || rc=$?
    if [ "$rc/$got" = "70/naïve.w:2: divide by zero" ]; then echo "  $tgt: a fault names a non-ASCII file: ok"
    else echo "  FAIL: $tgt naïve.w exit $rc [$got]"; fail=1; fi
  done
fi

# A duplicate definition across two files is a hard error naming both places
# (SPEC 11). It used to name only the second.
mkdir -p "$tmp/dup"
printf 'out(f())\nreturn 0\n'  > "$tmp/dup/app.w"
printf 'f()\n    return 1\n'    > "$tmp/dup/a.w"
printf 'f()\n    return 2\n'    > "$tmp/dup/b.w"
msg=$("$WORD" build "$tmp/dup/app.w" -o "$tmp/dup/x" 2>&1 || true)
case "$msg" in
  *"b.w:1:1: 'f' is already defined at "*"a.w:1:1, and there are no namespaces, so rename one of them"*)
    echo "  a duplicate definition across files names both places: ok" ;;
  *) echo "  FAIL: duplicate-definition error was [$msg]"; fail=1 ;;
esac

# Building a file other than app.w, in a directory of other .w files, pulls in
# nothing else: main.w must not see lib.w's definition.
mkdir -p "$tmp/single"
printf 'out(only())\nreturn 0\n'   > "$tmp/single/main.w"
printf 'only()\n    return 1\n'      > "$tmp/single/lib.w"
msg=$("$WORD" build "$tmp/single/main.w" -o "$tmp/single/x" 2>&1 || true)
case "$msg" in
  *"undefined function 'only'"*) echo "  a non-app.w build stays single-file: ok" ;;
  *) echo "  FAIL: non-app.w build unexpectedly folded [$msg]"; fail=1 ;;
esac

# Only app.w runs statements (SPEC 8.1). The other files are appended to it, so
# a statement in one used to run after app.w's own, without a word.
mkdir -p "$tmp/stray"
printf 'out(f(1))\n'                      > "$tmp/stray/app.w"
printf 'f(a)\n    return a + 1\nout(99)\n' > "$tmp/stray/lib.w"
msg=$("$WORD" build "$tmp/stray/app.w" -o "$tmp/stray/x" 2>&1 || true)
case "$msg" in
  *lib.w:3:1:*"only app.w may hold top-level statements"*) echo "  a top-level statement in another file is an error: ok" ;;
  *) echo "  FAIL: a statement in a sibling gave [$msg]"; fail=1 ;;
esac

# Imports are app.w's too (SPEC 11.1). The parser takes imports from the opening
# lines of the combined source, so when app.w held nothing but imports, a
# sibling's import was taken with them.
mkdir -p "$tmp/simp"
printf 'import fs\nout(f())\n'                  > "$tmp/simp/app.w"
printf 'import json\nf()\n    return 1\n'       > "$tmp/simp/b.w"
msg=$("$WORD" build "$tmp/simp/app.w" -o "$tmp/simp/x" 2>&1 || true)
case "$msg" in
  *b.w:1:1:*"an import goes at the top of app.w"*) echo "  an import in another file is an error: ok" ;;
  *) echo "  FAIL: an import in a sibling (after app.w's code) gave [$msg]"; fail=1 ;;
esac
printf 'import fs\n'                            > "$tmp/simp/app.w"
printf 'import json\nout(1)\n'                  > "$tmp/simp/b.w"
msg=$("$WORD" build "$tmp/simp/app.w" -o "$tmp/simp/x" 2>&1 || true)
case "$msg" in
  *b.w:1:1:*"an import goes at the top of app.w"*) echo "  an import in another file is an error when app.w holds only imports: ok" ;;
  *) echo "  FAIL: an import in a sibling (app.w all imports) gave [$msg]"; fail=1 ;;
esac

# Built from inside the folder, a sibling is named the way app.w is, with no
# "./" in front of it (SPEC 11 shows `helper.w:3:9`).
msg=$(cd "$tmp/diag" && "$WORD" build app.w -o x 2>&1 || true)
case "$msg" in
  "helper.w:2:"*"no_such_fn"*) echo "  built in the folder, a diagnostic names the sibling bare: ok" ;;
  *) echo "  FAIL: in-folder cross-file diagnostic was [$msg]"; fail=1 ;;
esac

# The directory is flat (SPEC 11), so a subdirectory whose name ends in .w is
# not a source file. On Windows reading one failed the build as "cannot read
# app.w", and on Linux it read as an empty file.
mkdir -p "$tmp/subw/lib.w"
printf 'out(7)\n' > "$tmp/subw/app.w"
for tgt in x86 arm64; do
  flag=; runner=
  if [ "$tgt" = arm64 ]; then
    [ -n "$QEMU" ] || continue
    flag=-arm64; runner=$QEMU
  fi
  if "$WORD" build $flag "$tmp/subw/app.w" -o "$tmp/subw/p.$tgt" >"$tmp/err" 2>&1; then
    got=$($runner "$tmp/subw/p.$tgt" 2>&1 || true)
    if [ "$got" = 7 ]; then echo "  $tgt: a subdirectory named lib.w is not a source file: ok"
    else echo "  FAIL: $tgt subdirectory case printed [$got]"; fail=1; fi
  else echo "  FAIL: $tgt build with a lib.w subdirectory: $(head -1 "$tmp/err")"; fail=1; fi
done

# A sibling that cannot be read is named in the error. The build used to say
# it could not read app.w.
mkdir -p "$tmp/unread"
printf 'out(1)\n'           > "$tmp/unread/app.w"
printf 'f()\n    return 1\n' > "$tmp/unread/b.w"
chmod 000 "$tmp/unread/b.w"
if cat "$tmp/unread/b.w" >/dev/null 2>&1; then
  echo "  an unreadable sibling is named: SKIP (this user can read a mode 000 file)"
else
  msg=$("$WORD" build "$tmp/unread/app.w" -o "$tmp/unread/x" 2>&1 || true)
  case "$msg" in
    "cannot read "*"unread/b.w") echo "  an unreadable sibling is named, not app.w: ok" ;;
    *) echo "  FAIL: an unreadable sibling gave [$msg]"; fail=1 ;;
  esac
fi
chmod 644 "$tmp/unread/b.w"

[ "$fail" = 0 ] || { echo "test_folder: FAIL"; exit 1; }
echo "test_folder: PASS"
