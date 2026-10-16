const std = @import("std");
pub const name = "Zyra JIT";
pub const Jit = @import("jit.zig").Jit;
pub const Zyra = Jit;
pub const supported = @import("jit.zig").supported;
pub const integer = @import("jit/x64.zig");
pub const memory = @import("jit/memory.zig");
pub const vector = @import("jit/vector.zig");
pub const program = @import("jit/program.zig");
pub const executable = @import("jit/executable.zig");

test {
    std.testing.refAllDecls(@This());
}
