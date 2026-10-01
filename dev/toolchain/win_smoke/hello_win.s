.intel_syntax noprefix
# Minimal hand-written Windows program: GetStdHandle(STD_OUTPUT) + WriteFile +
# ExitProcess, all via kernel32 imports the PE backend resolves. Used by
# dev/toolchain/test_win_pe.sh to smoke-test `word asm -win`.
.global _start
.text
_start:
    and rsp, -16                     # 16-align (PE entry stack alignment is unspecified)
    sub rsp, 48                      # shadow(32) + 5th-arg slot(8) + pad; stays 16-aligned
    mov rcx, -11                     # STD_OUTPUT_HANDLE
    call qword ptr [rip+GetStdHandle]
    mov rcx, rax                     # hFile
    lea rdx, [rip+msg]               # lpBuffer
    mov r8, 13                       # nNumberOfBytesToWrite
    lea r9, [rip+nwrote]             # lpNumberOfBytesWritten
    mov qword ptr [rsp+32], 0        # lpOverlapped = NULL (5th arg)
    call qword ptr [rip+WriteFile]
    mov rcx, 0
    call qword ptr [rip+ExitProcess]
.section .data
msg: .ascii "Hello, word!\n"
nwrote: .quad 0
