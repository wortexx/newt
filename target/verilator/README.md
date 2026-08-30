# Verilator simulation lane

An open-source (Questa-free) simulation flow for the digital SoC, built from
scratch: a Verilator model of `iguana_soc` (compiled with `-D NO_HYPERBUS`)
driven by a C++ testbench that bit-bangs the real JTAG-DTM + RISC-V Debug
Module protocol to preload an ELF and run it, exactly the way a hardware
debugger would. See `openspec/changes/verilator-sim-flow/` for the full
design rationale and implementation record.

**Status: not yet passing end-to-end.** The model builds and the JTAG-DTM
driver runs the full sequence (init, halt request, ELF preload, `dpc` set,
resume) with the DMI protocol reporting success throughout, but the debug
module's status/data reads return a value that never changes across
repeated reads — not yet root-caused; needs waveform access this
environment doesn't have. See `openspec/changes/verilator-sim-flow/tasks.md`
(section 3, "Green light") for the full investigation log. The instructions
below describe how to build and run it as designed; the *run* currently
ends in `[JTAG] ERROR: hart 0 did not report allhalted after haltreq`
rather than a passing exit.

## What is and isn't simulated

- **DUT:** `iguana_soc` — the digital SoC (`cheshire_soc` + this project's
  config), **not** the padded chip top (`iguana_chip`) and **not** with
  hyperbus attached. Built with `NO_HYPERBUS`, iguana_soc's own tie-off
  escape hatch.
- **No hyperbus/DRAM.** Anything that needs external memory (boot modes
  other than SPM, `PRELMODE=1`) is out of scope for this lane and rejected
  at startup with a clear error rather than hanging.
- **No pads.** JTAG/UART/etc. are driven as plain digital signals, not
  through `iguana_chip`'s I/O cells.
- Questa (`make ig-sim-rtl` and friends) is untouched and remains the
  waveform-debug target, including the hyperram-backed full-chip fixture
  this lane doesn't cover.

## Building and running

Requires the `newt-eda` container (or an environment with the same tools:
Verilator ≥5, a native C++ compiler, `bender`, `riscv64-unknown-elf-gcc`).

```bash
# build the model (verilate + compile; the long step, several minutes)
make ig-verilator-model

# build a test binary, if you haven't already
make ig-sw-all

# run it (defaults to sw/tests/helloworld.spm.elf, BOOTMODE=0, PRELMODE=0)
make ig-sim-verilator

# override the binary/mode/timeout from the command line
make ig-sim-verilator BINARY=sw/tests/other.spm.elf TIMEOUT_CYCLES=5000000
```

`ig-sim-verilator` depends on `ig-verilator-model`, so a single invocation
builds the model (if needed) and runs it. Changing the test binary alone
does **not** trigger a rebuild of the model.

### Plusargs (for invoking the built binary directly)

| Plusarg | Default | Notes |
| --- | --- | --- |
| `+BINARY=<path>` | — (required) | ELF to preload and run |
| `+BOOTMODE=` | `0` | Only `0` (SPM boot) is supported; anything else is rejected |
| `+PRELMODE=` | `0` | Only `0` (JTAG/SBA preload) is supported; anything else is rejected |
| `+TIMEOUT_CYCLES=` | `20000000` | Sys-clock cycle budget before the run is declared timed out (non-zero exit) |
| `+UART_BAUD=` | `115200` | Must match what the test binary configures (matches `sw/tests/helloworld.c`'s `__BOOT_BAUDRATE`) |

### Exit codes

`0` on a passing run (the target program reached `_exit(0)`); the target's
own nonzero return code if it exited with one; `1` on a timeout or a
JTAG/DM protocol error (printed to stderr before exiting).

## Known environment gotcha (local Docker/virtiofs, not this flow's design)

On some local Docker Desktop / Rancher Desktop setups (macOS, bind-mounted
repo), any in-container `bender script`/`bender checkout` invocation can
corrupt `.bender/git/checkouts/` (a `hardlink different from source` /
`already exists and is not an empty directory` git error) due to how the
virtiofs bind mount handles git's local-clone hardlink optimization. This
is not specific to the Verilator lane — it affects any Make target that
triggers a fresh Bender checkout from inside the container on such a setup,
and is not expected on a native Linux CI runner. If you hit it: run
`bender checkout` (and, if building software, the `sw/deps/printf`
submodule init) **on the host** first, then run the container step without
any other host- or container-side `bender` call happening concurrently.
