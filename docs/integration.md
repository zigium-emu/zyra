# Host integration

Add a path dependency named `zyra`, then bind the host module:

```zig
const dependency = b.dependency("zyra", .{ .target = target, .optimize = optimize });
const zyra = dependency.module("zyra");
zyra.addImport("zyra_host", host);
application.addImport("zyra", zyra);
```

The `zyra_host` module exports `Cpu`, `Memory` and `address_limit: u64`.
The host owns guest scheduling, instruction fallback and exception delivery.
Keep one binding module per Zyra module instance.

CPU state must expose `x: [31]u64`, `v: [32]u128`, `sp`, `pc`, `last_pc`,
`last_instruction`, `counter`, `nzcv`, `fpcr` and `fpsr`. Native emitters use
the actual host type's field offsets. `Cpu.clearExclusive()` invalidates the
exclusive monitor after a successful store.

The host supplies exact FP leaf methods `evaluateFloatVector`,
`evaluateFloatFused`, `evaluateFloatCompare` and `evaluateFloatConvert` with
the signatures shown by [the standalone fixture](../tests/host.zig).
They must preserve current FPCR rounding, FZ, DN, traps and sticky FPSR flags.
The fixture intentionally reports `ExactFloatingPointUnavailable` for these
leaves; it does not supply an emulator or substitute approximate arithmetic.

Memory supplies `fetch(address) !u32`, `executableBytes(address, length)
![]const u8`, `readInt(T, address) !T` and `writeInt(T, address, value) !void`.
All accesses must enforce current permissions. Executable slices must stay
valid through each execution call, and reflect aliases and writable changes.
Integer reads and writes follow the guest's little-endian order. Pair stores
are two ordered accesses: a fault in the second can retain the first store.

```zig
var jit = zyra.Jit.init(allocator);
defer jit.deinit();
const retired = jit.executeLinked(&cpu, &memory, remaining_quantum);
```

The returned count is the successful prefix only. An attempted fault updates
`last_pc` and `last_instruction`, while PC and counter remain on the fault.
Advance clocks and scheduler state for the returned prefix before delivering
`jit.pending_fault`. If no instructions retire and no fault is pending, run the
host interpreter, optionally reusing `jit.fallback_instruction`.
Code fetch failure and unavailable compilation return zero for host fallback.
