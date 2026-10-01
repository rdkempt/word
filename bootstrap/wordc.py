#!/usr/bin/env python3
"""
wordc: the bootstrap seed for `word`.

This isn't the word compiler. The word compiler is compiler/word.w, written in
word. This is a separate implementation, so the first word binary can be built
by something that isn't word itself (docs/BOOTSTRAP.md). Its one job is to
compile compiler/word.w on Linux x86-64:

    python3 bootstrap/wordc.py compiler/word.w -o word_A
    ./word_A build compiler/word.w -o word_B      # word_B == the committed word

It runs the whole pipeline (lexer, parser, analyzer, code generator, assembler,
static-ELF writer) and produces an executable that depends on nothing: no libc,
and by default no GNU as/ld either. Like the folder model of SPEC 11, it
compiles every .w file beside the entry file along with it. (The compiler does
that only for an entry named app.w. compiler/ holds only word.w, so the
difference never comes up.)

    python3 wordc.py app.w              # -> ./app   (plus any *.w in its dir)
    python3 wordc.py app.w -o myprog    # -> ./myprog
    python3 wordc.py app.w -S           # emit ./app.s and stop
    python3 wordc.py app.w --binutils   # -> ./app via GNU as/ld (second opinion)

--binutils swaps the Python assembler and ELF writer for GNU as/ld. That
assembles the same emitted text with code that shares nothing with this one, so
a bug in asm.py can't hide.

It targets Linux x86-64 only. word_A cross-compiles to every other target
(arm64, Windows PE, Mach-O), the same way the shipped binary does, and a second
target in the seed would only give an auditor more to read.
"""

import os
import sys
import glob
import subprocess

from lexer import Lexer, LexError
from parser import Parser, ParseError, Program, Function, Hook
from analyzer import Analyzer, AnalysisError, MODULES
from codegen import Codegen, CodegenError

def _emit_elf_direct(asm_text, out_path):
    """Assemble and link to a runnable ELF with the seed's own writer in
    asm_link.py, with no external as/ld. Linux x86-64 only."""
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    import asm_link
    secs, labels, relocs, bss, entry = asm_link.assemble([asm_text])
    blob = asm_link.link_elf(secs, labels, relocs, bss, entry)
    with open(out_path, "wb") as f:
        f.write(blob)
    os.chmod(out_path, 0o755)


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def _strip_netlib_region(src):
    # The net library is carried as text in a NETLIB region of compiler/word.w
    # (see netlib_embed there). The word compiler lifts that region out before
    # compiling itself, and this seed does the same, so it never tries to
    # compile the library, which uses `none` (a value this seed doesn't
    # implement). The library still reaches the committed binary: word_A, built
    # here, embeds it when it rebuilds compiler/word.w, as the real compiler
    # does.
    lines = src.split("\n")
    b = next((i for i, l in enumerate(lines) if ">>> NETLIB BEGIN" in l), -1)
    if b < 0:
        return src
    e = next(i for i, l in enumerate(lines) if "<<< NETLIB END <<<" in l)
    del lines[b:e + 1]
    return "\n".join(lines)


def parse_file(path):
    try:
        with open(path, encoding="utf-8") as f:
            src = f.read()
    except OSError as e:
        die(f"wordc: cannot read {path}: {e.strerror}")
    src = _strip_netlib_region(src)
    try:
        return Parser(Lexer(src).tokenize()).parse()
    except (LexError, ParseError) as e:
        die(f"{path}:{e}")


def check_library(path, prog):
    # a non-entry file holds definitions only (§11)
    if prog.imports:
        die(f"{path}: imports may appear only in the entry file")
    for it in prog.items:
        if not isinstance(it, (Function, Hook)):
            die(f"{path}:{it.line}:{it.col}: only the entry file may contain top-level statements")


def build_program(entry_path):
    """Merge the entry file, the rest of its directory, and any imported sibling
    directories into one Program (§11). Definition order across files is
    irrelevant, so functions and hooks are simply concatenated; the entry file's
    top-level statements stay in order and remain the program's execution."""
    entry_dir = os.path.dirname(entry_path) or "."
    entry_abs = os.path.abspath(entry_path)

    entry_prog = parse_file(entry_path)
    items = list(entry_prog.items)

    def add_dir(directory, label):
        for f in sorted(glob.glob(os.path.join(directory, "*.w"))):
            if os.path.abspath(f) == entry_abs:
                continue
            p = parse_file(f)
            check_library(f, p)
            items.extend(p.items)

    add_dir(entry_dir, "program directory")
    for imp in entry_prog.imports:
        if imp.name in MODULES:
            continue                       # built-in module, provided by codegen
        sib = os.path.join(entry_dir, imp.name)
        if not os.path.isdir(sib):
            die(f"{entry_path}: import '{imp.name}': no such module or sibling directory")
        add_dir(sib, imp.name)

    return Program(entry_prog.imports, items)


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        die("usage: wordc <program.w> [-o output] [-S] [--binutils]")

    args = [a for a in args]
    # The default is the seed's own ELF writer (no GNU as/ld). --binutils
    # assembles and links the same emitted text with GNU as/ld instead, as a
    # second opinion on asm.py. It isn't a fallback.
    use_binutils = "--binutils" in args
    while "--binutils" in args:
        args.remove("--binutils")
    direct = not use_binutils
    src_path = args[0]
    emit_asm_only = "-S" in args
    if "-o" in args:
        out_path = args[args.index("-o") + 1]
    else:
        base = src_path[:-2] if src_path.endswith(".w") else src_path
        out_path = base + (".s" if emit_asm_only else "")

    merged = build_program(src_path)
    try:
        Analyzer(merged).analyze()
        asm = Codegen(merged, target="linux").generate()
    except (AnalysisError, CodegenError) as e:
        die(f"{src_path}:{e}")

    if emit_asm_only:
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(asm)
        print(f"wrote {out_path}")
        return

    if direct:
        try:
            _emit_elf_direct(asm, out_path)
        except NotImplementedError as e:
            die(f"wordc: the built-in assembler does not handle this program ({e}); "
                f"retry with --binutils")
        return

    asm_path, obj_path = out_path + ".s", out_path + ".o"
    with open(asm_path, "w", encoding="utf-8") as f:
        f.write(asm)
    try:
        subprocess.run(["as", asm_path, "-o", obj_path], check=True)
        subprocess.run(["ld", obj_path, "-o", out_path], check=True)
    except FileNotFoundError:
        die("wordc: --binutils needs GNU as/ld on PATH; omit it to use the "
            "built-in ELF writer")
    except subprocess.CalledProcessError as e:
        die(f"wordc: assembler/linker failed ({e})")
    finally:
        for p in (asm_path, obj_path):
            try:
                os.remove(p)
            except OSError:
                pass
    os.chmod(out_path, 0o755)


if __name__ == "__main__":
    main()
