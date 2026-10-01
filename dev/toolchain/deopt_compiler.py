#!/usr/bin/env python3
# deopt_compiler.py: write a copy of compiler/word.w with the optimiser's gates
# answering conservatively, for test_opt_differential.sh to build and compare
# against the release compiler.
#
# SPEC 3.4 and 3.5 say a program can't tell which of these optimizations fired.
# That's a claim about every program, and the way to check it is to run
# programs both ways. This makes the second way.
#
# Each gate is a predicate that already has a conservative answer written into
# it (the one it gives when its pass hasn't run), so the patches below pin the
# gate to that answer instead of deleting anything. The rest of each body stays:
# `word` rejects a function that is never called (SPEC 10.1), so an early
# `return` would orphan helpers the gate is the only caller of, and the patched
# compiler wouldn't build. Where a gate's last statement is the only call to a
# helper, the call is kept and its value thrown away instead.
#
# Every patch must apply exactly once. If a rename stops one from matching, this
# fails instead of producing a "deoptimised" compiler identical to the release
# one, which would let the whole suite pass while comparing a compiler with
# itself. test_opt_differential.sh also checks for that, by requiring the two
# compilers to emit different assembly for a program whose optimisations it can
# name.
import sys

PATCHES = [
    # The switch for the aliasing family: is_inplace_append, the dead-store
    # rewind (is_reclaim_store) and the float accumulator (is_float_acc) each
    # answer false when this does, so pinning it to false turns all three off
    # (SPEC 3.4, 3.5).
    ("uniqueness",
     "is_local_unique(cg, name)\n"
     "    sh = cg[15]\n"
     "    if sh == 0\n"
     "        return false\n"
     "    if has(sh, name)\n"
     "        return false\n"
     "    return true\n",
     "is_local_unique(cg, name)\n"
     "    sh = cg[15]\n"
     "    if sh == 0\n"
     "        return false\n"
     "    if has(sh, name)\n"
     "        return false\n"
     "    return false\n"),

    # Bounds-check elimination: the subscript a loop guard already checked.
    # `&& false` pins the answer and leaves the call to elide_key in place.
    ("bounds elimination",
     "    return has(cg[52], elide_key(base[1], idx[1]))\n",
     "    return has(cg[52], elide_key(base[1], idx[1])) && false\n"),

    # Loop-invariant `len`. loop_len_hidden has no other caller, so the call
    # stays and a zero-length copy of its answer comes back, which is "", what
    # the caller reads as "this loop doesn't qualify".
    ("loop length hoisting",
     "    return loop_len_hidden(s)\n",
     "    return copy(loop_len_hidden(s), 0, 0)\n"),

    # Not in this list: is_float_local. It looks like a gate but it's the
    # storage decision for a float local, asked at eleven call sites, and
    # is_float_leaf asks the same question once more through local_kind().
    # Pinning it to false makes the compiler disagree with itself: the slot
    # still holds a raw double, and gen_float_leaf reads it as a tagged integer.
    # That's a bug in the patch, not in word, and the differential only means
    # something between two compilers that are each correct, which is why the
    # suite runs test_guarantees and test_builtins through the patched compiler
    # before it compares any generated program. The float accumulator is still
    # turned off here, through the uniqueness gate above.

    # u32 locals: integers proven to fit 32 bits, kept raw. The pass still
    # runs, and the caller installs no table, as in a program with floats.
    ("u32 locals",
     "    ch = 1\n"
     "    loop ch == 1\n"
     "        ch = u32_pass(cg, tbl, body)\n"
     "    return tbl\n",
     "    ch = 1\n"
     "    loop ch == 1\n"
     "        ch = u32_pass(cg, tbl, body)\n"
     "    return 0\n"),

    # The rotate idiom and the funnel shift. rot_lamt answers 0, so no rotate is
    # taken anywhere, the masked form and gen_u32 included, and funnel_parts
    # answers 0. funnel_arm has no other caller, so both its calls stay.
    ("rotate idiom",
     "    if a[1] == \"<<\"\n"
     "        return a[3][1]\n"
     "    return b[3][1]\n",
     "    if a[1] == \"<<\"\n"
     "        return 0\n"
     "    return 0\n"),
    ("funnel shift",
     "    r = funnel_arm(e[2], e[3])\n"
     "    if r != 0\n"
     "        return r\n"
     "    return funnel_arm(e[3], e[2])\n",
     "    r = funnel_arm(e[2], e[3])\n"
     "    if r != 0\n"
     "        return 0\n"
     "    funnel_arm(e[3], e[2])\n"
     "    return 0\n"),

    # Inlining a one-line accessor. inl_subst has no other caller, and its calls
    # to itself do not make it used (SPEC 10.1), so the call stays as a
    # statement and the answer is the conservative one.
    ("inlining",
     "    return inl_subst(ent[1], ps, args)\n",
     "    inl_subst(ent[1], ps, args)\n"
     "    return 0\n"),

    # Pinning a function's hottest integers to registers.
    ("register pinning",
     "    rz = cg[34]\n"
     "    if rz != 0\n"
     "        if has(rz[1], name)\n"
     "            return false\n"
     "    return true\n",
     "    rz = cg[34]\n"
     "    if rz != 0\n"
     "        if has(rz[1], name)\n"
     "            return false\n"
     "    return false\n"),

    # Reclaiming a temporary the expression owns across a call.
    ("owned-temp reclaim",
     "is_owned_temp(cg, e)\n"
     "    if is_owned_join(e)\n"
     "        return 1\n"
     "    return is_fresh_region_call(cg, e)\n",
     "is_owned_temp(cg, e)\n"
     "    if is_owned_join(e)\n"
     "        return 0\n"
     "    if is_fresh_region_call(cg, e) == 1\n"
     "        return 0\n"
     "    return 0\n"),

    # Pinning a function's hottest raw-double locals to xmm8-xmm15.
    ("float register pinning",
     "    rz = cg[34]\n"
     "    if rz == 0\n"
     "        return true\n"
     "    return !has(rz[1], name)\n",
     "    rz = cg[34]\n"
     "    if rz == 0\n"
     "        return false\n"
     "    return !has(rz[1], name) && false\n"),

    # A float chain built in its destination register: a pinned local's own, or
    # xmm1 for the right side of a pair.
    ("float destination (store)",
     "    if is_xmm_home(h) && float_chain(cg, rhs) && !expr_mentions(rhs, name)\n",
     "    if is_xmm_home(h) && float_chain(cg, rhs) && !expr_mentions(rhs, name) && false\n"),
    ("float destination (pair)",
     "    if float_chain(cg, e[3])\n"
     "        gen_float_expr(cg, e[2])\n",
     "    if float_chain(cg, e[3]) && false\n"
     "        gen_float_expr(cg, e[2])\n"),

    # A leading `if <param> < k / return ...` answered before the frame exists.
    # Declined at the first operand, after the helper that reads it has run.
    ("frameless guard",
     "    la = fg_int_param(cg, params, c[2])\n"
     "    if len(la) == 0\n"
     "        return 0\n",
     "    la = fg_int_param(cg, params, c[2])\n"
     "    if len(la) == 0 || true\n"
     "        return 0\n"),

    # `i = i + 1` on a pinned local as one `add` on its register.
    ("pinned step",
     "    h = env_lookup(cg, name)\n"
     "    if !is_gpr_home(h)\n"
     "        return 0\n",
     "    h = env_lookup(cg, name)\n"
     "    if !is_gpr_home(h) || true\n"
     "        return 0\n"),

    # A pinned local compared in its own register rather than copied to rax.
    ("pinned compare",
     "            if is_gpr_home(h)\n"
     "                return h\n",
     "            if is_gpr_home(h) && false\n"
     "                return h\n"),

    # A u32 loop bound on the right, compared with the left local in place.
    ("u32 bound compare",
     "            if cond[3][0] == 13 && is_u32_local(cg, cond[3][1]) == 1 && cond[2][0] == 13 && is_leaf_operand(cg, cond[2])\n",
     "            if cond[3][0] == 13 && is_u32_local(cg, cond[3][1]) == 1 && cond[2][0] == 13 && is_leaf_operand(cg, cond[2]) && false\n"),

    # `&&` and `||` in a condition branching on each side rather than building
    # the boolean first; both backends.
    ("condition logic (x86-64)",
     "    if cond[0] == 14 && cond[1] == \"&&\"\n"
     "        gen_cond_jump(cg, cond[2], target)\n",
     "    if cond[0] == 14 && cond[1] == \"&&\" && false\n"
     "        gen_cond_jump(cg, cond[2], target)\n"),
    ("condition logic (x86-64, or)",
     "    if cond[0] == 14 && cond[1] == \"||\"\n"
     "        rightl = new_label(cg)\n",
     "    if cond[0] == 14 && cond[1] == \"||\" && false\n"
     "        rightl = new_label(cg)\n"),
    ("condition logic (arm64)",
     "    if cond[0] == 14 && cond[1] == \"&&\"\n"
     "        a64_cond_jump(cg, cond[2], target)\n",
     "    if cond[0] == 14 && cond[1] == \"&&\" && false\n"
     "        a64_cond_jump(cg, cond[2], target)\n"),
    ("condition logic (arm64, or)",
     "    if cond[0] == 14 && cond[1] == \"||\"\n"
     "        rightl = a64_lbl(cg)\n",
     "    if cond[0] == 14 && cond[1] == \"||\" && false\n"
     "        rightl = a64_lbl(cg)\n"),
    ("condition logic (line stores)",
     "        if e[1] == \"&&\" || e[1] == \"||\"\n"
     "            fault_scan(cg, e[2], acc)\n",
     "        if (e[1] == \"&&\" || e[1] == \"||\") && false\n"
     "            fault_scan(cg, e[2], acc)\n"),
    ("condition not (x86-64)",
     "    if cond[0] == 15 && cond[1] == \"!\"\n"
     "        inv = cmp_inverted(cg, cond[2])\n"
     "        if inv != 0\n"
     "            gen_cond_jump(cg, inv, target)\n",
     "    if cond[0] == 15 && cond[1] == \"!\" && false\n"
     "        inv = cmp_inverted(cg, cond[2])\n"
     "        if inv != 0\n"
     "            gen_cond_jump(cg, inv, target)\n"),
    ("condition not (arm64)",
     "    if cond[0] == 15 && cond[1] == \"!\"\n"
     "        inv = cmp_inverted(cg, cond[2])\n"
     "        if inv != 0\n"
     "            a64_cond_jump(cg, inv, target)\n",
     "    if cond[0] == 15 && cond[1] == \"!\" && false\n"
     "        inv = cmp_inverted(cg, cond[2])\n"
     "        if inv != 0\n"
     "            a64_cond_jump(cg, inv, target)\n"),

    # An `if` with no else leaving out the jump to its own next instruction;
    # pinned to always emitting it, on both targets.
    ("if without else (x86-64)",
     "    if s[3] != 0\n"
     "        asmput(\"    jmp \" . endl)\n",
     "    if s[3] != 0 || true\n"
     "        asmput(\"    jmp \" . endl)\n"),
    ("if without else (arm64)",
     "    if s[3] != 0\n"
     "        asmput(\"    b \" . endl)\n",
     "    if s[3] != 0 || true\n"
     "        asmput(\"    b \" . endl)\n"),

    # The arm64 operand pair loading a leaf right operand straight into x1.
    ("arm64 leaf pair",
     "    if a64_pair_leaf(e[3])\n"
     "        a64_gen_expr(cg, e[2])\n",
     "    if a64_pair_leaf(e[3]) && false\n"
     "        a64_gen_expr(cg, e[2])\n"),

    # sort(): the all-integers path (the radix sort, and the all-equal answer)
    # and the inline compare of two integers in the merge, on both targets.
    ("sort integer path (x86-64)",
     "    asmput(\"    test r15, 1\")\n"
     "    asmput(\"    jz .sort_general\")\n",
     "    asmput(\"    test r15, 1\")\n"
     "    asmput(\"    jmp .sort_general\")\n"),
    ("sort inline compare (x86-64)",
     "    asmput(\"    jz .sort_ask\")\n",
     "    asmput(\"    jmp .sort_ask\")\n"),
    ("sort integer path (arm64)",
     "    asmput(\"    tst x12, #1\")\n"
     "    asmput(\"    b.eq .st_general\")\n",
     "    asmput(\"    tst x12, #1\")\n"
     "    asmput(\"    b .st_general\")\n"),
    ("sort inline compare (arm64)",
     "    asmput(\"    b.eq .st_ask\")\n",
     "    asmput(\"    b .st_ask\")\n"),

    # A map probe turning away a slot whose stored hash differs, without
    # comparing the keys: pinned to "the hashes match", so every occupied slot
    # it lands on is compared as text, as before. Both targets.
    ("map hash reject (x86-64)",
     "    asmput(\"    cmp r10, [rsp]\")\n"
     "    asmput(\"    jne .mf_next\")\n",
     "    asmput(\"    cmp r10, r10\")\n"
     "    asmput(\"    jne .mf_next\")\n"),
    ("map hash reject (arm64)",
     "        asmput(\"    cmp x9, x25\")\n"
     "        asmput(\"    b.ne .mf_next\")\n",
     "        asmput(\"    cmp x9, x9\")\n"
     "        asmput(\"    b.ne .mf_next\")\n"),
]


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: deopt_compiler.py <compiler/word.w> <out.w>")
    src = open(sys.argv[1], encoding="utf-8").read()
    for name, old, new in PATCHES:
        n = src.count(old)
        if n != 1:
            sys.exit("deopt_compiler: the '%s' gate matched %d times, want 1.\n"
                     "The compiler moved; update the patch rather than dropping it, or the\n"
                     "differential compares the release compiler with itself.\n"
                     "  wanted: %s" % (name, n, old.split("\n")[0]))
        src = src.replace(old, new, 1)
    with open(sys.argv[2], "w", newline="\n", encoding="utf-8") as f:
        f.write(src)
    print("deopt_compiler: %d gates pinned" % len(PATCHES))


if __name__ == "__main__":
    main()
