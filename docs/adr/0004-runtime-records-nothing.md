---
status: accepted
---

# The runtime records nothing; diagnostics are a separate, optional debugger

Diagnosing this helper needs keyboard and mouse events, window positions and
focus changes, and that data must not be collected during normal play. The
installed runtime contains no diagnostic input logger. Diagnostics run only in
a separate, observation-only debugger that Setup installs on request, that runs
only in a debug session the user starts, and that Setup can remove again.

## Considered options

- **A switchable log mode inside the runtime:** the runtime that runs during
  play would then carry keyboard and mouse logging code.
