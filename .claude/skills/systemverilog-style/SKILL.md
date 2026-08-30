---
name: systemverilog-style
description: >
  Apply the lowRISC Comportable SystemVerilog coding style guide when writing,
  generating, refactoring, or reviewing SystemVerilog / Verilog RTL and
  testbench code. Use this whenever the user asks to write a module, FIFO,
  FSM, bus interface, register file, or any other synthesizable SV block, or
  asks to check, lint, clean up, or review existing .sv/.v code for style,
  naming, or coding conventions -- even if they don't mention "lowRISC" or
  "style guide" by name. Also use it when the user is working inside an
  RTL/hardware project (e.g. files with .sv/.svh/.v extensions, module/
  endmodule blocks) and asks for new logic, a bugfix, or a refactor, since
  generated code should match house RTL conventions by default.
---

# SystemVerilog Style (lowRISC Comportable)

This skill makes generated or reviewed SystemVerilog conform to the
[lowRISC Verilog Coding Style Guide](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md)
("Comportable style"). The guide exists to keep hardware readable and
reviewable across a team, and to avoid a long list of classic Verilog
footguns (simulation/synthesis mismatches, inferred latches, X-propagation
bugs). Treat it as the default house style unless the surrounding codebase
clearly follows a different, consistent convention -- in that case, match
the codebase instead, since consistency within a project beats an external
standard.

## When you're generating new code

Work through this checklist as you write. It covers the rules that shape
*every* module; `references/lowrisc-style-guide.md` has the full guide with
more examples and the reasoning behind trickier rules (X-avoidance, signed
arithmetic, function argument rules, etc.) -- read it when you hit something
this checklist doesn't cover, or when you want to double check a rule before
telling the user "this follows lowRISC style."

**File & module basics**
- One module per `.sv` file; the file name matches the module name.
- ASCII only, Unix line endings, no tabs, no trailing whitespace, wrap at
  100 columns.
- Two-space indentation for every paired keyword (`begin/end`,
  `module/endmodule`, etc.); four-space indent for wrapped continuation lines.

**Naming** (this is the single most load-bearing convention -- get it right
and the rest of the style mostly falls out naturally)
- `lower_snake_case` for modules, instances, signals, variables, functions,
  named blocks.
- `UpperCamelCase` for tunable module parameters.
- `ALL_CAPS` for `` `define`` macros and true constants. The guide leaves
  enum/state value names as either `ALL_CAPS` or `UpperCamelCase` (both are
  spec-compliant) -- **default to `ALL_CAPS`** (`ST_IDLE`, `OP_JALR`) unless
  the surrounding codebase already uses `UpperCamelCase` (`StIdle`), in which
  case match it.
- Type suffixes: `_e` for enum typedefs, `_t` for other typedefs.
- Signal suffixes (combine without extra underscores, `_n` first, `_i/_o/_io`
  last): `_i`/`_o`/`_io` for module ports, `_n` for active-low, `_p`/`_n` for
  differential pairs, `_d`/`_q` for a register's input/output, `_q2`, `_q3`...
  for further pipeline stages.
- Clocks start with `clk` (`clk`, or `clk_axi` for a secondary clock).
  Resets are active-low and asynchronous, default name `rst_n`.
- Use whole, descriptive words -- avoid abbreviations. Give related signals a
  shared prefix (`bram_addr`, `bram_valid`, ...).

**Module declaration & instantiation**
- Full Verilog-2001 port style with explicit type and direction per port,
  clock(s) first, then reset(s). Closing paren of the port list on its own
  line at column 0.
- Parameterize with `parameter` in the module header (`UpperCamelCase` name,
  explicit type, sane default); derive internal constants with `localparam`.
- Instantiate with fully named ports (`.port_name(signal)`, or bare
  `.port_name` when the signal has the same name) -- never positional, never
  `.*`. Every declared port must appear, explicitly no-connected or tied off
  if unused. Align the `(` of the port expressions in a table (see the guide
  for exact spacing).

**Combinational vs. sequential logic** -- this split is the other rule that
matters most, because mixing assignment types in one block causes real
simulation/synthesis mismatches (not just a style nit):
- Combinational: `always_comb`, blocking assignments (`=`) only, no
  sensitivity list. Prefer plain `assign` where practical.
- Sequential (registers): `always_ff @(posedge clk or negedge rst_n)`,
  non-blocking assignments (`<=`) only. Keep sequential blocks minimal --
  ideally just `if (!rst_n) ... else state_q <= state_d;` -- and push any
  real logic into a companion `always_comb` block.
- Avoid latches; if one is unavoidable use `always_latch` with non-blocking
  assignments.

**Case statements & FSMs**
- Prefix with `unique case`; always include a `default:`, even when every
  value seems covered -- without it, an `X` in simulation behaves like an
  inferred latch and diverges from synthesis.
- Never use `full_case`/`parallel_case` pragmas or `casex`; use `case`,
  `case inside`, or `casez` (in that order of preference) instead.
- FSMs get three pieces: a `_e`-suffixed enum of states (`ALL_CAPS` by
  default, e.g. `ST_IDLE` -- see the naming note above), a combinational
  block that sets default outputs and next-state *before* the case (so
  individual cases only need to state what deviates from default), and a
  sequential block that does nothing but `state_q <= state_d` plus reset.

**Widths, X-values, and safety**
- Give every number literal an explicit width (`8'd2`, not `2`).
- Never compare/branch on a multi-bit signal as if it were boolean --
  compare explicitly to `'0`.
- Don't let RTL assign `X` to mean "don't care"; fully define outputs and
  use `` `ASSERT_KNOWN``/`` `ASSERT`` (SVAs) to flag invalid conditions
  instead. This keeps behavior deterministic, which matters even more for
  security-sensitive designs.
- Packed arrays/bit vectors are little-endian (`[7:0]`); unpacked arrays are
  big-endian (`[0:N-1]` or the shorthand `[N]`).

**Other frequent rules**
- `logic` over `reg`/`wire` for synthesizable signals (`wire` is fine for a
  simple continuous-assignment shorthand or `inout` nets).
- Logical operators (`||`, `&&`, `!`, `==`) for true/false conditions;
  bitwise operators (`|`, `&`, `~`, `^`) for data, even 1-bit data.
- Name every `generate` block (`if (...) begin : some_name`).
- No hierarchical references in synthesizable RTL; no recursive
  instantiation; wildcard package imports only within the same IP.
- Functions: must be `automatic`, only take inputs (no `output`/`ref`
  args), return via `return`, and not touch signals outside their own scope.

## When you're reviewing / linting existing code

Read the file(s) in question, then go through the same checklist above
looking for violations. For each issue found, report:
1. the rule violated (in plain terms, not just "see section X"),
2. why it matters (simulation/synthesis mismatch, readability, latch
   inference, etc. -- the "why" is what makes the feedback actionable
   instead of just pedantic), and
3. a corrected snippet.

Group findings by severity: things that are must-fix per the guide (wording
like "must", "do not", "prohibited") versus things that are merely
recommended. Don't nitpick pure formatting (spacing, alignment) as heavily
as correctness-affecting issues (blocking/non-blocking mixups, missing
`default:`, X-propagation, width mismatches) -- surface the important stuff
first.

If the existing code deviates from the guide but does so consistently and
on purpose (e.g. a codebase-wide choice to use `ALL_CAPS` module parameters
instead of `UpperCamelCase`), point that out as a deviation from Comportable
style rather than silently "fixing" it against the codebase's own
convention -- flag it, note the tradeoff, and let the user decide.

## Reference

`references/lowrisc-style-guide.md` contains the fuller version of this
guide: complete good/bad code examples for every rule above, the basic
module template, the condensed appendix table, and coverage of rules not
summarized here (number formatting/printing, delay modeling, signed
arithmetic casting, dynamic array indexing pitfalls, assertion macro
naming for security-critical logic). Open it when generating something
non-trivial (FIFOs, arbiters, FSMs with multiple machines, anything using
DV-style assertions) or when you want to quote the guide's own example back
to the user during a review.
