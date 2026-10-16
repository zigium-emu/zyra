const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.cpu.arch == .x86_64 and
    (builtin.os.tag == .windows or builtin.os.tag == .linux);

extern "kernel32" fn FlushInstructionCache(
    process: std.os.windows.HANDLE,
    address: *const anyopaque,
    size: usize,
) callconv(.winapi) std.os.windows.BOOL;

fn allocationSize(length: usize) !usize {
    if (length == 0) return error.EmptyCode;
    const page_size = std.heap.pageSize();
    const padded = std.math.add(usize, length, page_size - 1) catch return error.CodeSizeOverflow;
    return padded & ~(page_size - 1);
}

pub const Code = struct {
    memory: []align(std.heap.page_size_min) const u8,

    pub fn init(bytes: []const u8) !Code {
        if (!supported) return error.UnsupportedHost;
        const length = try allocationSize(bytes.len);
        const pointer = std.heap.PageAllocator.map(length, .fromByteUnits(std.heap.pageSize())) orelse return error.OutOfMemory;
        const memory: []align(std.heap.page_size_min) u8 = @alignCast(pointer[0..length]);
        errdefer std.heap.PageAllocator.unmap(memory);
        @memcpy(memory[0..bytes.len], bytes);
        try std.process.protectMemory(memory, .{ .read = true, .execute = true });
        if (builtin.os.tag == .windows) {
            if (!FlushInstructionCache(std.os.windows.GetCurrentProcess(), memory.ptr, memory.len).toBool())
                return error.InstructionCacheFlushFailed;
        }
        return .{ .memory = memory };
    }

    pub fn entry(self: *const Code, comptime T: type) T {
        comptime {
            if (@typeInfo(T) != .pointer or @typeInfo(@typeInfo(T).pointer.child) != .@"fn")
                @compileError("Code.entry requires a function pointer");
            if (!@typeInfo(@typeInfo(T).pointer.child).@"fn".attrs.@"callconv".eql(.c))
                @compileError("Code.entry requires the C calling convention");
        }
        return @ptrCast(self.memory.ptr);
    }

    pub fn deinit(self: *Code) void {
        std.heap.PageAllocator.unmap(@constCast(self.memory));
        self.* = undefined;
    }
};

test "executable allocation rejects empty and overflowing lengths" {
    if (!supported) return error.SkipZigTest;
    try std.testing.expectError(error.EmptyCode, Code.init(&.{}));
    try std.testing.expectError(error.CodeSizeOverflow, allocationSize(std.math.maxInt(usize)));
    try std.testing.expectEqual(std.heap.pageSize(), try allocationSize(1));
    try std.testing.expectEqual(std.heap.pageSize(), try allocationSize(std.heap.pageSize()));
    try std.testing.expectEqual(2 * std.heap.pageSize(), try allocationSize(std.heap.pageSize() + 1));
}

test "sealed x64 code executes through the C ABI" {
    if (!supported) return error.SkipZigTest;
    var code = try Code.init(&.{ 0x48, 0xb8, 0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01, 0xc3 });
    defer code.deinit();
    const function = code.entry(*const fn () callconv(.c) u64);
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), function());
}

test "independent executable code remains valid across other code lifetimes" {
    if (!supported) return error.SkipZigTest;
    const Entry = *const fn () callconv(.c) u64;
    var first = try Code.init(&.{ 0x48, 0xb8, 0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe, 0xc3 });
    defer first.deinit();
    const function = first.entry(Entry);
    for (0..16) |_| {
        {
            var second = try Code.init(&.{ 0xb8, 0xef, 0xbe, 0xad, 0xde, 0xc3 });
            defer second.deinit();
            try std.testing.expect(first.memory.ptr != second.memory.ptr);
            try std.testing.expectEqual(@as(u64, 0xdeadbeef), second.entry(Entry)());
            try std.testing.expectEqual(@as(u64, 0xfedcba9876543210), function());
        }
        try std.testing.expectEqual(@as(u64, 0xfedcba9876543210), function());
    }
}
