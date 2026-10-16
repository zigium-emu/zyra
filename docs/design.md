# Design

The x64 emitter uses the host C ABI and a small guest register cache. It
generates integer operations and branches directly. Mixed blocks call
predecoded memory and vector helpers at exact instruction boundaries.

The cache owns immutable executable allocations sealed from writable to
readable/executable memory. Blocks stay within a guest page. Every execution
validates current executable bytes, including linked successors. Stores end
the block before a potentially modified successor executes. Linked slots use
generation checks so eviction cannot leave usable stale targets.

SIMD moves preserve raw register bits. Integer lane arithmetic uses Zig
vectors. Normal f32 add/subtract/multiply have guarded native vector paths;
other supported FP operations use host-provided exact guest semantics.
Unsupported or reserved instructions decline to the host interpreter.

This is an original project extracted from Zigium's original Zig CPU backend.
It contains no Switch services, graphics backend, game data or full interpreter.
Standalone fixtures and native tests are independent of Zigium. The retained
differential tests require a real interpreter binding and skip otherwise.
