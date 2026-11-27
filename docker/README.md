# Docker Tools

## Building

Currently each part of the tool-flow has its own builder (compiles to binary) and runner (copies binary from builder).
Additionally, the main image used is the `all` image, it copies the binaries from all runners together into one.

`make build` will build all tool-specific runners and then the `all` runner.


Two tools have no builder stage and are installed directly in the `all` runner
from pinned upstream releases: Verible (static release tarball) and KLayout
(klayout.de's Ubuntu 24.04 `.deb`, SHA-256-checked, at the version
IHP-Open-PDK pins). `smoke-test.sh` checks every tool's version inside the
built image.
