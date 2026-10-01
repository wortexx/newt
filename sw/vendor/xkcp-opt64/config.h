/* Hand-written equivalent of the config.h XKCP's build generates for the
 * `generic64` target (Makefile.build: generic64 -> K1600-plain-64bits-ua in
 * lib/LowLevel.build): all rounds unrolled, no lane complementing. Only the
 * KeccakP-1600 entries are relevant to the files vendored here. Not an XKCP
 * file; see REVISION. */
#define XKCP_has_KeccakP1600
#define KeccakP1600_plain64_implementation_config "all rounds unrolled"
#define KeccakP1600_plain64_fullUnrolling
