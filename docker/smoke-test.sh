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
  local out
  if out=$("$@" 2>&1); then
    echo "OK   $desc"
  else
    echo "FAIL $desc"
    # Show what actually happened. A bare FAIL with no observed value cost a
    # full CI round-trip to diagnose once already (the composite image had
    # silently been built from a stale yosys layer, so the assertions were
    # right and the image was wrong - indistinguishable without this).
    printf '%s\n' "$out" | head -3 | sed 's/^/       | /'
    fail=1
  fi
}

# Like check, but for "this output must contain that string" assertions, which
# `check` cannot report usefully: the grep that decides them prints nothing.
check_contains() {
  local desc="$1" needle="$2"; shift 2
  local out
  out=$("$@" 2>&1)
  if printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "OK   $desc"
  else
    echo "FAIL $desc - no '$needle' in output of: $*"
    printf '%s\n' "$out" | head -3 | sed 's/^/       | /'
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
# Flow-support utilities the Makefiles call by name, not EDA tools themselves -
# missing gawk broke a live overnight synth-all run (yosys.mk/openroad.mk pipe
# their logs through `gawk '{ print strftime(...) }'`, which plain awk lacks);
# unzip is used by OpenROAD's checkpoint.tcl. Version-checking the 9 tools
# above never would have caught this.
check "gawk"         gawk --version
check "unzip"        unzip -v

# Yosys is upstream now, pinned by release tag in docker/yosys/Dockerfile
# (openspec/changes/upgrade-yosys-upstream). Three assertions beyond "it runs",
# because the flow depends on specific yosys features that a version bump or a
# wrong build configuration could silently drop:
#
#  - the exact pinned version, so a moving/stale layer cannot pass unnoticed
#  - `abc -liberty_args`, which yosys_synthesis.tcl passes as "-S 20 -G 3".
#    This was the reason the flow ran a custom fork until v0.66 landed the
#    same option upstream (PR #5721); if upstream ever renames it, the synth
#    script breaks at ABC time, ~2 h into a run, instead of here.
#  - `read_slang`, the built-in slang SystemVerilog frontend (v0.67+). Nothing
#    in the flow reads it *yet* - it is the prerequisite the Phase 8 frontend
#    work depends on, so the image must not regress to a yosys without it.
#    Must resolve with no `-m`/`plugin -i`, i.e. genuinely built in.
EXPECT_YOSYS_VERSION="${EXPECT_YOSYS_VERSION:-0.69}"
check_contains "yosys version is ${EXPECT_YOSYS_VERSION}" "Yosys ${EXPECT_YOSYS_VERSION}" \
  yosys --version
check_contains "yosys abc has -liberty_args" "-liberty_args" \
  yosys -p "help abc"

# read_slang needs its own shape of assertion. `yosys -p 'help <unknown>'`
# EXITS 0 - kernel/register.cc logs "No such command or cell type" with log()
# rather than log_error() - so testing the exit status here passes against any
# yosys ever built, including one with no slang frontend at all. That false
# pass is not hypothetical: it reported OK against a stale 0.40 image in the
# same run where the two assertions above correctly failed. Assert on the
# absence of that message instead.
slang_help=$(yosys -p "help read_slang" 2>&1)
if printf '%s' "$slang_help" | grep -qF "No such command"; then
  echo "FAIL yosys read_slang is built in - yosys does not know the command"
  printf '%s\n' "$slang_help" | head -3 | sed 's/^/       | /'
  fail=1
else
  echo "OK   yosys read_slang is built in"
fi

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
