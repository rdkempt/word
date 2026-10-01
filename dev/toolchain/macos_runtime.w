// macos_runtime.w: what the macOS CI runner runs after hello world.
//
// hello only reaches write, mmap and exit, which m_syscall renumbers (and for
// mmap, moves one flag bit). This one reaches the calls that need real
// translation:
//
//   openat    AT_FDCWD is -100 on Linux and -2 on Darwin, and O_CREAT, O_TRUNC
//             and O_APPEND all moved
//   fstat64   st_size sits at offset 96, not 48
//   renameat  AT_FDCWD again, twice
//   clock     Darwin has no clock_gettime syscall; gettimeofday reports
//             microseconds and takes its buffer as the first argument
//   rlimit    prlimit64(pid, res, new, old) becomes getrlimit(res, rlp)
//   entropy   getrandom(buf, len, flags) becomes getentropy(buf, len)
//   sigaction write() ignores SIGXFSZ while it writes, and Darwin lays the
//             action out differently
//
// and args(), which tests the LC_MAIN entry convention: dyld passes argc and
// argv in registers instead of leaving &argc on the stack.
//
// The expected output is the same on Linux, and CI compares the Mac's output
// with it.
p = "/tmp/word-mac-a.txt"
q = "/tmp/word-mac-b.txt"
if !write(p, "line one\nline two\n")
    out("FAIL write")
out("read " . len(read(p)))
if !rename(p, q)
    out("FAIL rename")
out("moved " . len(read(q)))
out("now " . (now() > 0))
out("rand " . (random() >= 0))
out("args " . len(args()))
