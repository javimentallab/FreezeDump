# Changelog

## [0.1.0] - 2026-11-01

First version prepared for publication. Not released yet.

### Added
- Probe that starts a console process every 10 s. If it has not ended after 45 s, the system counts as hung.
- Live kernel dump on a hang, without a blue screen: up to 2 per hang, at least 150 s apart.
- Dump files opened in advance at startup, so a dump does not need to create a file during the hang, and written
  through to disk, so it does not depend on the file cache.
  A reserve that still holds data at startup is kept as `hang-*-rescued.dmp`.
- Log every 5 s with memory, input idle time, probe latency, top CPU and started and ended processes,
  written through to disk so that it survives a reset.
- `logs` and `dumps` folders readable by administrators only, locked again at every start, also with your own
  `dataDir`.
- `DUMP STUCK` log line and notification when a dump takes over 30 s.
- Optional ntfy notifications and an optional TCP listener for a monitor on another machine. Both off by default.
- Simulation mode (`-Simulate`) with three scenarios, on a virtual clock and with made-up data.
- `install.ps1` and `uninstall.ps1`, both with `-WhatIf`.
- Tests with no dependencies, and test, Trivy, CodeQL and PSScriptAnalyzer workflows.

### Known limitations
- The real-hang fix is unproven. See "Known limitations" in the README.
