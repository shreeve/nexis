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
# found. It needs an LLVM objdump (llvm-objdump, or the objdump of
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
failed=0
for s in $syms; do
  # The instructions alone: no address, no symbol or comment that could
  # spell a register.
  code=$("$od" -d --no-show-raw-insn --disassemble-symbols="$s" "$bin" |
    grep -E '^ *[0-9a-f]+:' | sed -e 's/^ *[0-9a-f]*://' -e 's/<[^>]*>//g' -e 's/ ; .*$//' -e 's/ # .*$//')
  n=$(printf '%s\n' "$code" | grep -cvE '^[[:space:]]*(nop|udf|int3)' || true)
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
exit $failed
