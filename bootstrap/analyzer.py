#!/usr/bin/env python3
"""
Semantic analyzer for the `word` language (SPEC.md), phase 3 of the seed compiler.

Walks the AST from parser.py and runs the compile-time checks of §10.1, plus the
static kind resolution of §3.6. It doesn't change the tree. It validates it and
raises a located error on the first problem.

What it checks (§10.1):
  - names: declare-before-use for locals, no shadowing, functions are closed over
    their own params/locals (no top-level globals leak in)
  - calls: target is a known function / builtin / module function, with the
    right arity (a module needs no import)
  - static kind errors (§3.6): a numeric operator on text, an order-comparison of
    a number against text, or len/[]/slice applied to a number, when the compiler
    can see it. What it can't see statically is left to the runtime kind test.
  - control: break only in a loop; return only in a function/hook/top level; a
    bare return is never valid in a hook
  - contracts: hooks name real functions (not builtins); at most one before- and
    one after-hook per function; shared hooks have identical params and one kind;
    no after-hooked function has a parameter named `result`
  - duplicate definitions; and the app.w-only rules for imports and top-level code

Kind resolution is exposed as `static_kind(expr, funcs)` so codegen (phase 4) can
reuse it to decide where to emit the address-range test.

Run it directly to analyze the built-in sample and a set of deliberately broken
snippets:
    python3 analyzer.py
Analyze a file instead (treated as app.w):
    python3 analyzer.py path/to/app.w
"""

import sys
from lexer import Lexer, LexError
from parser import (Parser, ParseError, Program, Import, Function, Hook,
                    Decl, Assign, If, Loop, Return, Break, ExprStmt, MapLit,
                    Num, Str, Name, Singleton, Binary, Unary, Index, Call)

# --- kinds (§3.6) ----------------------------------------------------------
NUMBER, REGION, UNKNOWN = "number", "region", "unknown"

# builtins: name -> arity, and name -> result kind
BUILTINS = {"out": 1, "in": 0, "eof": 0, "len": 1, "array": 1, "slice": 3, "argument": 1, "numeric": 1,
            # the rest came to word after this seed was written; their arities
            # are copied from builtin_arity() in compiler/word.w, which is
            # where word decides them.
            "err": 1, "text": 1, "bytes": 1, "has": 2, "kind": 1, "args": 0, "env": 1, "random": 0,
            "copy": -1}   # copy is 1..3 (whole / from / range), so arity is checked by hand
# standard modules: module -> {function -> arity}
MODULES = {"fs": {"read": 1, "write": 2, "append": 2, "dir": 1},
           "net": {"get": 1, "post": 2, "put": 2, "delete": 1, "head": 1},
           "sys": {"asmput": 1, "asmtake": 0, "writex": 2, "exec": 2,
                   "mark": 0, "reset": 1, "arch": 0, "os": 0, "image": 0}}
ALL_MODULE_FUNCS = {fn: mod for mod, fns in MODULES.items() for fn in fns}

CALL_KIND = {
    "len": NUMBER, "array": REGION, "slice": REGION, "eof": NUMBER,
    "in": UNKNOWN, "out": UNKNOWN, "argument": REGION, "numeric": NUMBER,
    "read": UNKNOWN, "write": NUMBER, "append": NUMBER,
    "asmput": NUMBER, "asmtake": REGION, "writex": NUMBER, "exec": NUMBER,
    "err": UNKNOWN, "text": REGION, "bytes": REGION, "has": NUMBER, "kind": REGION,
    "args": REGION, "env": REGION, "random": NUMBER, "dir": REGION,
    "mark": NUMBER, "reset": NUMBER, "arch": REGION, "os": NUMBER, "image": UNKNOWN,
    "copy": UNKNOWN,   # a copy of a map is a map, of a region a region
}

NUMERIC_OPS = {"+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>"}
COMPARE_OPS = {"==", "!=", "<", "<=", ">", ">="}
ORDER_OPS = {"<", "<=", ">", ">="}


def static_kind(e, funcs):
    """The kind the compiler can prove for `e`, or UNKNOWN. `funcs` is the set of
    user-defined function names, which shadow builtins of the same name (§2.5)."""
    if isinstance(e, Num):    return NUMBER
    if isinstance(e, Singleton): return NUMBER   # the seed models true/false as 1/0
    if isinstance(e, Str):    return REGION
    if isinstance(e, Name):   return UNKNOWN     # a variable's kind needs flow analysis
    if isinstance(e, Index):  return UNKNOWN     # a cell may hold anything
    if isinstance(e, Unary):  return NUMBER
    if isinstance(e, Binary): return REGION if e.op == "." else NUMBER
    if isinstance(e, Call):
        if e.name in funcs:   return UNKNOWN     # user function -> decided at runtime
        return CALL_KIND.get(e.name, UNKNOWN)
    return UNKNOWN


class AnalysisError(Exception):
    def __init__(self, msg, line, col):
        super().__init__(f"{line}:{col}: {msg}")
        self.line, self.col = line, col


class Scope:
    def __init__(self, parent=None):
        self.names = set()
        self.parent = parent

    def resolve(self, name):
        s = self
        while s is not None:
            if name in s.names:
                return True
            s = s.parent
        return False

    def declare(self, name):
        self.names.add(name)


class Analyzer:
    def __init__(self, program, is_app=True, externs=None):
        self.program = program
        self.is_app = is_app
        self.externs = externs or {}     # name -> arity, from other files/dirs in a full build
        self.funcs = {}                  # name -> Function node
        self.module_funcs = {}           # name -> arity, from imported modules
        self.before_of = {}              # func name -> Hook
        self.after_of = {}

    def err(self, msg, node):
        raise AnalysisError(msg, node.line, node.col)

    def kind_of(self, e):
        return static_kind(e, set(self.funcs))

    # --- entry ---
    def analyze(self):
        self.collect()
        top = Scope()
        for it in self.program.items:
            if isinstance(it, Function):
                self.check_function(it)
            elif isinstance(it, Hook):
                self.check_hook(it)
            else:
                self.check_stmt(it, top, 0, "toplevel")
        return self.program

    # --- pass 1: gather functions, imports, and validate contracts ---
    def collect(self):
        if not self.is_app and self.program.imports:
            self.err("imports may appear only in app.w", self.program.imports[0])
        # Every module the compiler provides is available without an import: the
        # compiler knows which module each of these names belongs to, so calling
        # `read` is what pulls in `fs`. In this seed an import of any other name
        # is a sibling directory, which word 1.0 doesn't have (SPEC 15);
        # compiler/word.w imports nothing. A function the program defines
        # itself still shadows a module's.
        for mod in MODULES.values():
            self.module_funcs.update(mod)
        for imp in self.program.imports:
            pass  # a sibling directory; its functions arrive via `externs` in a full build

        for it in self.program.items:
            if isinstance(it, Function):
                if it.name in self.funcs:
                    self.err(f"function {it.name!r} is defined more than once", it)
                self.funcs[it.name] = it
            elif not isinstance(it, Hook):     # a top-level statement
                if not self.is_app:
                    self.err("only app.w may contain top-level statements", it)

        for it in self.program.items:
            if isinstance(it, Hook):
                self.check_contract(it)

    def check_contract(self, hook):
        kinds = {k for _, k in hook.targets}
        if len(kinds) > 1:
            self.err("a hook must be all ':before' or all ':after', not a mix", hook)
        kind = hook.targets[0][1]
        param_lists = []
        for (fname, _) in hook.targets:
            if fname not in self.funcs:
                if fname in BUILTINS or fname in ALL_MODULE_FUNCS:
                    self.err(f"cannot attach a contract to the builtin/module function {fname!r}", hook)
                self.err(f"contract names unknown function {fname!r}", hook)
            param_lists.append(tuple(self.funcs[fname].params))
            table = self.before_of if kind == "before" else self.after_of
            if fname in table:
                self.err(f"function {fname!r} already has a :{kind} hook", hook)
            table[fname] = hook
        if len(set(param_lists)) > 1:
            self.err("functions sharing a hook must have identical parameters", hook)

    # --- pass 2: bodies ---
    def check_function(self, fn):
        scope = Scope()
        for p in fn.params:
            if p in scope.names:
                self.err(f"duplicate parameter {p!r} in {fn.name!r}", fn)
            scope.declare(p)
        if fn.name in self.after_of and "result" in fn.params:
            self.err(f"{fn.name!r} has an :after hook, so it may not have a parameter "
                     f"named 'result'", fn)
        self.fn_scope = scope
        self.check_block(fn.body, scope, 0, "function")
        self.fn_scope = None

    def check_hook(self, hook):
        kind = hook.targets[0][1]
        fn = self.funcs[hook.targets[0][0]]        # existence checked in pass 1
        scope = Scope()
        for p in fn.params:
            scope.declare(p)
        if kind == "after":
            scope.declare("result")                # the contextual name (§8.2)
        self.fn_scope = scope
        self.check_block(hook.body, scope, 0, "hook")
        self.fn_scope = None

    fn_scope = None

    def check_block(self, stmts, scope, loopd, ctx):
        for s in stmts:
            self.check_stmt(s, scope, loopd, ctx)

    def check_stmt(self, s, scope, loopd, ctx):
        if isinstance(s, Decl):
            self.check_expr(s.expr, scope)             # RHS is in scope before the new name
            if scope.resolve(s.name):
                self.err(f"{s.name!r} is already declared in this or an enclosing scope", s)
            scope.declare(s.name)
        elif isinstance(s, Assign):
            self.check_expr(s.expr, scope)             # RHS is in scope before any new name
            # `=` both declares and assigns (spec 5): there is one assignment
            # operator, and the first one to a name brings it into being. The
            # name goes into the function's scope, not the block's. word has no
            # block scope (spec 5.1), and codegen's collect_locals puts a whole
            # body in one frame, so the two have to agree.
            if isinstance(s.target, Name) and not scope.resolve(s.target.ident):
                (self.fn_scope or scope).declare(s.target.ident)
                scope.declare(s.target.ident)
            else:
                self.check_expr(s.target, scope)       # Name -> must resolve; Index -> base/index
        elif isinstance(s, If):
            self.check_expr(s.cond, scope)
            self.check_block(s.then, Scope(scope), loopd, ctx)
            if s.orelse is not None:
                self.check_block(s.orelse, Scope(scope), loopd, ctx)
        elif isinstance(s, Loop):
            if s.cond is not None:
                self.check_expr(s.cond, scope)
            self.check_block(s.body, Scope(scope), loopd + 1, ctx)
        elif isinstance(s, Return):
            if ctx == "hook" and s.expr is None:
                self.err("a hook's 'return' must carry a pass/fail value", s)
            if s.expr is not None:
                self.check_expr(s.expr, scope)
        elif isinstance(s, Break):
            if loopd == 0:
                self.err("'break' outside a loop", s)
        elif isinstance(s, ExprStmt):
            self.check_call(s.call, scope)

    # --- expressions ---
    def check_expr(self, e, scope):
        if isinstance(e, (Num, Str, Singleton)):
            return
        if isinstance(e, Name):
            if not scope.resolve(e.ident):
                self.err(f"unknown variable {e.ident!r}", e)
        elif isinstance(e, Unary):
            self.check_expr(e.operand, scope)
            if self.kind_of(e.operand) == REGION:
                self.err(f"number expected: '{e.op}' needs a number, but this is text", e.operand)
        elif isinstance(e, Binary):
            self.check_expr(e.left, scope)
            self.check_expr(e.right, scope)
            lk, rk = self.kind_of(e.left), self.kind_of(e.right)
            if e.op in NUMERIC_OPS:
                if lk == REGION:
                    self.err(f"number expected: '{e.op}' needs numbers, but the left side is text", e.left)
                if rk == REGION:
                    self.err(f"number expected: '{e.op}' needs numbers, but the right side is text", e.right)
            elif e.op in ORDER_OPS and {lk, rk} == {NUMBER, REGION}:
                self.err(f"cannot compare a number and text with '{e.op}' (use '==' to test equality)", e)
        elif isinstance(e, Index):
            self.check_expr(e.base, scope)
            self.check_expr(e.index, scope)
            if self.kind_of(e.base) == NUMBER:
                self.err("region expected: indexing '[...]' needs a region, but this is a number", e.base)
            # A text index is a map key (spec 3.7), not an error. m[k] and a[i]
            # are the same syntax, told apart by the key's kind.
        elif isinstance(e, Call):
            self.check_call(e, scope)

    def check_call(self, call, scope):
        for a in call.args:
            self.check_expr(a, scope)
        name, argc = call.name, len(call.args)
        if name in self.funcs:
            self.arity(call, name, len(self.funcs[name].params), "function")
        elif name in BUILTINS:
            if BUILTINS[name] < 0:
                # copy(p) / copy(p, start) / copy(p, start, end): one builtin,
                # three shapes (spec 9), so the table can't hold its arity.
                if not 1 <= argc <= 3:
                    self.err(f"{name!r} takes 1, 2 or 3 arguments, not {argc}", call)
            else:
                self.arity(call, name, BUILTINS[name], "builtin")
            if name in ("len", "slice") and self.kind_of(call.args[0]) == NUMBER:
                self.err(f"region expected: {name} needs a region, but this is a number", call.args[0])
        elif name in self.module_funcs:
            self.arity(call, name, self.module_funcs[name], "module function")
        elif name in self.externs:
            self.arity(call, name, self.externs[name], "function")
        elif name in ALL_MODULE_FUNCS:
            mod = ALL_MODULE_FUNCS[name]
            self.err(f"unknown function {name!r}, defined by module {mod!r}; "
                     f"add 'import {mod}' to app.w", call)
        else:
            self.err(f"unknown function {name!r}", call)

    def arity(self, call, name, expected, what):
        if len(call.args) != expected:
            plural = "" if expected == 1 else "s"
            self.err(f"{what} {name!r} expects {expected} argument{plural}, "
                     f"got {len(call.args)}", call)


def analyze_source(src, is_app=True):
    return Analyzer(Parser(Lexer(src).tokenize()).parse(), is_app=is_app).analyze()


SAMPLE = r'''import fs

add(a, b)
    return a + b

divide(a, b)
    return a / b

divide:before
    if b == 0
        return 0

sum(a)
    total := 0
    i := 0
    loop i < len(a)
        total = total + a[i]
        i = i + 1
    return total

nums := array(3)
nums[0] = 10
nums[1] = 20
nums[2] = 30
out(sum(nums) . "\n")

if divide(10, 2) > 4
    out("big\n")
else
    out("small\n")
'''


BROKEN = [
    ("unknown variable",        "out(x)\n"),
    ("arity mismatch",          "add(a)\n    return a\nadd(1, 2)\n"),
    ("break outside a loop",    "break\n"),
    ("number expected (text+1)","x := \"a\" + 1\n"),
    ("region expected (len n)", "x := len(5)\n"),
    ("order-compare num vs text","if 3 < \"x\"\n    out(\"?\")\n"),
    ("duplicate function",      "f()\n    return 1\nf()\n    return 2\n"),
    ("shadowing",               "x := 1\nx := 2\n"),
    ("mixed contract kinds",    "f(a)\n    return a\ng(a)\n    return a\nf:before, g:after\n    return 1\n"),
    ("mismatched hook params",  "f(a)\n    return a\ng(x, y)\n    return x\nf:before, g:before\n    return 1\n"),
    ("bare return in a hook",   "f(a)\n    return a\nf:before\n    return\n"),
]


def main():
    if len(sys.argv) > 1:
        with open(sys.argv[1], encoding="utf-8") as f:
            src = f.read()
        try:
            analyze_source(src)
            print(f"{sys.argv[1]}: OK, no errors")
        except (LexError, ParseError, AnalysisError) as e:
            print(f"{sys.argv[1]}:{e}", file=sys.stderr)
            sys.exit(1)
        return

    print("=== analyzing the sample (expect: clean) ===")
    analyze_source(SAMPLE)
    print("OK, the sample passes every check\n")

    print("=== deliberately broken snippets (each should be caught) ===")
    for why, src in BROKEN:
        try:
            analyze_source(src)
            print(f"  MISSED: {why}")
            sys.exit(1)
        except (LexError, ParseError, AnalysisError) as e:
            print(f"  {why:26}: {e}")
    print("\nall analyzer checks fire correctly")


if __name__ == "__main__":
    main()
