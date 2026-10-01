#!/usr/bin/env python3
# nogetrandom.py <program> [args...]: run a program with getrandom(2) failing.
#
# A seccomp filter answers every getrandom call with an error (ENOSYS, or the
# errno in NOGR_ERRNO) and allows everything else, and the program is exec'd
# under it. That's how an old kernel, or a sandbox that denies the call, looks
# from inside, so a test can watch a caller of the OS entropy source meet a
# failure. test_random.sh uses it; Linux only. Under qemu-user the filter
# applies to the call qemu makes for the program, so the same launcher works
# for the arm64 build.
import ctypes
import errno
import os
import platform
import struct
import sys

NR = {"x86_64": 318, "aarch64": 278}

PR_SET_NO_NEW_PRIVS = 38
PR_SET_SECCOMP = 22
SECCOMP_MODE_FILTER = 2
SECCOMP_RET_ERRNO = 0x00050000
SECCOMP_RET_ALLOW = 0x7FFF0000
BPF_LD_W_ABS = 0x00 | 0x00 | 0x20
BPF_JMP_JEQ_K = 0x05 | 0x10 | 0x00
BPF_RET_K = 0x06 | 0x00


class SockFprog(ctypes.Structure):
    _fields_ = [("len", ctypes.c_ushort), ("filter", ctypes.c_void_p)]


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: nogetrandom.py <program> [args...]\n")
        return 2
    nr = NR.get(platform.machine())
    if nr is None:
        sys.stderr.write("nogetrandom: no getrandom number for %s\n" % platform.machine())
        return 2
    err = int(os.environ.get("NOGR_ERRNO", errno.ENOSYS))
    # struct sock_filter { u16 code; u8 jt; u8 jf; u32 k; }, and seccomp_data
    # starts with the syscall number.
    prog = b"".join([
        struct.pack("HBBI", BPF_LD_W_ABS, 0, 0, 0),
        struct.pack("HBBI", BPF_JMP_JEQ_K, 0, 1, nr),
        struct.pack("HBBI", BPF_RET_K, 0, 0, SECCOMP_RET_ERRNO | (err & 0xFFFF)),
        struct.pack("HBBI", BPF_RET_K, 0, 0, SECCOMP_RET_ALLOW),
    ])
    buf = ctypes.create_string_buffer(prog, len(prog))
    fprog = SockFprog(len(prog) // 8, ctypes.cast(buf, ctypes.c_void_p))
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        sys.stderr.write("nogetrandom: PR_SET_NO_NEW_PRIVS failed\n")
        return 2
    if libc.prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, ctypes.byref(fprog), 0, 0) != 0:
        sys.stderr.write("nogetrandom: seccomp is not available here (errno %d)\n" % ctypes.get_errno())
        return 3
    os.execv(sys.argv[1], sys.argv[1:])


if __name__ == "__main__":
    sys.exit(main())
