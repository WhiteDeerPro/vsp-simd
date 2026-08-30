# Routing architecture analysis (historical index)

This file previously contained an exploratory routing proposal.  Its cost
estimates, encoding suggestions, and scale-out decisions are not current
architecture commitments and have therefore been removed.

The authoritative routing description is [routing.md](routing.md).  In
particular, use that document for:

- the internal SIMD4-local route boundary and indexed-memory semantics;
- the retired status of wider cross-group register-routing experiments;
- `VGATHER`/`VSCATTER` and their memory-system trade-offs;
- unresolved questions and implementation constraints.

Historical context: this filename is retained only so older notes and links do
not break.  Do not use it as an instruction-format or RTL implementation
specification.
