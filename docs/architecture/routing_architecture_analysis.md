# Routing architecture analysis (historical index)

This file previously contained an exploratory routing proposal.  Its cost
estimates, encoding suggestions, and scale-out decisions are not current
architecture commitments and have therefore been removed.

The authoritative routing description is [routing.md](routing.md).  In
particular, use that document for:

- the internal SIMD4-local route path and the VRF-indexed vector instruction
  semantics;
- the status of wider cross-group routing experiments;
- the boundary between register permutation and indexed memory access;
- unresolved questions and implementation constraints.

Historical context: this filename is retained only so older notes and links do
not break.  Do not use it as an instruction-format or RTL implementation
specification.
