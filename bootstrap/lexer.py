#!/usr/bin/env python3
"""
Lexer for the `word` language (SPEC.md), phase 1 of the seed compiler.

Turns source text into a flat list of tokens for the parser. One file, no
dependencies. It's written in Python to be easy to read, because this is the
seed that proves the committed binary (see bootstrap/wordc.py).

Blocks are significant indentation (spaces only): the lexer emits INDENT when a
line is indented further than the one before, and DEDENT(s) when it comes back.
These stand in for the `{` and `}` a braced language would use.

Run it directly to lex the built-in sample:
    python3 lexer.py
Lex a file instead:
    python3 lexer.py path/to/app.w
"""

import sys
from dataclasses import dataclass

# --- character classes (ASCII only outside literals, per spec 2.1) ---------
DIGITS = "0123456789"
TWO_63 = 1 << 63          # the seed's largest literal, for -2^63 (nothing checks for the minus)


def is_id_start(c):
    return c.isascii() and (c.isalpha() or c == "_")


def is_id_cont(c):
    return c.isascii() and (c.isalnum() or c == "_")


# --- token kinds -----------------------------------------------------------
# The five keywords. `break` is loop-only (the analyzer checks). The contextual
# words `before`/`after`/`result`/`import` aren't here: they lex as ordinary
# IDENTs, and the parser recognises each one only where it means something.
KEYWORDS = {"if", "else", "loop", "return", "break"}

# The four singleton literals (SPEC 3.8). They're values, not identifiers, so
# they lex as their own token, and `true = 1` is a parse error instead of a
# shadowing assignment.
SINGLETONS = {"true", "false", "null", "none"}

# Operators and punctuation, longest first so a multi-character token beats its
# one-character prefix (`<=` before `<`, `:=` before `:`, `==` before `=`).
# `.` is the join operator. The seed has no floats, so a `.` between digits is
# a join, not a decimal point. Braces are only for map literals (blocks are
# indentation), and there's no `..` or `;`.
OPERATORS = [
    ("<<", "LSHIFT"), (">>", "RSHIFT"),
    ("==", "EQ_EQ"), ("!=", "BANG_EQ"),
    ("<=", "LE"), (">=", "GE"),
    ("&&", "AND"), ("||", "OR"),
    (":=", "DECLARE"),
    ("+", "PLUS"), ("-", "MINUS"), ("*", "STAR"), ("/", "SLASH"), ("%", "PERCENT"),
    ("<", "LT"), (">", "GT"),
    ("!", "BANG"), ("~", "TILDE"),
    ("&", "AMP"), ("|", "PIPE"), ("^", "CARET"),
    ("=", "ASSIGN"),
    ("(", "LPAREN"), (")", "RPAREN"),
    ("[", "LBRACKET"), ("]", "RBRACKET"),
    ("{", "LBRACE"), ("}", "RBRACE"),
    (",", "COMMA"), (":", "COLON"), (".", "DOT"),
]

# Escape sequences -> the scalar value they stand for (spec 2.8). No \x / \u.
ESCAPES = {"n": 10, "t": 9, "r": 13, "0": 0, "\\": 92, "'": 39, '"': 34}

# Brackets that suppress newlines AND indentation while open (spec 2.2).
OPEN = {"LPAREN", "LBRACKET", "LBRACE"}
CLOSE = {"RPAREN", "RBRACKET", "RBRACE"}


@dataclass
class Token:
    kind: str        # "INT", "IDENT", "IF", "PLUS", "NEWLINE", "INDENT", "EOF", ...
    value: object    # int (INT/CHAR), list[int] (STRING), str (IDENT), else None
    line: int
    col: int

    def __repr__(self):
        v = "" if self.value is None else f" {self.value!r}"
        return f"{self.kind}{v} @{self.line}:{self.col}"


class LexError(Exception):
    def __init__(self, msg, line, col):
        super().__init__(f"{line}:{col}: {msg}")
        self.line, self.col = line, col


class Lexer:
    def __init__(self, src):
        self.src = src.replace("\r\n", "\n").replace("\r", "\n")  # normalise newlines
        self.i = 0
        self.line = 1
        self.col = 1
        self.depth = 0             # unmatched (, [ or {: newlines and indentation don't count
        self.indents = [0]         # indentation stack, in spaces
        self.at_line_start = True   # about to measure a logical line's indent?
        self.tokens = []

    # --- cursor helpers ---
    def peek(self, k=0):
        j = self.i + k
        return self.src[j] if j < len(self.src) else ""

    def advance(self):
        c = self.src[self.i]
        self.i += 1
        if c == "\n":
            self.line, self.col = self.line + 1, 1
        else:
            self.col += 1
        return c

    def emit(self, kind, value, line, col):
        self.tokens.append(Token(kind, value, line, col))

    def last_kind(self):
        return self.tokens[-1].kind if self.tokens else None

    # --- main loop ---
    def tokenize(self):
        while self.i < len(self.src):
            if self.at_line_start and self.depth == 0:
                self.line_start()            # measures indent, emits INDENT/DEDENT
                continue
            c = self.peek()
            if c in " \t":                   # insignificant mid-line whitespace
                self.advance()
            elif c == "\n":
                self.newline()
            elif c == "/" and self.peek(1) == "/":
                self.comment()
            elif is_id_start(c):
                self.ident()
            elif c in DIGITS:
                self.number()
            elif c == '"':
                self.string()
            elif c == "'":
                self.char()
            elif not self.operator():
                raise LexError(f"unexpected character {c!r}", self.line, self.col)
        self.finish()
        return self.tokens

    # --- indentation ---
    def line_start(self):
        indent, sline, scol = 0, self.line, self.col
        while self.peek() in (" ", "\t"):
            if self.peek() == "\t":
                raise LexError("indent with spaces, not tabs", self.line, self.col)
            self.advance()
            indent += 1
        c = self.peek()
        # blank line or comment-only line: no NEWLINE, no indentation change
        if c == "" or c == "\n" or (c == "/" and self.peek(1) == "/"):
            if c == "/":
                self.comment()
            if self.peek() == "\n":
                self.advance()
            return                           # stay at_line_start for the next line
        if indent > self.indents[-1]:
            self.indents.append(indent)
            self.emit("INDENT", None, sline, 1)
        elif indent < self.indents[-1]:
            while indent < self.indents[-1]:
                self.indents.pop()
                self.emit("DEDENT", None, sline, 1)
            if self.indents[-1] != indent:
                raise LexError("inconsistent dedentation", sline, scol)
        self.at_line_start = False

    def newline(self):
        line, col = self.line, self.col
        self.advance()                       # consume the \n
        if self.depth == 0:
            if self.last_kind() not in (None, "NEWLINE", "INDENT", "DEDENT"):
                self.emit("NEWLINE", None, line, col)
            self.at_line_start = True
        # inside brackets (depth > 0) a newline is an implicit continuation: ignored

    def finish(self):
        if self.last_kind() not in (None, "NEWLINE", "INDENT", "DEDENT"):
            self.emit("NEWLINE", None, self.line, self.col)
        while len(self.indents) > 1:
            self.indents.pop()
            self.emit("DEDENT", None, self.line, self.col)
        self.emit("EOF", None, self.line, self.col)

    # --- token readers ---
    def comment(self):
        while self.peek() and self.peek() != "\n":
            self.advance()

    def ident(self):
        line, col = self.line, self.col
        start = self.i
        while is_id_cont(self.peek()):
            self.advance()
        text = self.src[start:self.i]
        if text in KEYWORDS:
            self.emit(text.upper(), None, line, col)
        elif text in SINGLETONS:
            self.emit("SINGLETON", text, line, col)
        else:
            self.emit("IDENT", text, line, col)

    def number(self):
        line, col = self.line, self.col
        digits = [self.advance()]            # first digit (guaranteed by caller)
        while True:
            c = self.peek()
            if c in DIGITS:
                digits.append(self.advance())
            elif c == "_":                   # separators live strictly between digits
                if self.peek(1) not in DIGITS:
                    raise LexError("underscore must be between digits", self.line, self.col)
                self.advance()
                digits.append(self.advance())
            else:
                break
        if is_id_start(self.peek()):         # 12abc / 0x1F is one bad token, not two
            raise LexError(f"unexpected {self.peek()!r} after number", self.line, self.col)
        value = int("".join(digits))
        if value > TWO_63:                   # 2^63 itself is allowed (for -9223372036854775808)
            raise LexError("integer literal out of range", line, col)
        self.emit("INT", value, line, col)

    def read_escape(self):                    # cursor is on the backslash
        self.advance()
        e = self.peek()
        if e == "":
            raise LexError("unterminated escape", self.line, self.col)
        if e not in ESCAPES:
            raise LexError(f"unknown escape \\{e}", self.line, self.col)
        self.advance()
        return ESCAPES[e]

    def string(self):
        line, col = self.line, self.col
        self.advance()                        # opening "
        out = []
        while True:
            c = self.peek()
            if c == "":
                raise LexError("unterminated string", line, col)
            if c == "\n":
                raise LexError("newline in string literal", self.line, self.col)
            if c == '"':
                self.advance()
                break
            out.append(self.read_escape() if c == "\\" else ord(self.advance()))
        self.emit("STRING", out, line, col)   # one element per Unicode scalar value

    def char(self):
        line, col = self.line, self.col
        self.advance()                        # opening '
        c = self.peek()
        if c == "'":                          # '' and ''' are both empty-char errors
            raise LexError("empty character literal", line, col)
        if c in ("", "\n"):
            raise LexError("unterminated char literal", line, col)
        value = self.read_escape() if c == "\\" else ord(self.advance())
        if self.peek() != "'":
            raise LexError("char literal must be exactly one character", self.line, self.col)
        self.advance()                        # closing '
        self.emit("CHAR", value, line, col)

    def operator(self):
        for text, kind in OPERATORS:
            if self.src.startswith(text, self.i):
                line, col = self.line, self.col
                for _ in text:
                    self.advance()
                if kind in OPEN:
                    self.depth += 1
                elif kind in CLOSE:
                    self.depth = max(0, self.depth - 1)
                self.emit(kind, None, line, col)
                return True
        return False


# --- demo / self-test ------------------------------------------------------
SAMPLE = r'''// the word language: indentation, no braces, no fn, `.` (not +) builds strings
add(a, b)
    return a + b

greet(name)
    out("hi " . name . "\n")

total := 0
i := 0
loop i < 3
    total = total + add(i, 1)
    i = i + 1

greet("world")
out(total . "\n")

names := array(2)
names[0] = "banana"
names[1] = "apple"
if names[0] > names[1]           // lexicographic comparison of two regions
    out("swap\n")

n := 0
loop
    n = n + 1
    if n >= 5
        break

divide(a, b)
    return a / b

divide:before
    if b == 0
        return 0
'''


def main():
    if len(sys.argv) > 1:
        with open(sys.argv[1], encoding="utf-8") as f:
            src, name = f.read(), sys.argv[1]
    else:
        src, name = SAMPLE, "<sample>"
    try:
        for t in Lexer(src).tokenize():
            print(t)
    except LexError as e:
        print(f"{name}:{e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
