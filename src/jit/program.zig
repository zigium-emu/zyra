const std = @import("std");
const builtin = @import("builtin");
const Cpu = @import("zyra_host").Cpu;
const Memory = @import("zyra_host").Memory;
const integer = @import("x64.zig");
pub const memory_ops = @import("memory.zig");
pub const vector_ops = @import("vector.zig");
const executable = @import("executable.zig");

pub fn supports(word: u32) bool {
    return integer.supports(word) or memory_ops.supports(word) or vector_ops.supports(word);
}

pub fn terminal(word: u32) bool {
    if (integer.terminal(word)) return true;
    return if (memory_ops.decode(word)) |operation| operation.mayWrite() else false;
}

const Operation = struct {
    word: u32,
    value: union(enum) { memory: memory_ops.Operation, vector: vector_ops.Decoded },
};

pub const Context = struct {
    cpu: *Cpu,
    memory: *Memory,
    retired: u32 = 0,
    native_count: u32 = 0,
    memory_count: u32 = 0,
    vector_count: u32 = 0,
    fault: ?anyerror = null,
};

const Entry = *const fn (*Context) callconv(.c) void;
const Leaf = *const fn (*Cpu) callconv(.c) void;

pub const Program = struct {
    code: executable.Code,
    operations: []Operation = &.{},
    mixed: bool,
    length: u32,

    pub fn init(allocator: std.mem.Allocator, words: []const u32, pc: u64) !Program {
        if (words.len == 0) return error.EmptyBlock;
        if (pc & 3 != 0) return error.UnalignedInstruction;
        var operation_count: usize = 0;
        for (words, 0..) |word, index| {
            if (!supports(word)) return error.UnsupportedInstruction;
            if (terminal(word) and index + 1 != words.len) return error.InvalidBlock;
            if (!integer.supports(word)) operation_count += 1;
        }
        if (operation_count == 0) {
            const bytes = try integer.compile(allocator, words, pc);
            defer allocator.free(bytes);
            return .{ .code = try executable.Code.init(bytes), .mixed = false, .length = @intCast(words.len) };
        }
        const operations = try allocator.alloc(Operation, operation_count);
        errdefer allocator.free(operations);
        var emitter: Emitter = .{ .allocator = allocator };
        defer emitter.bytes.deinit(allocator);
        defer emitter.exits.deinit(allocator);
        try emitter.put(&.{ 0x41, 0x54 });
        try emitter.put(if (builtin.os.tag == .windows) &.{ 0x49, 0x89, 0xcc } else &.{ 0x49, 0x89, 0xfc });
        if (builtin.os.tag == .windows) try emitter.put(&.{ 0x48, 0x83, 0xec, 0x20 });
        var cursor: usize = 0;
        var operation_index: usize = 0;
        while (cursor < words.len) {
            if (integer.supports(words[cursor])) {
                const first = cursor;
                while (cursor < words.len and integer.supports(words[cursor])) : (cursor += 1) {}
                const bytes = try integer.compile(allocator, words[first..cursor], pc +% @as(u64, @intCast(first * 4)));
                defer allocator.free(bytes);
                if (bytes.len == 0 or bytes[bytes.len - 1] != 0xc3) return error.InvalidBlock;
                try emitter.cpuArgument();
                try emitter.put(bytes[0 .. bytes.len - 1]);
                try emitter.addContext(@offsetOf(Context, "retired"), @intCast(cursor - first));
                try emitter.addContext(@offsetOf(Context, "native_count"), @intCast(cursor - first));
            } else {
                const word = words[cursor];
                operations[operation_index] = .{ .word = word, .value = if (memory_ops.decode(word)) |operation| .{ .memory = operation } else .{ .vector = vector_ops.decode(word) orelse return error.UnsupportedInstruction } };
                try emitter.callOperation(&operations[operation_index]);
                operation_index += 1;
                cursor += 1;
            }
        }
        const exit = emitter.bytes.items.len;
        if (builtin.os.tag == .windows) try emitter.put(&.{ 0x48, 0x83, 0xc4, 0x20 });
        try emitter.put(&.{ 0x41, 0x5c, 0xc3 });
        for (emitter.exits.items) |offset| std.mem.writeInt(i32, emitter.bytes.items[offset..][0..4], @intCast(exit - offset - 4), .little);
        return .{ .code = try executable.Code.init(emitter.bytes.items), .operations = operations, .mixed = true, .length = @intCast(words.len) };
    }

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        self.code.deinit();
        allocator.free(self.operations);
        self.* = undefined;
    }

    pub fn execute(self: *const Program, cpu: *Cpu, memory: *Memory) Context {
        var context: Context = .{ .cpu = cpu, .memory = memory };
        if (self.mixed) self.code.entry(Entry)(&context) else {
            self.code.entry(Leaf)(cpu);
            context.retired = self.length;
            context.native_count = self.length;
        }
        return context;
    }
};

fn executeOperation(context: *Context, operation: *const Operation) callconv(.c) u32 {
    switch (operation.value) {
        .memory => |decoded| {
            decoded.execute(context.cpu, context.memory) catch |err| {
                context.fault = err;
                return 0;
            };
            context.memory_count += 1;
        },
        .vector => |decoded| {
            context.cpu.last_pc = context.cpu.pc;
            context.cpu.last_instruction = operation.word;
            vector_ops.executeDecoded(context.cpu, decoded) catch |err| {
                context.fault = err;
                return 0;
            };
            context.cpu.pc +%= 4;
            context.cpu.counter +%= 1;
            context.vector_count += 1;
        },
    }
    context.retired += 1;
    return 1;
}

const Emitter = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    exits: std.ArrayList(usize) = .empty,

    fn put(self: *Emitter, bytes: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, bytes);
    }

    fn word(self: *Emitter, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.put(&bytes);
    }

    fn immediate(self: *Emitter, register: u8, value: u64) !void {
        try self.put(&.{ 0x48, 0xb8 + register });
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.put(&bytes);
    }

    fn cpuArgument(self: *Emitter) !void {
        try self.put(&.{ 0x49, 0x8b, if (builtin.os.tag == .windows) 0x8c else 0xbc, 0x24 });
        try self.word(@offsetOf(Context, "cpu"));
    }

    fn addContext(self: *Emitter, offset: u32, count: u32) !void {
        try self.put(&.{ 0x41, 0x81, 0x84, 0x24 });
        try self.word(offset);
        try self.word(count);
    }

    fn callOperation(self: *Emitter, operation: *const Operation) !void {
        try self.put(if (builtin.os.tag == .windows) &.{ 0x4c, 0x89, 0xe1 } else &.{ 0x4c, 0x89, 0xe7 });
        try self.immediate(if (builtin.os.tag == .windows) 2 else 6, @intFromPtr(operation));
        try self.immediate(0, @intFromPtr(&executeOperation));
        try self.put(&.{ 0xff, 0xd0, 0x85, 0xc0, 0x0f, 0x84 });
        try self.exits.append(self.allocator, self.bytes.items.len);
        try self.word(0);
    }
};

test "Zyra mixed generated blocks preserve helper boundaries and fault retirement" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    if (!executable.supported) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try memory.map(0x4000, 4096, .{ .read = true, .write = true });
    try memory.writeInt(u64, 0x4000, 0x123456789abcdef0);
    const words = [_]u32{ 0x91000442, 0xf9400020, 0x91001c00, 0xf9000020 };
    for (words, 0..) |value, index| try memory.writeInt(u32, 0x1000 + index * 4, value);
    var program = try Program.init(std.testing.allocator, &words, 0x1000);
    defer program.deinit(std.testing.allocator);
    var cpu: Cpu = .{ .pc = 0x1000, .sp = 0x8000, .nzcv = 13, .fpcr = 0x400000, .fpsr = 0x8010091 };
    cpu.x[1] = 0x4000;
    var reference = cpu;
    for (words) |_| _ = try reference.step(&memory);
    try memory.writeInt(u64, 0x4000, 0x123456789abcdef0);
    const result = program.execute(&cpu, &memory);
    try std.testing.expectEqual(@as(u32, 4), result.retired);
    try std.testing.expectEqual(@as(u32, 2), result.native_count);
    try std.testing.expectEqual(@as(u32, 2), result.memory_count);
    try std.testing.expectEqual(@as(?anyerror, null), result.fault);
    try std.testing.expectEqualDeep(reference, cpu);
    try std.testing.expectEqual(@as(u64, 0x123456789abcdef7), try memory.readInt(u64, 0x4000));
    cpu = .{ .pc = 0x1000 };
    cpu.x[1] = 0x8000;
    reference = cpu;
    _ = try reference.step(&memory);
    try std.testing.expectError(error.MemoryFault, reference.step(&memory));
    const faulted = program.execute(&cpu, &memory);
    try std.testing.expectEqual(@as(u32, 1), faulted.retired);
    try std.testing.expectEqual(@as(?anyerror, error.MemoryFault), faulted.fault);
    try std.testing.expectEqualDeep(reference, cpu);
}
