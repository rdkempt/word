# win_runner.sh: how to run a Windows PE from a POSIX shell, for the two
# Windows test scripts. Sourced, not executed.
#
# There are three ways, and this file finds whichever is there, best first:
#
#   native: the shell is running on Windows (Git Bash / MSYS), so a PE is just
#           a program. Nothing emulates anything or translates a syscall. The
#           other two approximate this case, and it's what
#           .github/workflows/windows.yml runs. argv has to be spelled the
#           Windows way, which is what pe_path is for.
#   wine:   a dev oracle (CI doesn't install wine). Cross-compile on Linux and
#           run under wine. wine maps the Unix root to Z:, so an absolute Linux
#           path in argv resolves as it is.
#   WSL:    a Windows PE run from WSL is executed by Windows itself, through
#           binfmt interop. No emulation and nothing to install: on a Windows
#           machine, this is the real thing without a native Windows shell. The
#           catch is argv. The process is a Windows process, so a path in an
#           argument has to be spelled the Windows way (`wslpath -w`). The .exe
#           being launched is named the Linux way, since WSL translates that one.
#
# Each of them is only for running things: none is needed to build word, or to
# build a word program for Windows. When none is available, the caller skips
# its runtime cases and keeps the structural ones.
#
# Sets PE_KIND (native|wine|wsl|empty) and defines pe_path / pe_run. Call
# win_runner_init <tmpdir> first, then win_runner_probe <exe> <expected-stdout>
# to check the runner works before relying on it. A Windows that refuses to run
# from a UNC path, or a broken wine prefix, should give a skip instead of a wall
# of failures.

PE_KIND=""
PE_WINE=""

win_runner_init() {
    _wr_tmp="$1"
    # PE_RUNNER forces a choice: `none` to check the skip paths, `wsl` to use
    # interop on a machine that also has wine, `wine` for the reverse. Any other
    # value (`native`, say) gets the normal order below.
    if [ "$PE_RUNNER" = none ]; then return 0; fi
    if [ "$PE_RUNNER" = wsl ] && command -v wslpath >/dev/null 2>&1; then
        PE_KIND=wsl; return 0
    fi
    # Running on Windows already. That's the best case, so only an explicit
    # PE_RUNNER overrides it.
    if [ "$PE_RUNNER" != wine ]; then
        case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
            msys*|cygwin*|win32|MINGW*|MSYS*|CYGWIN*) PE_KIND=native; return 0 ;;
        esac
    fi
    # An explicit $WINE wins: it's how you point the suite at a specific build.
    if [ -n "$WINE" ] && command -v "$WINE" >/dev/null 2>&1; then
        PE_WINE="$WINE"
    else
        for _w in wine64 wine; do
            command -v "$_w" >/dev/null 2>&1 && { PE_WINE="$_w"; break; }
        done
        [ -z "$PE_WINE" ] && [ -x /usr/lib/wine/wine64 ] && PE_WINE=/usr/lib/wine/wine64
    fi
    if [ -n "$PE_WINE" ] && [ "$PE_RUNNER" != wsl ]; then
        PE_KIND=wine
        export WINEDEBUG=-all WINEPREFIX="$_wr_tmp/wp" HOME="$_wr_tmp"
        return 0
    fi
    # No wine. Are we inside WSL with interop switched on? Both binfmt names have
    # been used across releases, and wslpath is needed for argv translation.
    if [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] || [ -e /proc/sys/fs/binfmt_misc/WSLInterop-late ]; then
        if command -v wslpath >/dev/null 2>&1; then
            PE_KIND=wsl
            return 0
        fi
    fi
    return 0
}

# pe_path <unix-path> -> the same path as the PE will read it in argv.
pe_path() {
    if [ "$PE_KIND" = native ]; then
        # MSYS hands the script /d/a/word/x, and the PE needs D:/a/word/x. The
        # same conversion hostpath.sh does, for the same reason.
        if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
    elif [ "$PE_KIND" = wsl ]; then
        _pp_d=$(dirname "$1"); _pp_b=$(basename "$1")
        # Translate the directory (which exists) and put the leaf back on, so
        # this works for an output file that hasn't been created yet.
        printf '%s\\%s' "$(wslpath -w "$_pp_d")" "$_pp_b"
    else
        printf '%s' "$1"
    fi
}

# pe_run <timeout-seconds> <exe> [args...] -> runs the PE, passing stdio through.
#
# Under interop the kernel execs the file directly, so it needs the owner-execute
# bit, and a PE that a Windows process wrote onto the WSL filesystem (through
# the \\wsl.localhost share) arrives without one. The bytes are right, but the
# file can't be run. Comparing bytes still passes (word.exe rebuilding itself),
# but running the output doesn't (word.exe building hello.w, then running it).
# So pe_run adds the bit, here instead of at every call site.
pe_run() {
    _pr_t="$1"; shift
    if [ "$PE_KIND" = native ]; then
        timeout "$_pr_t" "$@"
    elif [ "$PE_KIND" = wine ]; then
        timeout "$_pr_t" "$PE_WINE" "$@"
    elif [ "$PE_KIND" = wsl ]; then
        [ -f "$1" ] && [ ! -x "$1" ] && chmod +x "$1" 2>/dev/null
        timeout "$_pr_t" "$@"
    else
        return 127
    fi
}

# win_runner_probe <exe> <expected-stdout> -> 0 if the runner really works.
# Clears PE_KIND when it doesn't, so every later case skips itself.
win_runner_probe() {
    [ -n "$PE_KIND" ] || return 1
    _wp_got=$(pe_run 90 "$1" 2>/dev/null || true)
    if [ "$_wp_got" = "$2" ]; then
        return 0
    fi
    echo "  SKIP: $PE_KIND is present but could not run a PE (got [$_wp_got]), so the runtime cases are skipped"
    PE_KIND=""
    return 1
}

# win_runner_name -> a human label for the skip/ok lines.
win_runner_name() {
    case "$PE_KIND" in
        native) echo "Windows itself" ;;
        wine)   echo "wine" ;;
        wsl)    echo "WSL interop (real Windows)" ;;
        *)      echo "none" ;;
    esac
}
