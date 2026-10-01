#!/usr/bin/env python3
"""
Parser for the `word` language (SPEC.md), phase 2 of the seed compiler.

Recursive descent over the token stream from lexer.py, producing an AST. One
file, depending only on the lexer. The expression grammar is a precedence ladder
(§4.1): one small function per level, each a left-associative loop, so the code
follows the grammar and needs no table.

Two rules from §4.2 shape the statement parser:
  - No `fn` keyword: a `name(args)` line is a function DEFINITION if an indented
    block follows, and a CALL otherwise. We parse the header, then look for INDENT.
  - Only a call can stand alone as a statement. A bare expression like `x + 1` is
    an error, and assignment is a statement, not an expression.

The parser only checks syntax. Semantic checks (arity, declare-before-use,
duplicate definitions, "break only in a loop", contract param-matching, kind
errors) are left to the analyzer.

Run it directly to parse the built-in sample and print the tree:
    python3 parser.py
Parse a file instead:
    python3 parser.py path/to/app.w
"""

import sys
from dataclasses import dataclass, field
from lexer import Lexer, LexError

# token kind -> operator symbol stored in the AST
OPSYM = {
    "OR": "||", "AND": "&&",
    "EQ_EQ": "==", "BANG_EQ": "!=", "LT": "<", "LE": "<=", "GT": ">", "GE": ">=",
    "DOT": ".",
    "PLUS": "+", "MINUS": "-", "PIPE": "|", "CARET": "^",
    "STAR": "*", "SLASH": "/", "PERCENT": "%", "LSHIFT": "<<", "RSHIFT": ">>", "AMP": "&",
    "BANG": "!", "TILDE": "~",
}

# --- AST -------------------------------------------------------------------
# Every node carries the source position of its leading token, so later phases
# can report `file:line` (§10). Character and integer literals are both a `Num`,
# because a character literal is its code point (§2.7).

@dataclass
class Program:  imports: list; items: list
@dataclass
class Import:    name: str; line: int; col: int
@dataclass
class Function:  name: str; params: list; body: list; line: int; col: int
@dataclass
class Hook:      targets: list; body: list; line: int; col: int   # targets: [(name, "before"|"after")]

@dataclass
class Decl:      name: str; expr: object; line: int; col: int      # x := e
@dataclass
class Assign:    target: object; expr: object; line: int; col: int # lvalue = e
@dataclass
class If:        cond: object; then: list; orelse: object; line: int; col: int  # orelse: list | None
@dataclass
class Loop:      cond: object; body: list; line: int; col: int     # cond None => infinite
@dataclass
class Return:    expr: object; line: int; col: int                 # expr None => bare
@dataclass
class Break:     line: int; col: int
@dataclass
class ExprStmt:  call: object; line: int; col: int                 # always wraps a Call

@dataclass
class Num:       value: int; line: int; col: int
@dataclass
class Str:       elems: list; line: int; col: int
@dataclass
class Name:      ident: str; line: int; col: int
@dataclass
class Singleton: word: str; line: int; col: int    # true / false / null / none
@dataclass
class Binary:    op: str; left: object; right: object; line: int; col: int
@dataclass
class Unary:     op: str; operand: object; line: int; col: int
@dataclass
class Index:     base: object; index: object; line: int; col: int
@dataclass
class Call:      name: str; args: list; line: int; col: int
@dataclass
class MapLit:    keys: list; vals: list; line: int; col: int    # {} or {k: v, ...}


class ParseError(Exception):
    def __init__(self, msg, line, col):
        super().__init__(f"{line}:{col}: {msg}")
        self.line, self.col = line, col


class Parser:
    def __init__(self, tokens):
        self.toks = tokens
        self.pos = 0

    # --- cursor ---
    def peek(self, k=0):
        i = self.pos + k
        return self.toks[i] if i < len(self.toks) else self.toks[-1]   # last token is EOF

    def check(self, *kinds):
        return self.peek().kind in kinds

    def advance(self):
        t = self.peek()
        self.pos += 1
        return t

    def expect(self, kind, what):
        if self.peek().kind != kind:
            self.error(f"expected {what}, found {self.describe(self.peek())}")
        return self.advance()

    def error(self, msg, tok=None):
        tok = tok or self.peek()
        raise ParseError(msg, tok.line, tok.col)

    @staticmethod
    def describe(tok):
        if tok.kind == "NEWLINE": return "end of line"
        if tok.kind == "INDENT":  return "an indent"
        if tok.kind == "DEDENT":  return "a dedent"
        if tok.kind == "EOF":     return "end of file"
        if tok.value is not None: return f"{tok.kind} {tok.value!r}"
        return tok.kind

    # --- program ---
    def parse(self):
        imports = self.parse_imports()
        items = []
        while not self.check("EOF"):
            items.append(self.parse_top_item())
        return Program(imports, items)

    def parse_imports(self):
        out = []
        while (self.peek().kind == "IDENT" and self.peek().value == "import"
               and self.peek(1).kind == "IDENT"):
            t = self.advance()                       # 'import'
            name = self.advance().value              # module or directory name
            self.expect("NEWLINE", "a newline after the import")
            out.append(Import(name, t.line, t.col))
        return out

    def parse_top_item(self):
        t = self.peek()
        if t.kind in ("IF", "LOOP", "RETURN", "BREAK"):
            return self.parse_statement(top=True)
        if t.kind == "IDENT":
            if self.peek(1).kind == "COLON":          # name:before / name:after
                return self.parse_hook()
            return self.parse_ident_statement(top=True)
        self.error(f"expected a definition or a statement, found {self.describe(t)}")

    # --- statements ---
    def parse_statement(self, top=False):
        t = self.peek()
        if t.kind == "IF":     return self.parse_if()
        if t.kind == "LOOP":   return self.parse_loop()
        if t.kind == "RETURN": return self.parse_return()
        if t.kind == "BREAK":
            self.advance()
            self.expect("NEWLINE", "a newline after break")
            return Break(t.line, t.col)
        if t.kind == "IDENT":
            return self.parse_ident_statement(top=top)
        self.error(f"expected a statement, found {self.describe(t)}")

    def parse_ident_statement(self, top):
        """An identifier at statement position: declaration, assignment, call, or
        (top level only) a function definition."""
        t = self.peek()
        if self.peek(1).kind == "DECLARE":            # x := expr
            name = self.advance().value
            self.advance()                            # :=
            expr = self.parse_expr()
            self.expect("NEWLINE", "a newline after the declaration")
            return Decl(name, expr, t.line, t.col)

        node = self.postfix()                         # Name / Call / Index / Call[...]

        # a header line (NEWLINE then INDENT) opens a block -> function definition
        if self.check("NEWLINE") and self.peek(1).kind == "INDENT":
            if not top:
                self.error("nested functions are not allowed", tok=self.peek(1))
            if not isinstance(node, Call):
                self.error("only a function header may open a block here", tok=t)
            return self.finish_function(node, t)

        if self.check("ASSIGN"):                      # lvalue = expr
            self.advance()
            expr = self.parse_expr()
            self.expect("NEWLINE", "a newline after the assignment")
            if not isinstance(node, (Name, Index)):
                raise ParseError("this cannot be assigned to", node.line, node.col)
            return Assign(node, expr, t.line, t.col)

        if isinstance(node, Call) and self.check("NEWLINE"):
            self.advance()
            return ExprStmt(node, t.line, t.col)

        # a bare expression (e.g. `x + 1`) does nothing and is not a statement (§4.2)
        self.error("a bare expression is not a statement: expected a call, an "
                   "assignment, or a declaration", tok=self.peek())

    def finish_function(self, call_node, t):
        params = []
        for a in call_node.args:
            if not isinstance(a, Name):
                raise ParseError("function parameters must be plain names",
                                 a.line, a.col)
            params.append(a.ident)
        self.expect("NEWLINE", "a newline after the function header")
        body = self.parse_block()
        return Function(call_node.name, params, body, t.line, t.col)

    def parse_hook(self):
        t = self.peek()
        targets = []
        while True:
            name_tok = self.expect("IDENT", "a function name")
            self.expect("COLON", "':'")
            kind_tok = self.expect("IDENT", "'before' or 'after'")
            if kind_tok.value not in ("before", "after"):
                self.error("expected 'before' or 'after' after ':'", tok=kind_tok)
            targets.append((name_tok.value, kind_tok.value))
            if self.check("COMMA"):
                self.advance()
                continue
            break
        self.expect("NEWLINE", "a newline after the hook header")
        body = self.parse_block()
        return Hook(targets, body, t.line, t.col)

    def parse_if(self):
        t = self.advance()                            # if
        cond = self.parse_expr()
        self.expect("NEWLINE", "a newline after the condition")
        then = self.parse_block()
        orelse = None
        if self.check("ELSE"):
            self.advance()
            if self.check("IF"):                      # else if ... -> nested If
                orelse = [self.parse_if()]
            else:
                self.expect("NEWLINE", "a newline after else")
                orelse = self.parse_block()
        return If(cond, then, orelse, t.line, t.col)

    def parse_loop(self):
        t = self.advance()                            # loop
        cond = None if self.check("NEWLINE") else self.parse_expr()
        self.expect("NEWLINE", "a newline after the loop header")
        body = self.parse_block()
        return Loop(cond, body, t.line, t.col)

    def parse_return(self):
        t = self.advance()                            # return
        expr = None if self.check("NEWLINE") else self.parse_expr()
        self.expect("NEWLINE", "a newline after return")
        return Return(expr, t.line, t.col)

    def parse_block(self):
        self.expect("INDENT", "an indented block")
        stmts = []
        while not self.check("DEDENT"):
            if self.check("EOF"):
                self.error("unexpected end of file inside a block")
            stmts.append(self.parse_statement(top=False))
        self.advance()                                # DEDENT
        return stmts

    # --- expressions: one function per precedence level (§4.1) ---
    def parse_expr(self):
        return self.binary(0)

    # precedence levels, loosest first; each entry is (set of token kinds)
    LEVELS = [
        ("OR",),
        ("AND",),
        ("EQ_EQ", "BANG_EQ", "LT", "LE", "GT", "GE"),
        ("DOT",),
        ("PLUS", "MINUS", "PIPE", "CARET"),
        ("STAR", "SLASH", "PERCENT", "LSHIFT", "RSHIFT", "AMP"),
    ]

    def binary(self, level):
        if level >= len(self.LEVELS):
            return self.unary()
        left = self.binary(level + 1)
        while self.check(*self.LEVELS[level]):
            op = self.advance()
            right = self.binary(level + 1)
            left = Binary(OPSYM[op.kind], left, right, op.line, op.col)
        return left

    def unary(self):
        if self.check("BANG", "TILDE", "MINUS"):
            op = self.advance()
            return Unary(OPSYM[op.kind], self.unary(), op.line, op.col)
        return self.postfix()

    def postfix(self):
        node = self.call_or_primary()
        while self.check("LBRACKET"):
            lb = self.advance()
            idx = self.parse_expr()
            self.expect("RBRACKET", "']'")
            node = Index(node, idx, lb.line, lb.col)
        return node

    def call_or_primary(self):
        t = self.peek()
        if t.kind == "IDENT" and self.peek(1).kind == "LPAREN":
            name = self.advance().value
            self.advance()                            # (
            args = []
            if not self.check("RPAREN"):
                args.append(self.parse_expr())
                while self.check("COMMA"):
                    self.advance()
                    args.append(self.parse_expr())
            self.expect("RPAREN", "')'")
            return Call(name, args, t.line, t.col)
        return self.primary()

    def primary(self):
        t = self.peek()
        if t.kind == "INT":    self.advance(); return Num(t.value, t.line, t.col)
        if t.kind == "CHAR":   self.advance(); return Num(t.value, t.line, t.col)
        if t.kind == "STRING": self.advance(); return Str(t.value, t.line, t.col)
        if t.kind == "IDENT":  self.advance(); return Name(t.value, t.line, t.col)
        if t.kind == "SINGLETON":
            self.advance(); return Singleton(t.value, t.line, t.col)
        if t.kind == "LPAREN":
            self.advance()
            e = self.parse_expr()
            self.expect("RPAREN", "')'")
            return e
        if t.kind == "LBRACE":
            return self.map_literal()
        self.error(f"expected an expression, found {self.describe(t)}")

    def map_literal(self):
        """`{}` or `{name: expr, "quoted": expr}` (spec 3.7). A bare name key is
        the text of the name, not a variable read, as in a JavaScript object
        literal."""
        t = self.expect("LBRACE", "'{'")
        keys, vals = [], []
        while self.peek().kind != "RBRACE":
            k = self.peek()
            if k.kind == "IDENT":
                self.advance(); key = Str([ord(c) for c in k.value], k.line, k.col)
            elif k.kind == "STRING":
                self.advance(); key = Str(k.value, k.line, k.col)
            else:
                self.error(f"expected a map key, found {self.describe(k)}")
            self.expect("COLON", "':' after a map key")
            keys.append(key); vals.append(self.parse_expr())
            if self.peek().kind == "COMMA":
                self.advance()
            elif self.peek().kind != "RBRACE":
                self.error(f"expected ',' or '}}', found {self.describe(self.peek())}")
        self.expect("RBRACE", "'}'")
        return MapLit(keys, vals, t.line, t.col)


# --- pretty-printer for the demo -------------------------------------------
def expr_str(e):
    if e is None:                 return ""
    if isinstance(e, Num):        return str(e.value)
    if isinstance(e, Str):
        return '"' + "".join(chr(c) if 32 <= c < 127 else f"\\{c}" for c in e.elems) + '"'
    if isinstance(e, Name):       return e.ident
    if isinstance(e, Singleton):  return e.word
    if isinstance(e, Binary):     return f"({expr_str(e.left)} {e.op} {expr_str(e.right)})"
    if isinstance(e, Unary):      return f"({e.op}{expr_str(e.operand)})"
    if isinstance(e, Index):      return f"{expr_str(e.base)}[{expr_str(e.index)}]"
    if isinstance(e, Call):       return f"{e.name}(" + ", ".join(expr_str(a) for a in e.args) + ")"
    if isinstance(e, MapLit):
        return "{" + ", ".join(f"{expr_str(k)}: {expr_str(v)}" for k, v in zip(e.keys, e.vals)) + "}"
    return repr(e)


def dump(n, d=0):
    pad = "  " * d
    if isinstance(n, Program):
        out = [f"{pad}import {i.name}" for i in n.imports]
        out += [dump(it, d) for it in n.items]
        return "\n".join(out)
    if isinstance(n, Function):
        head = f"{pad}fn {n.name}({', '.join(n.params)})"
        return "\n".join([head] + [dump(s, d + 1) for s in n.body])
    if isinstance(n, Hook):
        tg = ", ".join(f"{name}:{kind}" for name, kind in n.targets)
        return "\n".join([f"{pad}hook {tg}"] + [dump(s, d + 1) for s in n.body])
    if isinstance(n, Decl):
        return f"{pad}decl {n.name} = {expr_str(n.expr)}"
    if isinstance(n, Assign):
        return f"{pad}assign {expr_str(n.target)} = {expr_str(n.expr)}"
    if isinstance(n, If):
        out = [f"{pad}if {expr_str(n.cond)}"] + [dump(s, d + 1) for s in n.then]
        if n.orelse is not None:
            out.append(f"{pad}else")
            out += [dump(s, d + 1) for s in n.orelse]
        return "\n".join(out)
    if isinstance(n, Loop):
        head = "loop" if n.cond is None else f"loop {expr_str(n.cond)}"
        return "\n".join([f"{pad}{head}"] + [dump(s, d + 1) for s in n.body])
    if isinstance(n, Return):
        return f"{pad}return {expr_str(n.expr)}".rstrip()
    if isinstance(n, Break):
        return f"{pad}break"
    if isinstance(n, ExprStmt):
        return f"{pad}{expr_str(n.call)}"
    return f"{pad}{n!r}"


SAMPLE = r'''import fs

add(a, b)
    return a + b

divide(a, b)
    return a / b

divide:before
    if b == 0
        return 0

total := 0
i := 0
loop i < 3
    total = total + add(i, 1)
    i = i + 1

names := array(2)
names[0] = "banana"
names[1] = "apple"
if names[0] > names[1]
    out("swap" . "\n")
else
    out(total . "\n")
'''


def main():
    if len(sys.argv) > 1:
        with open(sys.argv[1], encoding="utf-8") as f:
            src, name = f.read(), sys.argv[1]
    else:
        src, name = SAMPLE, "<sample>"
    try:
        tokens = Lexer(src).tokenize()
        tree = Parser(tokens).parse()
        print(dump(tree))
    except (LexError, ParseError) as e:
        print(f"{name}:{e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
