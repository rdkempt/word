#!/bin/sh
# test_encoder_vs_as.sh: the encoder oracle. Runs word's own assembler
# (`word asm`) over the one-instruction snippets in corpus.txt and
# net_corpus.txt and compares the encoded .text with GNU as. `as` is only a
# cross-check for development and CI; word never needs it to build or run.
# This replaced the Python-encoder differential tests (difftest.py and
# riptest.py).
#
# word's ELF has no section headers, but its .text always starts at file
# offset 4096. The W^X layout puts the 64-byte ELF header and four 56-byte
# program headers (R-X text, R-- rodata, RW data+bss, and PT_GNU_STACK, which
# loads nothing) on the first page and page-aligns .text to the second, and
# there's room for many more headers before that changes. We take L bytes
# there, where L is the length as gives the same instruction. rip- and
# label-relative forms depend on the whole program's layout (word resolves
# them and as leaves a relocation), so they're skipped, as the old difftest
# did.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}

if ! command -v as >/dev/null 2>&1 || ! command -v objcopy >/dev/null 2>&1; then
  echo "SKIP: GNU as/objcopy not on PATH (encoder oracle is dev/CI-only)"; exit 0
fi
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok=0; fail=0; skip=0
# relative-branch mnemonics whose bytes depend on layout (difftest's RELMN list)
rel=" call jmp loop jo jno jb jae je jz jne jnz jbe ja js jns jl jge jle jg jc jnc jp jpe jnp jpo "

check() {
  corpus="$1"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    mn=${line%% *}
    # Relative branches (call/jmp/jcc to a label) depend on layout, so they're
    # skipped. A memory-indirect call/jmp (the operand has '[') doesn't.
    case "$rel" in *" $mn "*) case "$line" in *"["*) ;; *) skip=$((skip+1)); continue;; esac;; esac
    case "$line" in *rip*|*"[."*) skip=$((skip+1)); continue;; esac
    printf '.intel_syntax noprefix\n.global _start\n.text\n_start:\n    %s\n' "$line" > "$tmp/s.s"
    if ! as "$tmp/s.s" -o "$tmp/as.o" 2>/dev/null; then skip=$((skip+1)); continue; fi
    objcopy -O binary -j .text "$tmp/as.o" "$tmp/as.bin" 2>/dev/null || { skip=$((skip+1)); continue; }
    L=$(wc -c < "$tmp/as.bin"); [ "$L" -gt 0 ] || { skip=$((skip+1)); continue; }
    if ! "$WORD" asm "$tmp/s.s" "$tmp/w.elf" >/dev/null 2>&1; then
      echo "  FAIL (word asm errored): $line"; fail=$((fail+1)); continue
    fi
    dd if="$tmp/w.elf" bs=1 skip=4096 count="$L" of="$tmp/w.bin" 2>/dev/null
    if cmp -s "$tmp/as.bin" "$tmp/w.bin"; then ok=$((ok+1)); else
      echo "  DIFF: $line  (as=$(od -An -tx1 "$tmp/as.bin" | tr -d ' \n') word=$(od -An -tx1 "$tmp/w.bin" | tr -d ' \n'))"
      fail=$((fail+1))
    fi
  done < "$corpus"
}

check "$here/corpus.txt"
check "$here/net_corpus.txt"

# Two diagnostics that used to be internal faults. Both linkers find the entry
# symbol by name, and a file with no `.global` left it unset, so a file that
# forgot the directive got a fault inside the compiler instead of a message
# about the input.
diag() { # name, source, expected substring
  printf '%b' "$2" > "$tmp/d.s"
  got=$("$WORD" asm "$tmp/d.s" "$tmp/d.out" 2>&1) && rc=0 || rc=$?
  case "$got" in
    *"$3"*) if [ "$rc" != 0 ]; then ok=$((ok+1)); echo "  ok: $1"
            else echo "  FAIL: $1 (right message, exit 0)"; fail=$((fail+1)); fi ;;
    *) echo "  FAIL: $1 -- got [$got]"; fail=$((fail+1)) ;;
  esac; }
diag "no .global at all reports it" \
  '.intel_syntax noprefix\n.text\nnop\n' "no entry symbol"
diag ".global naming a label that is not there reports it" \
  '.intel_syntax noprefix\n.global _start\n.text\nnop\n' "has no label"

# The refusal half. The corpus loop skips every line `as` refuses, so it never
# checks that word refuses them too, and each of these used to assemble as some
# other instruction and exit 0. `as` is asked first, so a line it now accepts
# shows up as a stale entry instead of a pass.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  printf '.intel_syntax noprefix\n.global _start\n.text\n_start:\n    %s\n' "$line" > "$tmp/r.s"
  if as "$tmp/r.s" -o "$tmp/r.o" 2>/dev/null; then
    echo "  FAIL (stale: as accepts it now): $line"; fail=$((fail+1)); continue
  fi
  rm -f "$tmp/r.out"
  wrc=0; "$WORD" asm "$tmp/r.s" "$tmp/r.out" > "$tmp/r.err" 2>&1 || wrc=$?
  if [ "$wrc" = 1 ] && [ ! -f "$tmp/r.out" ] && grep -q '^wasm: ' "$tmp/r.err"; then ok=$((ok+1))
  else echo "  FAIL (as refuses, word did not): $line  rc=$wrc $(head -1 "$tmp/r.err")"; fail=$((fail+1)); fi
done <<'EOF'
mov rax, [rbx+rcx*3]
mov rax, [rbx+0x100000000]
mov eax, rbx
add rax, 0x1ffffffff
and rax, 0x80000000
imul rax, rbx, 0x100000000
shl rax, 256
lea rax, rbx
push eax
movzx rax, rbx
mov [rax], 5
mov rax, 0x1ffffffffffffffff
mov rax, 1, 2
push rax, rbx
syscall rax
EOF

# Alignment padding, which the per-instruction corpus can't reach and a byte
# diff against as can't judge (as emits multi-byte nops, word repeats 0x90, and
# both are correct). What matters is that the fill can be executed: code
# usually falls through into an aligned label, and zero padding would be wrong,
# since a zero pair decodes as `add [rax], al`. So the program runs, and the
# exit code only arrives if the padding was run through.
printf '.intel_syntax noprefix\n.global _start\n.text\n_start:\n    nop\n    .balign 64\n    mov rax, 60\n    mov rdi, 7\n    syscall\n' > "$tmp/al.s"
if "$WORD" asm "$tmp/al.s" "$tmp/al.elf" >/dev/null 2>&1; then
  chmod +x "$tmp/al.elf"; rc=0; "$tmp/al.elf" || rc=$?     # exits 7, so set -e must not see it
  pad=$(dd if="$tmp/al.elf" bs=1 skip=4097 count=8 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if [ "$rc" = 7 ] && [ "$pad" = "9090909090909090" ]; then ok=$((ok+1))
  else echo "  FAIL: .balign in .text: exit $rc (want 7), padding [$pad] (want 90 x8)"; fail=$((fail+1)); fi
else echo "  FAIL (word asm errored): .balign 64 in .text"; fail=$((fail+1)); fi

echo "encoder vs as: OK=$ok FAIL=$fail SKIP(rel/rip/unassemblable)=$skip"
[ "$fail" = 0 ]
