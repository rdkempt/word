#!/usr/bin/env python3
# netlib_cat.py <module>... | --list: print the named net-library modules, in
# order, or list every module's name.
#
# The net library is text in the NETLIB region of compiler/word.w (see
# netlib_embed). Tests and benchmarks that need a module's source get it here,
# since runtime/crypto/*.w is gone. The extraction does what netlib_region_module
# in the compiler does, so a test compiles the same bytes the compiler bundles.
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "compiler", "word.w")


def _region():
    s = open(SRC, encoding="utf-8", newline="").read()
    rb = s.find("// >>> NETLIB BEGIN")
    re = s.find("// <<< NETLIB END <<<")
    if rb < 0 or re < 0:
        sys.stderr.write("netlib_cat: no NETLIB region in compiler/word.w\n")
        sys.exit(1)
    return s[rb:re]


def module(region, mod):
    mk = "// >>> NETLIB MODULE " + mod + " >>>"
    a = region.find(mk)
    if a < 0:
        return None
    s = region.index("\n", a) + 1
    nxt = region.find("// >>> NETLIB", s)
    return region[s:] if nxt < 0 else region[s:nxt]


def modules(region):
    # Every module name, in region order. The region decides which modules
    # exist, so callers don't keep a second list.
    pre = "// >>> NETLIB MODULE "
    out = []
    i = region.find(pre)
    while i >= 0:
        j = region.index(" >>>", i + len(pre))
        out.append(region[i + len(pre):j])
        i = region.find(pre, j)
    return out


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: netlib_cat.py <module>... | --list\n")
        sys.exit(2)
    region = _region()
    if sys.argv[1] == "--list":
        # Write LF bytes, not text-mode stdout: a Windows Python would write
        # \r\n, and a caller's `for m in $(... --list)` would get a \r on each
        # name.
        sys.stdout.buffer.write(("\n".join(modules(region)) + "\n").encode("utf-8"))
        return
    # Write raw UTF-8 bytes: the module text is the compiler's own source, and a
    # test compiles these bytes. On Windows, sys.stdout would re-encode it as
    # cp1252 (U+2014 -> 0x97) and turn \n into \r\n. The region is LF UTF-8 and
    # has to come out unchanged.
    out = sys.stdout.buffer
    for m in sys.argv[1:]:
        t = module(region, m)
        if t is None:
            sys.stderr.write(f"netlib_cat: no module '{m}'\n")
            sys.exit(1)
        out.write(t.encode("utf-8"))


if __name__ == "__main__":
    main()
