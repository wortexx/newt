#!/usr/bin/env bash
# Smoke-tests a newt-eda image: confirms every pinned, bumped, or newly added
# tool is on PATH and reports a sane version. Run inside the image, e.g.:
#   docker run --rm -v "$PWD/docker/smoke-test.sh:/smoke-test.sh" \
#     newt-eda:dev bash /smoke-test.sh
# Shared by CI (.github/workflows/docker-image.yml) and manual checks so both
# gate on the same thing (see spec: eda-tooling-image, "All tools present").
set -uo pipefail

fail=0
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "OK   $desc"
  else
    echo "FAIL $desc"
    fail=1
  fi
}

check "yosys"        yosys --version
check "morty"        morty --version
# svase's own --version throws an unhandled cxxopts exception (tries to read
# a required positional "top" argument before checking --version was passed)
# and aborts - a pre-existing bug in this pin, not something we touch. --help
# takes the same early-return path successfully, so use that instead.
check "svase"        svase --help
check "sv2v"         sv2v --version
check "bender"       bender --version
check "openroad"     openroad -version
check "riscv64 gcc"  riscv64-unknown-elf-gcc --version
check "verilator"    verilator --version
check "verible lint" verible-verilog-lint --version

# Zknh toolchain probe (spec: eda-tooling-image, "Zknh toolchain support")
tmpdir=$(mktemp -d)
printf 'int main(void) { return 0; }\n' > "$tmpdir/probe.c"
if riscv64-unknown-elf-gcc -march=rv64gc_zknh -mabi=lp64d \
    -o "$tmpdir/probe.elf" "$tmpdir/probe.c" >/dev/null 2>&1; then
  echo "OK   riscv64 gcc -march=rv64gc_zknh"
else
  echo "FAIL riscv64 gcc -march=rv64gc_zknh"
  fail=1
fi
rm -rf "$tmpdir"

exit "$fail"
