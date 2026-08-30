# lowRISC Verilog Coding Style Guide (condensed reference)

Distilled from the full guide at
https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md
Terminology: **must** = mandatory, **recommended** = preferred but not
mandatory, **may**/**can** = optional. Justify any deviation with a comment
(and a lint waiver where applicable).

## Table of contents

1. [File basics & formatting](#file-basics--formatting)
2. [Comments](#comments)
3. [Basic module template](#basic-module-template)
4. [Naming](#naming)
5. [Module declaration & instantiation](#module-declaration--instantiation)
6. [Signal widths](#signal-widths)
7. [Blocking / non-blocking / combinational / sequential](#blocking--non-blocking--combinational--sequential)
8. [Don't-cares and X-avoidance](#dont-cares-and-x-avoidance)
9. [Case statements](#case-statements)
10. [Generate constructs](#generate-constructs)
11. [Signed arithmetic](#signed-arithmetic)
12. [Number formatting](#number-formatting)
13. [Functions and tasks](#functions-and-tasks)
14. [Problematic constructs](#problematic-constructs)
15. [Design conventions (arrays, FSMs, active-low, wildcard imports, assertions)](#design-conventions)
16. [Condensed appendix table](#condensed-appendix-table)

---

## File basics & formatting

- Prefer SystemVerilog-2017 for all RTL and tests.
- File extensions: `.sv` (module/package), `.svh` (include-only header),
  `.v`/`.vh` for pure Verilog-2001. Each `.sv`/`.v` file should contain one
  module, named to match the file (`foo.sv` -> module `foo`).
- ASCII only, Unix line endings (`\n`), every non-empty file ends in a
  newline, 100 columns max, no tabs, no trailing whitespace.
- `begin`/`end`: required whenever a statement wraps across lines; may be
  omitted only when the entire statement fits on one line. `begin` stays on
  the same line as the preceding keyword; `end` starts a new line; `end else
  begin` stay together on one line (exception: a labeled `end : foo` may be
  followed by `else` on a new line).

  ```systemverilog
  // Good: wrapped block needs begin/end
  always_ff @(posedge clk) begin
    q <= d;
  end
  // Good: single-line statement may omit them
  always_ff @(posedge clk) q <= d;
  // Bad: wrapped without begin/end
  always_ff @(posedge clk)
    q <= d;
  ```

- Indentation: two spaces per nesting level for every paired keyword
  (`begin/end`, `module/endmodule`, `package/endpackage`, `class/endclass`,
  `function/endfunction`). Line-wrap continuations indent four spaces, or
  align with an opening `(`/`{`. Closing `)`/`}` of a wrapped expression get
  their own line.
- Preprocessor branching directives (`` `ifdef/`ifndef/`else/`elsif/`endif``)
  stay left-aligned/un-indented even when nested; the code they guard keeps
  normal indentation as if the directives weren't there. Non-branching
  directives (`` `include``, etc.) follow normal indentation.
- Spacing:
  - One space after each comma in a list.
  - Whitespace around binary operators (`a + b`, not `a+b`); compact
    `[WIDTH-1:0]` is fine in a declaration.
  - Space before/after packed-array brackets, none between identifier and
    unpacked/dynamic/associative/queue dimensions, none between multiple
    dimensions: `logic [7:0][3:0] data[128][2];`.
  - Parameterized type args get one leading space (`my_fifo #(.WIDTH(4))`)
    except inside a qualified (`::`) name (`my_pkg::x_class#(8,1)`).
  - One space before and after a block label's colon (`begin : foo`,
    `end : foo`).
  - No space before a case item's colon, at least one space after it;
    `default:` always keeps its colon.
  - No space between a function/task/macro name and its opening `(`.
  - Line continuations (`\`) right-aligned, consistently, past the longest
    line in the macro.
  - Space before/after keywords, except right after an opening `(` or at the
    start/end of a line (`always_ff @(posedge clk)`, not `@( posedge clk)`).
- Parentheses: use them whenever a human would have to think about operator
  precedence. A ternary nested in another ternary's *true* branch must be
  parenthesized; parens may be dropped in a ternary chain that visually reads
  like a priority mux (`cond_a ? a : cond_b ? b : default_val;`).

## Comments

- `//` C++-style preferred; `/* */` allowed. A comment on its own line
  describes the following code; a trailing comment describes that line.
- Section headers inside a module: a single-line name framed in `//`:
  ```systemverilog
  ////////////////
  // Controller //
  ////////////////
  ```
- To mark the start/end of a block (e.g. around a loop), use a plain
  single-line comment with no extra decoration -- not a boxed banner:
  ```systemverilog
  // begin: iterate over foobar
  for (...) begin
  ...
  end
  // end: iterate over foobar
  ```

## Basic module template

```systemverilog
// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// One line description of the module

module my_module #(
  parameter Width = 80,
  parameter Height = 24
) (
  input              clk_i,
  input              rst_ni,
  input              req_valid_i,
  input  [Width-1:0] req_data_i,
  output             req_ready_o,
  ...
);

  logic [Width-1:0] req_data_masked;

  submodule u_submodule (
    .clk_i,
    .rst_ni,
    .req_valid_i,
    .req_data_i (req_data_masked),
    .req_ready_o(req_ready),
    ...
  );

  always_comb begin
    req_data_masked = req_data_i;
    case (fsm_state_q)
      ST_IDLE: begin
        req_data_masked = req_data_i & MASK_IDLE;
        ...
  end

  ...

endmodule
```

## Naming

Summary table:

| Construct | Style |
| --- | --- |
| Declarations (module, class, package, interface) | `lower_snake_case` |
| Instance names | `lower_snake_case` |
| Signals (nets and ports) | `lower_snake_case` |
| Variables, functions, tasks | `lower_snake_case` |
| Named code blocks | `lower_snake_case` |
| `` `define`` macros | `ALL_CAPS` |
| Tunable parameters (modules, classes, interfaces) | `UpperCamelCase` |
| Constants | `ALL_CAPS` or `UpperCamelCase` |
| Enumeration types | `lower_snake_case_e` |
| Other typedef types | `lower_snake_case_t` |
| Enumerated value names | `ALL_CAPS` (default in this skill) or `UpperCamelCase` -- the guide accepts either; match the surrounding codebase if one is already established |

- **Constants**: declare in a `package` using `parameter` (module/class
  scope: `localparam`). `` `define`` -> `ALL_CAPS`; module `parameter` ->
  `UpperCamelCase`; a truly fixed `localparam` constant (e.g. an opcode
  value) -> `ALL_CAPS`. Include units in the name unless unitless or "bits"
  (`FooLengthBytes`).
- **Parameterized objects**: use `parameter` for what a user tunes at
  instantiation, `localparam` for anything derived from it. Always give
  parameters an explicit type and a sensible default. Never use `` `define``
  or `defparam` to parameterize a module.
  ```systemverilog
  module modname #(
    parameter  int Depth  = 2048,          // 8kB default
    localparam int Aw     = $clog2(Depth)  // derived parameter
  ) ( ... );
  ```
- **Macros**: `ALL_CAPS_WITH_UNDERSCORES`. Global macros get a namespace
  prefix + double underscore (`` `SN_FOO__ALPHA_BETA``); file-local macros
  get a single leading underscore and must be `` `undef``-ed after use.
- **Suffixes** (combine without an extra `_`, `_n` first, `_i/_o/_io` last):

  | Suffix | Meaning |
  | --- | --- |
  | `_e` | enum typedef |
  | `_t` | other typedef |
  | `_n` | active-low signal |
  | `_n`, `_p` | differential pair (active-low / active-high) |
  | `_d`, `_q` | register input / output |
  | `_q2`, `_q3`, ... | further pipeline stages (2, 3, ... cycles latency) |
  | `_i`, `_o`, `_io` | module input / output / bidirectional |

  `_d`/`_q` don't have to propagate all the way to module boundaries.
- **Enumerations**: always `typedef`, name the type `snake_case_e`, always
  specify a 4-state storage type (`logic`, not `bit`) for synthesizable
  enums, never leave an enum anonymous. Value names may be `ALL_CAPS` or
  `UpperCamelCase` -- the guide explicitly allows either (it calls this out
  as a case where "a collection of arbitrary values could be either
  convention"); this skill defaults to `ALL_CAPS` unless the codebase
  already uses `UpperCamelCase`.
  ```systemverilog
  typedef enum logic [7:0] {  // 8-bit opcodes
    OP_JALR = 8'hA0,
    OP_ADDI = 8'h47
  } opcode_e;
  ```
- **Signals**: `lower_snake_case`, descriptive whole words (avoid
  abbreviations), never end in `_<number>` (confuses netlist bus naming
  tools), never a reserved keyword. Share a common prefix across signals
  that belong together (`foo_valid`, `foo_ready`, `foo_data`) and across a
  non-default clock domain (`dram_*` for signals synchronous to `clk_dram`).
  A signal should keep the same name at every level of hierarchy it's wired
  through unmodified (exceptions: array elements, or renaming a generic port
  like `host_bus` to something design-specific).
- **Clocks**: the main clock is `clk`; secondary clocks get a unique
  `clk_<name>` (`clk_dram`, `clk_axi`), and that suffix becomes the prefix
  for other signals in that domain.
- **Resets**: active-low, asynchronous, default name `rst_n` (or
  `rst_<domain>_n`). Preferred syntax:
  ```systemverilog
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) q <= 1'b0;
    else        q <= d;
  end
  ```

## Module declaration & instantiation

- Use full Verilog-2001 port declaration style (type + direction inline per
  port), never the Verilog-95 list style. Opening `(` on the module-name
  line, first port on the next line, closing `)` alone at column 0. Clock
  port(s) first, then reset(s).
  ```systemverilog
  module foo #(
    parameter int unsigned Width = 8,
  ) (
    input                    clk_i,
    input                    rst_ni,
    input [Width-1:0]        d_i,
    output logic [Width-1:0] q_o
  );
  ```
- Instantiate with fully named ports; `.port_name` (no parens) is fine when
  the connecting signal shares the port's name. Every declared port must be
  present in the instantiation -- explicit no-connect (`.foo_o()`) for
  unused outputs, explicit tie-off (`.foo_i(8'd0)`) for unused inputs.
  `.*` is never allowed. No positional connections. Ports instantiated in
  declaration order. Named parameters for instantiation too (an exception is
  a single, obviously-named parameter like a register width, which may be
  positional: `my_reg #(16) my_reg0 (...)`). Never `defparam`. Never
  recursive self-instantiation.
  ```systemverilog
  my_module i_my_instance (
    .clk_i,
    .rst_ni,
    .d_i   (from_here),
    .q_o   (to_there)
  );
  ```
  Align port expressions in a table: the `(` lines up across a block, no
  space right after `(` or right before `)`.

## Signal widths

- Every number literal gets an explicit width (`4'd4`, not `4`). Exceptions:
  `1'b1`/`Bus_width'(1)` idioms for parameterized increments, `'0` for an
  auto-sized zero, and literals assigned to 2-state integer types
  (`byte`/`int`/...).
- Match port-connection widths explicitly rather than relying on implicit
  extension/truncation:
  ```systemverilog
  // Good
  my_module i_module (.thirty_two_bit_input({16'd0, sixteen_bit_word}));
  // Bad: silently zero-extends 16 -> 32 bits
  my_module i_module (.thirty_two_bit_input(sixteen_bit_word));
  ```
- Never use a multi-bit signal directly as a boolean; compare explicitly to
  `'0`:
  ```systemverilog
  assign out = (a != '0) && (b == '0);      // good
  assign out = a && !b;                     // bad: implicit 4-bit -> 1-bit
  ```
- Only use bit-slicing (`a[7:1]`) for an actual partial reference; slicing
  the full width (`a[7:0] = ...` when `a` is 8 bits) is redundant and can
  mask lint warnings.
- Shifts can silently widen a result; prefer bit-select/concatenation over
  shifting by a constant. Addition/negation naturally produce one extra bit
  from carry -- dropping it on assignment is allowed, optionally made
  explicit with a size cast: `assign cnt_d = 4'(cnt_q + 4'h1);`.

## Blocking / non-blocking / combinational / sequential

- Sequential (clocked) blocks: **only** non-blocking assignments (`<=`).
  Combinational blocks: **only** blocking assignments (`=`). Never mix
  either within one block -- simulators can process the two assignment
  types as different events, causing real simulation/synthesis divergence.
- No `#delay` anywhere in synthesizable modules (including `#0`); design
  around zero-delay simulation.
- Latches are discouraged -- use flip-flops. If one is unavoidable, use
  `always_latch` with non-blocking assignments only, never blocking.
- Standard register pattern:
  ```systemverilog
  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) foo_q <= 8'hab;
    else if (foo_en) foo_q <= foo_d;
  end
  ```
  Never let two non-blocking assignments target the same bit across
  different `if`s in one block -- turn a second `if` into `else if` even if
  the conditions look mutually exclusive.
- Keep sequential blocks minimal (ideally just a register + load-enable or
  reset); push real decision logic into a companion `always_comb` block that
  computes the `_d` (next-state) value, with the sequential block only doing
  `state_q <= state_d`:
  ```systemverilog
  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) state_q <= ST_IDLE;
    else         state_q <= state_d;
  end

  always_comb begin
    state_d = state_q;  // default: stay in current state
    unique case (state_q)
      ST_IDLE: state_d = ST_INIT;
      ST_INIT: state_d = conditional ? ST_IDLE : ST_CALC;
      ST_CALC: if (conditional) state_d = ST_RESULT;
      ST_RESULT: state_d = ST_IDLE;
      default: ;
    endcase
  end
  ```
  (State names shown here in `ALL_CAPS` per this skill's default -- the
  guide itself equally accepts `UpperCamelCase`, e.g. `StIdle`.)
- Use `always_comb` (not `always @*`, which is Verilog-2001-only) for
  combinational logic, with no explicit sensitivity list. Prefer plain
  `assign` wherever practical. No three-state (`Z`) logic for on-chip muxing.
  Never infer a latch inside a function.

## Don't-cares and X-avoidance

RTL must not assign `X` to represent "don't care" -- it risks
simulation/synthesis mismatches. Instead, fully define every output and use
SystemVerilog assertions (SVAs) to flag invalid conditions:

```systemverilog
// Flag consumption of a value that may be meaningless when its enable is low
assign special_reg_en = (reg_addr == SPECIAL_REG_ADDR) & reg_wr_en;
`ASSERT(NoSpecialRegEnWithoutRegEn, special_reg_en |-> reg_wr_en);

// Assert every module output is known post-reset (except FIFO/SRAM/regfile
// outputs, which may legitimately start as X)
assign out_o = ina_i ^ inb_i;
`ASSERT_KNOWN(OutKnown_A, out_o, clk_i, !rst_ni)
```

For case/ternary select signals, add `` `ASSERT_KNOWN`` (or a fuller
functional assertion) on the selector, and keep any qualifying "valid"
condition on such an assertion as broad as possible rather than narrowly
scoped. Dynamic array indexing can implicitly produce `X` -- avoid by
aligning indexed arrays to a power of two, or guard the index with an `if`.

## Case statements

- `unique case` is best practice (creates simulation assertions that catch
  mistakes); `priority` is occasionally appropriate but a cascaded ternary
  is usually clearer for priority encoders. Never use `full_case` /
  `parallel_case` pragmas -- they can cause sim/synth mismatches.
- Always include `default:`, even when every value looks covered -- in
  simulation an `X` select value matches no case item and behaves like an
  inferred latch, which synthesis won't reproduce.
- If there's no default-assignment block before the case, every variable
  touched by any case item must be assigned in *all* items including
  `default:`. Setting defaults before the case (see the FSM pattern above)
  lets individual items only state what deviates from that default.
- Wildcards: use plain `case` if you don't need wildcard behavior, `case
  inside` if you do (preferred), `casez` only if Verilog-2001 compatibility
  is required (`?` for the wildcard bit). Never use `casex` -- treating `X`
  as a wildcard hides bugs that `casez` (treats only `Z`/`?` as wildcard)
  and `case inside` (no wildcard on `X`/`Z`) avoid.

## Generate constructs

Always name generate blocks explicitly, `lower_snake_case`, space between
`begin` and the name:

```systemverilog
if (TypeIsPosedge) begin : posedge_type
  always_ff @(posedge clk) foo <= bar;
end else begin : negedge_type
  always_ff @(negedge clk) foo <= bar;
end

for (genvar ii = 0; ii < NumberOfBuses; ii++) begin : my_buses
  my_bus #(.index(ii)) i_my_bus (.foo(foo), .bar(bar[ii]));
end
```

Don't wrap a generate construct in an extra `begin`; don't use the
`generate`/`endgenerate` region keywords.

## Signed arithmetic

Use `signed'(...)` (or `$signed(...)` in Verilog-2001) whenever converting
unsigned to signed. If any operand in an expression is unsigned, Verilog
silently treats the whole expression as unsigned and warns -- don't ignore
that warning; cast explicitly instead:

```systemverilog
sum1 = a + incr;                   // bad: surprises, a treated as unsigned
sum2 = a + signed'({1'b0, incr});  // good
sum3 = a + 8'sh01;                 // good, simpler
```

## Number formatting

When printing: `0x` prefix for hex, `0b` prefix for binary, no prefix for
decimal (`$display("0x%0x", v); $display("0b%0b", v); $display("%0d", v);`).
When declaring constants, use underscore grouping for readability on
hex/binary literals over 8 bits, and write the literal in whatever base
(binary/hex/decimal) it's typically displayed in.

## Functions and tasks

RTL (not DV) rule: functions are allowed if `automatic`; **tasks are not
allowed** in synthesizable RTL.

- Explicit storage type on every argument and the return value, all 4-state
  (`logic` or logic-derived types) -- no `int`/`bit`/other 2-state types.
- No `output`/`inout`/`ref` arguments -- functions take inputs only and
  produce exactly one return value, via `return result;` (not
  `function_name = result;`).
- Every local variable must be assigned on every code path (initial
  assignment, or `else`/`default:` coverage).
- No references to signals/variables outside the function's own scope
  (parameters/constants are fine to reference; other module-level signals
  are not -- pass them in as arguments instead).

```systemverilog
function automatic logic [2:0] foo(logic [2:0] a, logic [2:0] b);
  logic [2:0] result;
  if (a == 3'd2) result = b;
  else            result = a ^ b;
  return result;
endfunction
```

## Problematic constructs

Discouraged/prohibited outright:

- **Interfaces** and the **`alias`** statement -- discouraged in general.
- **Floating `begin`/`end` blocks** (a bare block that isn't part of a
  `for`/`if`/`case` generate construct) -- not LRM-compliant, don't use them.
- **Hierarchical references** in synthesizable RTL -- prohibited (support is
  inconsistent across synthesis tools). The only exception is a reference
  guarded by macros so it's removed for synthesis, e.g. inside an SVA.

## Design conventions

- **Declare all signals** with an explicit data type -- no implicit net
  inference.
- **Use `logic`** for synthesizable signals (`wire` is fine as continuous-
  assignment shorthand, or where required, e.g. `inout` nets -- justify with
  a comment). Don't confuse `wire [7:0] sum = a + b;` (continuous assignment,
  synthesizable) with `logic [7:0] sum = a + b;` (initialization, generally
  not synthesizable).
- **Logical vs. bitwise**: logical operators (`!`, `||`, `&&`, `==`, `!=`)
  for true/false conditions (`if`, ternary conditions); bitwise (`~`, `|`,
  `&`, `^`) for data, even 1-bit data.
- **Packed arrays/bit vectors**: little-endian, i.e. `[msb:lsb]` with
  `msb >= lsb` (`logic [31:0] word;`).
- **Unpacked arrays**: big-endian (`[n:m]` with `n <= m`), or the zero-based
  shorthand `[size]` (equivalent to `[0:size-1]`). Never declare one
  little-endian (`[size-1:0]`).
- **Finite State Machines**: enum for states (`ALL_CAPS` values by default,
  e.g. `ST_IDLE` -- or `UpperCamelCase`/`StIdle` if the codebase already
  uses that), one combinational block that sets defaults then decodes state
  -> next-state + outputs, and one clocked block that does nothing but
  register the state (see pattern under "Blocking / non-blocking" above).
  One state machine per module where possible; if a module needs more than
  one, prefix/suffix each machine's states distinctly (`ST_RD_IDLE`,
  `ST_WR_IDLE`). Pick state names that look visually distinct early in the
  name, since it helps when reading waveforms.
- **Active-low signals**: must carry the `_n` suffix; everything else is
  assumed active-high.
- **Differential pairs**: `_p`/`_n` suffixes (e.g. `lvds_po`, `lvds_no`).
- **Delayed-by-one-cycle signals**: `_q` suffix; further stages `_q2`,
  `_q3`, etc.
- **Wildcard package imports** (`import foo_pkg::*;`): only allowed when the
  package is part of the *same IP* as the importing module, and only in the
  module header or module body (never at file scope before the module,
  which pollutes `$root`).
- **Assertion macros**: `` `ASSERT_I``, `` `ASSERT_INIT``, `` `ASSERT``,
  `` `ASSERT_KNOWN`` (reference implementation: lowRISC OpenTitan's
  `prim_assert.sv`). For security-critical designs, suffix the macro name
  with `_SEC` (`` `ASSERT_SEC``, etc.) so these assertions can be identified
  for later security-specific processing.

## Condensed appendix table

- SystemVerilog-2017 conventions; one module per file, named `module.sv`.
- ASCII only, 100 cols, no tabs, two-space indent for paired keywords.
- `//` comments; one space after commas; whitespace around keywords and
  binary operators; no space before case-item colon or before
  function/task/macro call parens; four-space indent on wrapped lines;
  `begin` ends its line, `end` starts a new one.
- `lower_snake_case`: instances, signals, declarations, variables, types.
  `UpperCamelCase`: tunable parameters, enum values. `ALL_CAPS`: constants,
  `` `define`` macros. Main clock is `clk`; other clocks start with `clk_`.
  Resets are active-low/async, default `rst_n`. Names should be descriptive
  and consistent through the hierarchy.
- Suffixes: `_i`/`_o`/`_io` (ports), `_d`/`_q` (register in/out, `_q2`/`_q3`
  for further pipeline stages), `_n` (active-low, first if combined with
  another suffix), `_p` (active-high half of a diff pair), `_e` (enum
  typedefs).
- Full port declaration style, clock/reset first; named-port instantiation
  with every port present, no `.*`; top-level `parameter`s over `` `define``;
  symbolic constants over raw numbers; `localparam` for local constants,
  package `parameter` + `.svh` for globals.
- `logic` over `reg`/`wire`; declare everything explicitly.
  `always_comb`/`always_ff`/`always_latch` over bare `always`. Interfaces
  discouraged. Sequential = non-blocking; combinational = blocking. Avoid
  latches. Avoid `X` in RTL, use SVAs instead. Prefer `assign`. `unique
  case` with a `default:` always. Cast explicitly for signed arithmetic.
  Print with `0x`/`0b` prefixes, `_` grouping for readability.
  Packed = little-endian, unpacked = big-endian.
  FSM state register: no logic besides reset. FSM combinational block: set
  defaults for every output (including next-state) before the case.
