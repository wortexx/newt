# Xcelium simulation lane

Runs the SoC RTL under Cadence Xcelium (`xrun`, developed against
24.03-s004) on a **restricted VM** with no git, Bender, Docker or network
access. The host builds a single self-contained archive. You copy it to
the VM, run one script there, and copy one results archive back.

The design under test is `iguana_soc` compiled with `-D NO_HYPERBUS`, the
same one the [Verilator lane](../verilator/README.md) builds. It is driven
by Cheshire's own verification IP (`vip_cheshire_soc`): clocks, reset,
JTAG ELF preload through the reference `riscv-dbg` driver, and UART
output. Design record: `openspec/changes/xcelium-sim-lane/`.

## What is and isn't simulated

| Simulated | Not simulated |
| --- | --- |
| `iguana_soc`: Cheshire + CVA6 with this project's `CheshireCfg` | Pads (`iguana_chip`), hyperbus controller, hyperram |
| IHP13 SRAM/stdcell/pad behavioral models | DRAM: `*.dram.elf` tests cannot run, since the LLC's external port is tied off |
| Cheshire's VIP, SPI NOR flash and I2C EEPROM models | Gate-level, sv2v or netlist simulation |

Only JTAG preload (`BOOTMODE=0 PRELMODE=0`) is the acceptance path.
Serial-link and UART preload, and autonomous boot from flash or EEPROM
(`BOOTMODE=2/3` with `IMAGE=`), are passed through to the VIP unmodified.

## 1. Host: build the bundle

Prerequisites, once per checkout (the `newt-eda` container works for all
of them):

```bash
make ig-hw-all    # generated RTL
make ig-sw-all    # test ELFs (sw/tests/*.spm.elf in the Cheshire checkout)
```

Then:

```bash
make ig-xrun-bundle
# -> target/xcelium/out/newt-xrun-<sha>[-dirty].tar.gz  (~1.5 MB)
```

On first use this downloads Cheshire's two vendor sim models with `wget`
(its `chs-sim-all` rules). **They are non-free.** The bundle and any
results that carry them are gitignored and are not for redistribution.

The target fails before archiving if any file or include directory in
the bundle's `xrun.f` is missing, absolute, or outside the bundle. It
also fails if the EEPROM model is not actually a model. Set
`XRUN_ELFS="a.elf b.elf"` to bundle specific ELFs instead of all
`*.spm.elf`.

`MANIFEST` inside the bundle records the commit, whether the tree was
dirty, the `Bender.lock` hash, and every ELF's sha256.

## 2. VM: run

```bash
tar xzf newt-xrun-<sha>.tar.gz
cd newt-xrun-<sha>
./run.sh                          # every bundled test
./run.sh helloworld.spm           # or a subset (".elf" optional)
TIMEOUT_NS=50000000 WAVES=vcd ./run.sh helloworld.spm
./run.sh --help
```

`run.sh` compiles and elaborates once, runs each test against that
snapshot, prints a summary, and writes
**`<bundle-id>-results-<timestamp>.tar.gz`** in the bundle directory.
That one file is what you copy back.

| Setting (env var) | Default | Meaning |
| --- | --- | --- |
| `BOOTMODE` | `0` | 0 = idle boot + preload; 2/3 = autonomous boot (needs `IMAGE`) |
| `PRELMODE` | `0` | 0 = JTAG, 1 = serial link, 2 = UART (with `BOOTMODE=0`) |
| `IMAGE` | empty | memh image for `BOOTMODE=2/3` |
| `TIMEOUT_NS` | `10000000` (10 ms) | simulated-time bound per test |
| `WAVES` | `none` | `vcd`: debug path only (`dmi_jtag`, `dm_top`, CVA6 ports), for GTKWave on the host. `shm`: everything, for SimVision on the VM |
| `WALL_TIMEOUT_S` | `7200` | wall-clock bound per test (uses `timeout` if present; `0` = off) |
| `XRUN`, `XRUN_COMP_ARGS`, `XRUN_RUN_ARGS` | `xrun`, empty, empty | tool override and extra compile/run arguments (e.g. `-nowarn` entries) |

## 3. Host: read the results

```bash
tar -C target/xcelium/out -xzf <bundle-id>-results-<timestamp>.tar.gz
```

Extract under `target/xcelium/out/`, which is gitignored. The archive
contains:

- `summary.txt`: one line per test
- `compile.log`
- `<test>/run.log`: the full simulation log, including `[UART]` output
- `<test>/waves.*`: when requested
- `settings.txt`, `xrun-version.txt`, `check-bundle.log`, `MANIFEST`

| Verdict | Meaning |
| --- | --- |
| `PASS` | the program signalled exit code 0 |
| `FAIL` | the program signalled a non-zero exit code (shown in `EXIT`) |
| `TIMEOUT` | no completion within `TIMEOUT_NS` (or `WALL_TIMEOUT_S`) |
| `ERROR` | could not run: compile failure, unsupported mode, missing ELF, or the simulation ended without a verdict (e.g. a VIP `$fatal`; see `run.log`) |

`run.sh` exits 0 only if every executed test is `PASS`.

## Running in place

On a machine that has `xrun` on `PATH`, `make ig-sim-xrun` stages the
bundle and runs the same `run.sh` inside
`target/xcelium/build/bundle/`. `BINARY`, `BOOTMODE` and `PRELMODE` are
shared with the Verilator lane, whose `BINARY` defaults to
`helloworld.spm.elf`. Pass `BINARY=` (empty) to run every bundled test.
