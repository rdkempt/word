# hostpath.sh: a path that both this shell and the word binary can open.
#
# Sourced, not run. On Linux and macOS it returns the path unchanged and costs
# one `uname`. On Windows it's what lets the suite run natively.
#
# The Windows job runs these scripts under Git Bash, which is MSYS: it hands a
# script POSIX paths like /d/a/word/word, and every POSIX tool in the suite
# (cat, mktemp, openssl, python3) understands them. `word.exe` doesn't. It's a
# native Windows binary that opens files with CreateFileA, which reads
# /d/a/word/word as \d\a\word\word on the current drive, so the open fails and
# `word build` says it cannot read a file that's there.
#
# `cygpath -m` writes the same location as D:/a/word/word, which MSYS tools
# accept as readily as the POSIX form. So one conversion at the top of a script
# keeps every line below it working for both kinds of program, and no call site
# has to know which platform it's on.
hostpath() {
  case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32|MINGW*|MSYS*|CYGWIN*)
      if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi ;;
    *)
      printf '%s\n' "$1" ;;
  esac
}

# wordbin <path> -> the same binary as an absolute path.
#
# Several of these suites cd into a temporary directory before running word, so
# a relative WORD (`WORD=./word.exe`, the natural thing to write in a workflow)
# stops resolving partway through the run. Making it absolute once, at the top,
# fixes that. It's separate from hostpath(): this one is about surviving a cd,
# and that one is about which OS has to open the path.
wordbin() {
  case "$1" in
    /*|[A-Za-z]:*|[A-Za-z]:[/\]*) printf '%s
' "$1" ;;
    *) printf '%s
' "$(cd "$(dirname "$1")" 2>/dev/null && pwd)/$(basename "$1")" ;;
  esac
}
