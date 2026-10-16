const std = @import("std");
const Cpu = @import("zyra_host").Cpu;
const Memory = @import("zyra_host").Memory;

const Kind = enum { transfer, literal, pair };
const AddressMode = enum { offset, post, pre, register };

pub const Operation = struct {
    instruction: u32,
    kind: Kind,
    mode: AddressMode = .offset,
    bytes: u8,
    result_width: u7 = 64,
    load: bool,
    vector: bool,
    signed: bool = false,
    prefetch: bool = false,
    rt: u5,
    rn: u5 = 31,
    rt2: u5 = 31,
    rm: u5 = 31,
    offset: u64 = 0,
    option: u3 = 0,
    shift: u3 = 0,

    pub fn mayWrite(self: Operation) bool {
        return !self.load and !self.prefetch;
    }

    pub fn execute(self: Operation, cpu: *Cpu, memory: *Memory) !void {
        std.debug.assert(cpu.pc & 3 == 0);
        cpu.last_pc = cpu.pc;
        cpu.last_instruction = self.instruction;
        try self.transfer(cpu, memory);
        cpu.pc +%= 4;
        cpu.counter +%= 1;
    }

    fn transfer(self: Operation, cpu: *Cpu, memory: *Memory) !void {
        if (self.prefetch) return;
        const base = if (self.kind == .literal) cpu.pc else readRegister(cpu, self.rn, true);
        const offset = if (self.mode == .register) extend(readRegister(cpu, self.rm, false), self.option) << self.shift else self.offset;
        const address = if (self.mode == .post) base else base +% offset;
        if (self.kind == .pair) {
            if (self.load) {
                const first = try readSized(memory, address, self.bytes);
                const second = try readSized(memory, address +% self.bytes, self.bytes);
                self.setLoaded(cpu, self.rt, first);
                self.setLoaded(cpu, self.rt2, second);
            } else {
                try writeSized(memory, address, self.bytes, self.stored(cpu, self.rt));
                try writeSized(memory, address +% self.bytes, self.bytes, self.stored(cpu, self.rt2));
                cpu.clearExclusive();
            }
        } else if (self.load) {
            self.setLoaded(cpu, self.rt, try readSized(memory, address, self.bytes));
        } else {
            try writeSized(memory, address, self.bytes, self.stored(cpu, self.rt));
            cpu.clearExclusive();
        }
        if (self.mode == .pre or self.mode == .post) setRegister(cpu, self.rn, base +% offset, 64, true);
    }

    fn stored(self: Operation, cpu: *const Cpu, rt: u5) u128 {
        return if (self.vector) cpu.v[rt] else readRegister(cpu, rt, false);
    }

    fn setLoaded(self: Operation, cpu: *Cpu, rt: u5, value: u128) void {
        if (self.vector) {
            cpu.v[rt] = value;
        } else {
            const scalar: u64 = @truncate(value);
            setRegister(cpu, rt, if (self.signed) signExtend(scalar, @intCast(self.bytes * 8)) else scalar, self.result_width, false);
        }
    }
};

pub fn supports(instruction: u32) bool {
    return decode(instruction) != null;
}

pub fn decode(instruction: u32) ?Operation {
    return decodeChecked(instruction) catch null;
}

pub fn execute(cpu: *Cpu, memory: *Memory, instruction: u32) !void {
    std.debug.assert(cpu.pc & 3 == 0);
    cpu.last_pc = cpu.pc;
    cpu.last_instruction = instruction;
    const operation = (try decodeChecked(instruction)) orelse return error.UnsupportedInstruction;
    try operation.transfer(cpu, memory);
    cpu.pc +%= 4;
    cpu.counter +%= 1;
}

fn decodeChecked(ins: u32) !?Operation {
    const rt: u5 = @truncate(ins);
    const rn: u5 = @truncate(ins >> 5);
    const vector = ins & 0x04000000 != 0;
    const size: u2 = @truncate(ins >> 30);
    const opc: u2 = @truncate(ins >> 22);

    if (ins & 0x3b000000 == 0x18000000) {
        if (vector and size == 3) return error.UndefinedInstruction;
        return .{
            .instruction = ins,
            .kind = .literal,
            .bytes = if (vector) @as(u8, 4) << size else if (size == 1) 8 else 4,
            .load = true,
            .vector = vector,
            .signed = !vector and size == 2,
            .prefetch = !vector and size == 3,
            .result_width = if (size == 0) 32 else 64,
            .rt = rt,
            .offset = signExtend((ins >> 5) & 0x7ffff, 19) *% 4,
        };
    }
    if (ins & 0x3a000000 == 0x28000000) {
        const load = ins & 0x00400000 != 0;
        if (size == 3 or (!vector and size == 1 and !load)) return error.UndefinedInstruction;
        const bytes: u8 = if (vector) @as(u8, 4) << size else if (size == 2) 8 else 4;
        const rt2: u5 = @truncate(ins >> 10);
        const mode: u2 = @truncate(ins >> 23);
        if (!vector and size == 1 and mode == 0) return error.UndefinedInstruction;
        const writeback = mode == 1 or mode == 3;
        if ((load and rt == rt2) or (!vector and writeback and rn != 31 and (rn == rt or rn == rt2))) return error.InvalidRegisterEncoding;
        return .{
            .instruction = ins,
            .kind = .pair,
            .mode = if (mode == 1) .post else if (mode == 3) .pre else .offset,
            .bytes = bytes,
            .result_width = if (size == 0) 32 else 64,
            .load = load,
            .vector = vector,
            .signed = !vector and size == 1,
            .rt = rt,
            .rt2 = rt2,
            .rn = rn,
            .offset = signExtend((ins >> 15) & 0x7f, 7) *% bytes,
        };
    }
    var operation: Operation = .{
        .instruction = ins,
        .kind = .transfer,
        .bytes = if (vector and opc >= 2) 16 else @as(u8, 1) << size,
        .result_width = if (size == 3 or opc == 2) 64 else 32,
        .load = if (vector) opc & 1 != 0 else opc != 0,
        .vector = vector,
        .signed = !vector and opc >= 2,
        .prefetch = !vector and size == 3 and opc == 2,
        .rt = rt,
        .rn = rn,
    };
    if (ins & 0x3b000000 == 0x39000000) {
        operation.offset = @as(u64, (ins >> 10) & 0xfff) * operation.bytes;
    } else if (ins & 0x3b200000 == 0x38000000) {
        const mode: u2 = @truncate(ins >> 10);
        const writeback = mode == 1 or mode == 3;
        if (ins & 0xffc00000 == 0xf8800000 and mode != 0) return error.UndefinedInstruction;
        if (writeback and rt == rn and rn != 31 and !vector) return error.InvalidRegisterEncoding;
        operation.mode = if (mode == 1) .post else if (mode == 3) .pre else .offset;
        operation.offset = signExtend((ins >> 12) & 0x1ff, 9);
    } else if (ins & 0x3b200c00 == 0x38200800) {
        operation.mode = .register;
        operation.option = @truncate(ins >> 13);
        if (operation.option & 2 == 0) return error.UndefinedInstruction;
        operation.rm = @truncate(ins >> 16);
        operation.shift = if (ins & 0x1000 == 0) 0 else if (vector and opc >= 2) 4 else size;
    } else return null;
    if (vector) {
        if (opc >= 2 and size != 0) return error.UndefinedInstruction;
    } else if (!operation.prefetch and ((size >= 2 and opc == 3) or (size == 3 and opc >= 2))) return error.UndefinedInstruction;
    return operation;
}

fn readRegister(cpu: *const Cpu, index: u5, use_sp: bool) u64 {
    return if (index == 31) (if (use_sp) cpu.sp else 0) else cpu.x[index];
}

fn setRegister(cpu: *Cpu, index: u5, value: u64, width: u7, use_sp: bool) void {
    const result = value & mask(width);
    if (index == 31) {
        if (use_sp) cpu.sp = result;
    } else cpu.x[index] = result;
}

fn mask(width: u7) u64 {
    return if (width == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(width)) - 1;
}

fn signExtend(value: u64, bits: u7) u64 {
    const sign = @as(u64, 1) << @intCast(bits - 1);
    return ((value & mask(bits)) ^ sign) -% sign;
}

fn extend(value: u64, option: u3) u64 {
    const bits: u7 = @as(u7, 8) << @as(u2, @truncate(option));
    return if (option & 4 != 0) signExtend(value, bits) else value & mask(bits);
}

fn readSized(memory: *Memory, address: u64, bytes: u8) !u128 {
    return switch (bytes) {
        1 => try memory.readInt(u8, address),
        2 => try memory.readInt(u16, address),
        4 => try memory.readInt(u32, address),
        8 => try memory.readInt(u64, address),
        16 => try memory.readInt(u128, address),
        else => unreachable,
    };
}

fn writeSized(memory: *Memory, address: u64, bytes: u8, value: u128) !void {
    switch (bytes) {
        1 => try memory.writeInt(u8, address, @truncate(value)),
        2 => try memory.writeInt(u16, address, @truncate(value)),
        4 => try memory.writeInt(u32, address, @truncate(value)),
        8 => try memory.writeInt(u64, address, @truncate(value)),
        16 => try memory.writeInt(u128, address, value),
        else => unreachable,
    }
}

fn initialCpu() Cpu {
    var cpu: Cpu = .{
        .pc = 0x1800,
        .sp = 0x3103,
        .last_pc = 0x12345678,
        .last_instruction = 0xabcdef01,
        .nzcv = 13,
        .tpidrro_el0 = 0x1122334455667788,
        .tpidr_el0 = 0x8877665544332211,
        .fpcr = 0x03c09f00,
        .fpsr = 0x08000091,
        .counter = std.math.maxInt(u64),
        .counter_frequency = 123456789,
        .exclusive_address = 0x3003,
        .exclusive_size = 8,
    };
    for (&cpu.x, 0..) |*value, index| value.* = 0xfedcba9876543210 ^ (@as(u64, @intCast(index)) * 0x102030405060708);
    for (&cpu.v, 0..) |*value, index| value.* = 0xffeeddccbbaa99887766554433221100 ^ (@as(u128, @intCast(index)) * 0x102030405060708090a0b0c0d0e0f00);
    cpu.x[1] = 0x3003;
    cpu.x[2] = 3;
    return cpu;
}

fn testMemory() !Memory {
    var memory = Memory.init(std.testing.allocator);
    errdefer memory.deinit();
    try memory.map(0x1000, 0x5000, .{ .read = true, .write = true, .execute = true });
    var bytes: [0x5000]u8 = undefined;
    for (&bytes, 0..) |*value, index| value.* = @truncate(index *% 37 +% (index >> 5) +% 0x81);
    try memory.write(0x1000, &bytes);
    return memory;
}

fn compareInstruction(instruction: u32, initial: Cpu, reference_memory: *Memory, actual_memory: *Memory) !void {
    return compareInstructionMode(instruction, initial, reference_memory, actual_memory, true);
}

fn compareInstructionMode(instruction: u32, initial: Cpu, reference_memory: *Memory, actual_memory: *Memory, comptime predecoded: bool) !void {
    var reference = initial;
    var actual = initial;
    const expected_error: ?anyerror = blk: {
        _ = reference.stepFetched(reference_memory, instruction) catch |err| break :blk err;
        break :blk null;
    };
    const actual_error: ?anyerror = blk: {
        if (if (predecoded) decode(instruction) else null) |operation| {
            operation.execute(&actual, actual_memory) catch |err| break :blk err;
        } else execute(&actual, actual_memory, instruction) catch |err| break :blk err;
        break :blk null;
    };
    try std.testing.expectEqual(expected_error, actual_error);
    try std.testing.expectEqualDeep(reference, actual);
    var expected_bytes: [0x5000]u8 = undefined;
    var actual_bytes: [0x5000]u8 = undefined;
    for ([_]u64{ 0x1000, 0x2000, 0x3000, 0x4000, 0x5000 }) |address| {
        const expected_read: ?anyerror = blk: {
            reference_memory.read(address, expected_bytes[0..0x1000]) catch |err| break :blk err;
            break :blk null;
        };
        const actual_read: ?anyerror = blk: {
            actual_memory.read(address, actual_bytes[0..0x1000]) catch |err| break :blk err;
            break :blk null;
        };
        try std.testing.expectEqual(expected_read, actual_read);
        if (expected_read == null) try std.testing.expectEqualSlices(u8, expected_bytes[0..0x1000], actual_bytes[0..0x1000]);
    }
}

fn differential(instruction: u32) !void {
    var reference = try testMemory();
    defer reference.deinit();
    var actual = try testMemory();
    defer actual.deinit();
    try compareInstruction(instruction, initialCpu(), &reference, &actual);
}

test "Zyra scalar and SIMD immediate transfers match all operand widths and faults" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    for ([_]u32{ 0, 1 }) |vector| {
        for (0..4) |size| {
            for (0..4) |opc| {
                const prefix = (@as(u32, @intCast(size)) << 30) | (vector << 26) | (@as(u32, @intCast(opc)) << 22);
                for ([_]u32{ 0, 1, 31 }) |rt| {
                    for ([_]u32{ 1, 31 }) |rn| {
                        for ([_]u32{ 0, 1, 0xfff }) |offset| {
                            try differential(prefix | 0x39000000 | (offset << 10) | (rn << 5) | rt);
                        }
                        for (0..4) |mode| {
                            for ([_]u32{ 0, 1, 0xff, 0x100, 0x1ff }) |offset| {
                                try differential(prefix | 0x38000000 | (offset << 12) | (@as(u32, @intCast(mode)) << 10) | (rn << 5) | rt);
                            }
                        }
                    }
                }
            }
        }
    }
}

test "Zyra literal and extended register transfers match PC SP ZR and raw vector bits" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    for ([_]u32{ 0, 1 }) |vector| {
        for (0..4) |size| {
            for ([_]u32{ 0, 31 }) |rt| {
                for ([_]u32{ 0, 0x40, 0x7ffc0, 0x3ffff }) |offset| {
                    try differential((@as(u32, @intCast(size)) << 30) | (vector << 26) | 0x18000000 | (offset << 5) | rt);
                }
            }
            for (0..4) |opc| {
                const prefix = (@as(u32, @intCast(size)) << 30) | (vector << 26) | (@as(u32, @intCast(opc)) << 22);
                for (0..8) |option| {
                    for ([_]u32{ 0, 1 }) |scaled| {
                        for ([_]u32{ 0, 2, 31 }) |rm| {
                            try differential(prefix | 0x38200800 | (rm << 16) | (@as(u32, @intCast(option)) << 13) | (scaled << 12) | (1 << 5));
                        }
                    }
                }
            }
        }
    }
}

test "Zyra pair transfers preserve all addressing modes width sign and alias rules" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    for ([_]u32{ 0, 1 }) |vector| {
        for (0..4) |size| {
            for ([_]u32{ 0, 1 }) |load| {
                for (0..4) |mode| {
                    const prefix = (@as(u32, @intCast(size)) << 30) | (vector << 26) | (load << 22) | (@as(u32, @intCast(mode)) << 23);
                    for ([_]u32{ 0, 1, 31 }) |rt| {
                        for ([_]u32{ 0, 1, 31 }) |rt2| {
                            for ([_]u32{ 1, 31 }) |rn| {
                                for ([_]u32{ 0, 1, 0x3f, 0x40, 0x7f }) |offset| {
                                    try differential(prefix | 0x28000000 | (offset << 15) | (rt2 << 10) | (rn << 5) | rt);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

test "Zyra crossing accesses and faulting pairs preserve partial stores and monitor state" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    for ([_]u32{ 0xf9400020, 0xf9000020, 0x3dc00020, 0x3d800020, 0xa9400820, 0xa9000820, 0xad400820, 0xad000820, 0xa8c10820, 0xa8810820 }) |instruction| {
        for ([_]u64{ 0x3fff, 0x3ff8, 0x3ff0, 0x5fff, 0x5ff8, 0x5ff0, 0xfffffffffffffff8 }) |address| {
            for ([_]bool{ false, true }) |deny| {
                var reference = try testMemory();
                defer reference.deinit();
                var actual = try testMemory();
                defer actual.deinit();
                if (deny) {
                    try reference.protect(0x4000, 0x1000, .{});
                    try actual.protect(0x4000, 0x1000, .{});
                }
                var cpu = initialCpu();
                cpu.x[1] = address;
                try compareInstruction(instruction, cpu, &reference, &actual);
            }
        }
    }
}

test "Zyra direct helper and predecode preserve signed register offsets and ignored prefetches" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    for ([_]u32{ 0xf9400020, 0xf9000020, 0x39800020, 0x39c00020, 0x79800020, 0x79c00020, 0xb9800020, 0x3dc00020, 0xa9400820, 0xad000820, 0xd8000800, 0xf9800020, 0xf8a26820 }) |instruction| {
        var reference = try testMemory();
        defer reference.deinit();
        var actual = try testMemory();
        defer actual.deinit();
        try compareInstructionMode(instruction, initialCpu(), &reference, &actual, false);
    }
    for ([_]u64{ 0xfffffffffffffffd, 0x12345678fffffffd, 0x1234567800000003 }) |offset| {
        for ([_]u32{ 2, 3, 6, 7 }) |option| {
            for ([_]u32{ 0, 1 }) |scaled| {
                var reference = try testMemory();
                defer reference.deinit();
                var actual = try testMemory();
                defer actual.deinit();
                var cpu = initialCpu();
                cpu.x[2] = offset;
                try compareInstruction(0xf8620820 | (option << 13) | (scaled << 12), cpu, &reference, &actual);
            }
        }
    }
    const nonaccessing = [_]u32{ 0xd8000000, 0xf9800020, 0xf8800020, 0xf8a26820 };
    var empty = Memory.init(std.testing.allocator);
    defer empty.deinit();
    for (nonaccessing) |instruction| {
        var cpu = initialCpu();
        const monitor = cpu.exclusive_address;
        try execute(&cpu, &empty, instruction);
        try std.testing.expectEqual(@as(u64, 0x1804), cpu.pc);
        try std.testing.expectEqual(@as(u64, 0), cpu.counter);
        try std.testing.expectEqual(monitor, cpu.exclusive_address);
        try std.testing.expect(!decode(instruction).?.mayWrite());
    }
}

test "Zyra predecoded memory observes permission changes aliases remaps and code writes" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x2000, 0x1000, .{ .read = true, .write = true, .execute = true });
    var cpu = initialCpu();
    cpu.x[1] = 0x2000;
    const load = decode(0xf9400020).?;
    const store = decode(0xf9000020).?;
    try memory.writeInt(u64, 0x2000, 0x1122334455667788);
    try load.execute(&cpu, &memory);
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), cpu.x[0]);
    try memory.protect(0x2000, 0x1000, .{ .execute = true });
    try std.testing.expectError(error.AccessDenied, load.execute(&cpu, &memory));
    try std.testing.expectError(error.AccessDenied, store.execute(&cpu, &memory));
    try memory.protect(0x2000, 0x1000, .{ .read = true, .write = true });
    try memory.mapAlias(0x8000, 0x2000, 0x1000);
    try std.testing.expectError(error.AccessDenied, load.execute(&cpu, &memory));
    cpu.x[1] = 0x8000;
    cpu.x[0] = 0x876543210fedcba9;
    try store.execute(&cpu, &memory);
    cpu.x[0] = 0;
    try load.execute(&cpu, &memory);
    try std.testing.expectEqual(@as(u64, 0x876543210fedcba9), cpu.x[0]);
    try memory.unmapAlias(0x8000, 0x2000, 0x1000);
    try std.testing.expectError(error.MemoryFault, load.execute(&cpu, &memory));
    cpu.x[1] = 0x2000;
    try load.execute(&cpu, &memory);
    try std.testing.expectEqual(@as(u64, 0x876543210fedcba9), cpu.x[0]);
    try memory.unmap(0x2000, 0x1000);
    try std.testing.expectError(error.MemoryFault, load.execute(&cpu, &memory));
    try memory.map(0x2000, 0x1000, .{ .read = true, .write = true, .execute = true });
    try load.execute(&cpu, &memory);
    try std.testing.expectEqual(@as(u64, 0), cpu.x[0]);
    cpu.x[0] = 0xd503201f;
    try store.execute(&cpu, &memory);
    try std.testing.expectEqual(@as(u32, 0xd503201f), try memory.fetch(0x2000));
    try std.testing.expect(!supports(0xc85f7c20));
    try std.testing.expect(!supports(0xc8007c22));
}
