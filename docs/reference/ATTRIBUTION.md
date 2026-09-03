# Third-party reference material

## `6502_cpu.txt`

Source: the "64doc" NMOS 6502/6510/8500/8502 instruction-set documentation
(`$Id: 64doc,v 1.8 1994/06/03 19:50:04 jopi Exp $`), written by John West
(john@ucc.gu.uwa.edu.au) and Marko Mäkelä (msmakela@kruuna.helsinki.fi) as
part of the Commodore 64 emulator and Program Development System (X64).

No explicit license or copyright statement accompanies the file itself. It
has circulated freely in the NES/C64 emulator-development community for
decades (it's the document commonly linked from NESdev as "64doc") and is
vendored here, unmodified, purely as a reference for implementing the CPU
core — same "no formal grant, believed freely redistributable per
longstanding community practice" posture already applied to the Blargg/
nestest test ROMs (see [`docs/research/test-rom-licensing.md`](../research/test-rom-licensing.md)).

**Scope note:** this document describes the Commodore 64's 6510/8500/8502
variants, including C64-specific I/O examples (VIC-II, CIA) and the NMOS
decimal (BCD) mode. The NES's 2A03/2A07 CPU shares the same core
instruction set and undocumented-opcode behavior, but disables BCD
arithmetic in hardware (`SED`/`CLD` still toggle the D flag bit, but
`ADC`/`SBC` never perform decimal correction). Treat the opcode matrix,
flag semantics, undocumented-opcode behavior, and cycle-by-cycle timing
tables as directly applicable; disregard the Decimal-mode section's
arithmetic behavior and the C64-specific interrupt-acknowledgment examples.
