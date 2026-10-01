#!/usr/bin/env python3
# gen_opt_programs.py: generate word programs that put the optimiser's
# assumptions next to each other.
#
# The hand-written optimiser tests each pin one invariant: this append isn't
# rewritten, that bounds check isn't dropped, this length is hoisted. Breaking
# any one pass makes them fail. What they don't reach is how the passes
# interact (aliasing across a call, an alias made through a nested container,
# a map key that's also a loop subject, a float accumulator inside a call the
# inliner wants, a u32 local that overflows), because writing those by hand
# means guessing which pair matters.
#
# So these are generated, and judged by comparison: test_opt_differential.sh
# compiles each program with the release compiler and with one whose optimiser
# gates are patched to their conservative answers, and wants the same output
# and the same exit status from both. Nothing here needs an expected answer
# written down, so there can be thousands of them.
#
# Every program is:
#   * deterministic: no random(), no clock, no I/O, no net;
#   * terminating: every loop walks an array that doesn't grow, or a map's keys;
#   * legal: every local is read and every helper is called (SPEC 10.1 makes
#     both errors), and every index is in range by construction or out of range
#     on purpose;
#   * allowed to fault. A fault can be compared like any other outcome: both
#     compilers get the same file, so the located message and exit 70 have to
#     match too. Writing into a map key is one (SPEC 3.7).
#
# Usage: gen_opt_programs.py <seed> <out.w>
import random
import sys

# Integers with bits above bit 31, or negative, for the rotate and funnel
# shapes. Their 32-bit instructions are only right when the operand fits in 32
# bits, so these are the values that tell a sound use from an unsound one.
WIDE = ["4278190080", "4294967295", "2147483648", "1099511627781", "305419896",
        "72057594037927935", "2305843009213693951", "0 - 2", "0 - 4278190080", "3"]


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.lines = []
        self.helpers = set()
        self.ints = []
        self.floats = []
        self.texts = []
        self.arrays = []
        self.maps = []
        # Arrays whose elements are all still numbers. An array that has been
        # given a region (a nested array, or a text stored into it) leaves this
        # list, because the accumulating shapes below add their elements up, and
        # adding a region is a fault (SPEC 10.2). The fault would be
        # deterministic, so it could be compared, but it would end the program
        # early and leave less to compare.
        self.clean = []
        self.keyed = []
        # Integers kept away from the arithmetic shapes, which would overflow on
        # them, and the locals the rotate shapes write.
        self.wides = []
        self.rots = []
        self.n = 0

    # --- plumbing --------------------------------------------------------
    def name(self, pre):
        self.n += 1
        return "%s%d" % (pre, self.n)

    def emit(self, line, indent=0):
        self.lines.append("    " * indent + line)

    def pick(self, pool):
        return self.r.choice(pool)

    def soil(self, a):
        # This array is about to hold something that is not a number.
        if a in self.clean:
            self.clean.remove(a)

    # --- seeds -----------------------------------------------------------
    def seed_int(self):
        v = self.name("n")
        self.emit("%s = %d" % (v, self.r.randint(0, 40)))
        self.ints.append(v)
        return v

    def seed_wide(self):
        v = self.name("n")
        self.emit("%s = %s" % (v, self.pick(WIDE)))
        self.wides.append(v)
        return v

    def seed_float(self):
        v = self.name("f")
        self.emit("%s = %d.%d" % (v, self.r.randint(0, 9), self.r.randint(1, 9)))
        self.floats.append(v)
        return v

    def seed_text(self):
        v = self.name("t")
        # A join always allocates, so this is a fresh, unaliased region, the
        # shape the uniqueness pass is allowed to rewrite in place.
        self.emit('%s = "" . "%s"' % (v, "abcdefgh"[: self.r.randint(1, 8)]))
        self.texts.append(v)
        return v

    def seed_array(self):
        v = self.name("a")
        k = self.r.randint(1, 4)
        self.emit("%s = array(%d)" % (v, k))
        for i in range(k):
            self.emit("%s[%d] = %d" % (v, i, self.r.randint(0, 20)))
        self.arrays.append(v)
        self.clean.append(v)
        return v

    def seed_map(self):
        v = self.name("m")
        self.emit("%s = {}" % v)
        self.maps.append(v)
        return v

    # --- the interactions ------------------------------------------------
    def op_append(self):
        t = self.pick(self.texts)
        self.emit('%s = %s . "%s"' % (t, t, "wxyz"[: self.r.randint(1, 4)]))

    def op_alias_then_append(self):
        # Two names for one region, then an append through one of them. The
        # append may only be in place if the pass saw the alias.
        t = self.pick(self.texts)
        u = self.name("t")
        self.emit("%s = %s" % (u, t))
        self.texts.append(u)
        self.emit('%s = %s . "%s"' % (t, t, "pq"[: self.r.randint(1, 2)]))

    def op_alias_through_call(self):
        # The alias is made inside a callee, so only the interprocedural half
        # of the pass can see it.
        self.helpers.add("keep")
        t = self.pick(self.texts)
        u = self.name("t")
        self.emit("%s = keep(%s)" % (u, t))
        self.texts.append(u)
        self.emit('%s = %s . "k"' % (t, t))

    def op_alias_in_container(self):
        # The only reference left is inside an array, which a per-name
        # analysis can't see.
        a = self.pick(self.arrays)
        t = self.pick(self.texts)
        self.soil(a)
        self.emit("%s[0] = %s" % (a, t))
        self.emit('%s = %s . "c"' % (t, t))

    def op_map_key(self):
        # A map keeps the key region and indexes it by content (SPEC 3.7), so
        # the key is read-only afterwards, including through keys().
        m = self.pick(self.maps)
        t = self.pick(self.texts)
        self.emit("%s[%s] = %d" % (m, t, self.r.randint(0, 9)))
        self.keyed.append(t)
        if self.r.random() < 0.35:
            # An append to the name that spelled the key. That's legal, and the
            # map's key must not change with it.
            self.emit('%s = %s . "s"' % (t, t))

    def op_map_keys_loop(self):
        m = self.pick(self.maps)
        t = self.pick(self.texts)
        k = self.name("t")
        self.emit("%s = \"\"" % k)
        self.texts.append(k)
        self.emit("loop %s in keys(%s)" % (self.name("k"), m))
        self.emit("%s = %s . \"|\"" % (k, k), 1)
        self.emit("%s = %s . %s" % (t, t, k))

    def op_bounds_loop(self):
        # The loop guard already checks this subscript, which lets the
        # per-element check go, unless the body changes the subject.
        if not self.clean:
            return
        a = self.pick(self.clean)
        n = self.pick(self.ints)
        self.emit("%s = 0" % n)
        i = self.name("i")
        self.emit("%s = 0" % i)
        self.ints.append(i)
        self.emit("loop %s < len(%s)" % (i, a))
        self.emit("%s = %s + %s[%s]" % (n, n, a, i), 1)
        if self.r.random() < 0.35:
            # Changing the loop's own subject, which is the case the elision
            # has to survive. Growing it isn't generated: `.` on an
            # array-marked region renders it as JSON (SPEC 3.7), so the subject
            # would become text that doubles every pass, and the loop would
            # never end.
            self.emit("%s[%s] = %s" % (a, i, n), 1)
        self.emit("%s = %s + 1" % (i, i), 1)

    def op_index_store(self):
        # Always in range: element 0 exists in every array this generates. The
        # out-of-range write is one of the hazards at the end instead, so it
        # can't cut the program short and leave less to compare.
        a = self.pick(self.arrays)
        n = self.pick(self.ints)
        self.emit("%s[0] = %s" % (a, n))

    def op_nested(self):
        a = self.pick(self.arrays)
        self.soil(a)
        self.emit("%s[0] = array(2)" % a)
        self.emit("%s[0][1] = %d" % (a, self.r.randint(0, 9)))
        if self.r.random() < 0.4 and self.texts:
            t = self.pick(self.texts)
            self.emit("%s[0][0] = %s" % (a, t))
            self.emit('%s = %s . "n"' % (t, t))

    def op_float_acc(self):
        # x = x <op> ... on a unique float local writes into the box it holds.
        if not self.floats:
            return
        f = self.pick(self.floats)
        op = self.pick(["+", "-", "*"])
        self.emit("%s = %s %s %d.%d" % (f, f, op, self.r.randint(0, 3), self.r.randint(1, 9)))

    def op_float_call(self):
        # A float that only crosses a call is never boxed, unless it escapes.
        if not self.floats:
            return
        self.helpers.add("fmix")
        f = self.pick(self.floats)
        self.emit("%s = fmix(%s, %d.%d)" % (f, f, self.r.randint(1, 4), self.r.randint(1, 9)))

    def op_u32(self):
        # Every assignment lands in [0, 2^32), so the local is kept raw, until
        # one doesn't and the pass has to demote it. The mask is what the pass
        # recognizes. `%` would land in the same range, but it isn't a shape the
        # pass knows, so a `%` here never made a raw local at all.
        n = self.pick(self.ints)
        self.emit("%s = (%s * %d) & 4294967295" % (n, n, self.r.choice([31, 131, 2654435761])))

    def op_rotate(self):
        # The rotate idiom and the funnel shift, masked and not, on operands
        # that fit in 32 bits and on ones that don't. The target is a fresh
        # local or one an earlier rotate wrote, so a masked rotate can make it
        # a raw u32 local and a later unmasked one has to demote it.
        pool = self.ints + self.wides + self.rots
        x = self.pick(pool)
        y = self.pick(pool)
        L = self.r.randint(1, 31)
        rot = self.pick(["(%s << %d) | (%s >> %d)" % (x, L, x, 32 - L),
                         "(%s >> %d) | (%s << %d)" % (x, 32 - L, x, L)])
        k = self.r.randint(1, 31)
        fun = "(%s >> %d) | ((%s & %d) << %d)" % (x, k, y, (1 << k) - 1, 32 - k)
        s = self.r.random()
        if s < 0.3:
            rhs = "(%s) & 4294967295" % rot
        elif s < 0.5:
            rhs = rot
        elif s < 0.65:
            rhs = fun
        elif s < 0.75:
            rhs = "(%s) & 4294967295" % fun
        else:
            # SHA-256's shape: rotates xor'd together, one mask for all of them.
            L2 = self.r.randint(1, 31)
            rhs = "((%s) ^ ((%s >> %d) | (%s << %d)) ^ (%s >> %d)) & 4294967295" % (
                rot, x, 32 - L2, x, L2, x, self.r.randint(1, 31))
        if self.rots and self.r.random() < 0.5:
            t = self.pick(self.rots)
        else:
            t = self.name("w")
            self.rots.append(t)
        self.emit("%s = %s" % (t, rhs))

    def op_rotate_call(self):
        # The same shapes on a parameter, which is never a raw u32 local, in a
        # function too long to be inlined.
        self.helpers.add("rotf")
        x = self.pick(self.ints + self.wides + self.rots)
        t = self.name("w")
        self.rots.append(t)
        self.emit("%s = rotf(%s)" % (t, x))

    def op_call(self):
        if not self.clean:
            return
        self.helpers.add("sumreg")
        a = self.pick(self.clean)
        n = self.pick(self.ints)
        self.emit("%s = sumreg(%s)" % (n, a))

    def op_inline_call(self):
        # A one-line accessor is what the inliner takes.
        if not self.clean:
            return
        self.helpers.add("first")
        a = self.pick(self.clean)
        n = self.pick(self.ints)
        self.emit("%s = first(%s)" % (n, a))

    def op_sort_copy(self):
        # Only over a clean array: sort orders the elements, and ordering a
        # number against a region is a fault (SPEC 3.3) that would end the
        # program there instead of at the end.
        if not self.clean:
            return
        a = self.pick(self.clean)
        b = self.name("a")
        self.emit("%s = sort(copy(%s))" % (b, a))
        self.arrays.append(b)
        self.clean.append(b)

    def op_slice(self):
        t = self.pick(self.texts)
        u = self.name("t")
        self.emit("%s = copy(%s, 0, 1)" % (u, t))
        self.texts.append(u)

    # --- the program -----------------------------------------------------
    def build(self):
        for _ in range(self.r.randint(1, 3)):
            self.seed_int()
        for _ in range(self.r.randint(0, 2)):
            self.seed_wide()
        # About half the programs have no float anywhere. The u32 locals and
        # the rotate idiom only run in a program with no float in it, so
        # without this half the differential never reached them.
        if self.r.random() < 0.5:
            for _ in range(self.r.randint(1, 2)):
                self.seed_float()
        for _ in range(self.r.randint(1, 3)):
            self.seed_text()
        for _ in range(self.r.randint(1, 2)):
            self.seed_array()
        self.seed_map()

        ops = [
            self.op_append, self.op_alias_then_append, self.op_alias_through_call,
            self.op_alias_in_container, self.op_map_key, self.op_map_keys_loop,
            self.op_bounds_loop, self.op_index_store, self.op_nested,
            self.op_float_acc, self.op_float_call, self.op_u32,
            self.op_call, self.op_inline_call, self.op_sort_copy, self.op_slice,
            self.op_rotate, self.op_rotate, self.op_rotate_call,
        ]
        for _ in range(self.r.randint(4, 14)):
            self.pick(ops)()

        # Read every live name, so none is an unread binding and every one of
        # them is part of the answer being compared.
        for v in self.ints + self.wides + self.rots + self.floats + self.texts + self.arrays + self.maps:
            self.emit("out(%s)" % v)

        # A hazard goes after the printing, so the whole state is compared and
        # then the located fault too. Both compilers get the same file, so the
        # message and exit 70 have to agree.
        hz = self.r.random()
        if hz < 0.10:
            self.emit("%s[%d] = 1" % (self.pick(self.arrays), self.r.randint(40, 90)))
        elif hz < 0.20 and self.keyed:
            self.emit("%s[0] = 'z'" % self.pick(self.keyed))
        elif hz < 0.28:
            n = self.pick(self.ints)
            self.emit("%s = %s + 2305843009213693000" % (n, n))
            self.emit("out(%s)" % n)
        elif hz < 0.34:
            self.emit("out(%s / 0)" % self.pick(self.ints))

    def source(self):
        self.build()
        head = []
        if "keep" in self.helpers:
            head += ["keep(v)", "    return v", ""]
        if "fmix" in self.helpers:
            head += ["fmix(x, y)", "    z = x * y", "    return z + 1.0", ""]
        if "sumreg" in self.helpers:
            head += ["sumreg(r)", "    t = 0", "    i = 0", "    loop i < len(r)",
                     "        t = t + r[i]", "        i = i + 1", "    return t", ""]
        if "first" in self.helpers:
            head += ["first(r)", "    return r[0]", ""]
        if "rotf" in self.helpers:
            head += ["rotf(x)", "    y = ((x << 13) | (x >> 19)) & 4294967295",
                     "    z = (x >> 5) | ((x & 31) << 27)", "    return (y ^ z) | ((x << 7) | (x >> 25))", ""]
        return "\n".join(head + self.lines) + "\n"


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: gen_opt_programs.py <seed> <out.w>")
    src = Gen(int(sys.argv[1])).source()
    with open(sys.argv[2], "w", newline="\n") as f:
        f.write(src)


if __name__ == "__main__":
    main()
