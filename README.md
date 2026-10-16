# Zyra

An original AArch64 JIT written in Zig for x86-64 Windows and Linux.
It generates integer machine code, links validated blocks and supports
memory and SIMD operations through predecoded helpers.

Requires Zig 0.17.0.

```sh
zig build test
zig build test -Doptimize=ReleaseFast
```

Consumers provide CPU state, memory access and exact floating-point leaves.
Standalone tests use a small fixture. Interpreter differential tests run when
the supplied CPU has `stepFetched`; the standalone fixture skips those tests.

See [integration](docs/integration.md) and [design](docs/design.md).

No NeXium or Dynarmic implementation is included.
