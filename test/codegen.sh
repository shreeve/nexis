#!/bin/sh
# test/codegen.sh TRIPLE BINARY: the codegen check of docs/VM.md §8.
# No fast dispatch handler (`vm.VM.fast*`) in BINARY, a release build,
# may call anything, and on arm64 none may keep a stack frame: no
# instruction of it may name the stack pointer. On x86-64, whose
# System V convention leaves a handler nine scratch registers, four of
# them its arguments, a handler may save registers it needs past those
# with push and pop, which the table counts, but may reserve no stack
# and address none. It prints each handler's size in instructions
# (without the padding after it) and fails, listing the offending
# instructions, when one breaks the rule or when the handlers cannot be
# found. It then lists, for information only, what the out-of-line
# parts a fast handler goes on to (`callLeaf`, `callBuffered`,
# `callLookup`, `lookupPart`, `batchNext`, `collectThen`) save: pushes
# on x86-64, callee-saved registers stored to the stack on arm64. It
# needs an LLVM objdump (llvm-objdump, or the objdump of
# Xcode's tools), which reads every target's binaries; without one it
# says so and passes.
set -eu
triple=$1
bin=$2
od=
for c in llvm-objdump objdump; do
  if command -v "$c" >/dev/null 2>&1 && "$c" --version 2>/dev/null | grep -q LLVM; then
    od=$c
    break
  fi
done
if [ -z "$od" ]; then
  echo "codegen $triple: skipped, no LLVM objdump on PATH"
  exit 0
fi
case $triple in
  x86_64*) rule='(^|[^a-z])(call[a-z]*|enter[a-z]*)([[:space:]]|$)|[^%a-z](sub|add|lea)[a-z]*[[:space:]].*%rsp|\(%rsp\)' ;;
  *) rule='(^|[^a-z0-9])(sp|wsp)([^a-z0-9]|$)|^[[:space:]]*(bl|blr|blraa[a-z]*)([[:space:]]|$)' ;;
esac
syms=$("$od" --syms "$bin" | awk '{ print $NF }' | grep -E '^_?vm\.VM\.fast' | sort -u)
count=$(printf '%s\n' "$syms" | grep -c . || true)
if [ "$count" -lt 20 ]; then
  echo "codegen $triple: $count fast handlers in $bin, expected at least 20" >&2
  exit 1
fi
# The instructions of symbol $1 alone: no address, no symbol or
# comment that could spell a register.
disassemble() {
  "$od" -d --no-show-raw-insn --disassemble-symbols="$1" "$bin" |
    grep -E '^ *[0-9a-f]+:' | sed -e 's/^ *[0-9a-f]*://' -e 's/<[^>]*>//g' -e 's/ ; .*$//' -e 's/ # .*$//'
}
# Its size in instructions, without the padding after it.
size() { printf '%s\n' "$1" | grep -cvE '^[[:space:]]*(nop|udf|int3)' || true; }
failed=0
for s in $syms; do
  code=$(disassemble "$s")
  n=$(size "$code")
  pushes=$(printf '%s\n' "$code" | grep -cE '^[[:space:]]*push' || true)
  bad=$(printf '%s\n' "$code" | grep -E "$rule" || true)
  name=${s#_}
  if [ -n "$bad" ]; then
    failed=1
    echo "codegen $triple: $name keeps a frame or calls:" >&2
    printf '%s\n' "$bad" | sed 's/^/    /' >&2
  elif [ "$pushes" -gt 0 ]; then
    printf 'codegen %s: %-36s %4d instructions, %d saved\n' "$triple" "$name" "$n" "$pushes"
  else
    printf 'codegen %s: %-36s %4d instructions\n' "$triple" "$name" "$n"
  fi
done
parts=$("$od" --syms "$bin" | awk '{ print $NF }' |
  grep -E '^_?vm\.VM\.(callLeaf|callBuffered|callLookup|lookupPart|collectThen|batchNext.*\.run)$' | sort -u || true)
for s in $parts; do
  code=$(disassemble "$s")
  n=$(size "$code")
  case $triple in
    x86_64*) saved=$(printf '%s\n' "$code" | grep -cE '^[[:space:]]*push' || true) ;;
    *) saved=$(printf '%s\n' "$code" | grep -E '^[[:space:]]*(stp|str)[[:space:]].*\[sp' |
      grep -oE '(^|[^a-z0-9])(x19|x2[0-9]|x30|d[89]|d1[0-5]|fp|lr)([^a-z0-9]|$)' | grep -c . || true) ;;
  esac
  printf 'codegen %s: %-36s %4d instructions, %d saved (out of line)\n' "$triple" "${s#_}" "$n" "$saved"
done
exit $failed
