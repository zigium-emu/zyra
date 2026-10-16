const std = @import("std");
const Cpu = @import("zyra_host").Cpu;
const Memory = @import("zyra_host").Memory;
const address_limit = @import("zyra_host").address_limit;
const backend = @import("jit/program.zig");
const executable = @import("jit/executable.zig");
pub const supported = executable.supported;
pub const name = "Zyra JIT";
pub const Zyra = Jit;

const max_words = 32;
const max_blocks = 16_384;
const max_negative = 4096;
const absent_pc = std.math.maxInt(u64);
const absent_slot = std.math.maxInt(u16);
const Link = struct { pc: u64, slot: u16, generation: u64 };
const Block = struct {
    bytes: [max_words * 4]u8 = @splat(0),
    length: u8,
    program: backend.Program,
    slot: u16 = absent_slot,
    links: [2]?Link = @splat(null),
    next_link: u1 = 0,

    fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        self.program.deinit(allocator);
    }
};
const Slot = struct { pc: u64 = absent_pc, previous: u16 = absent_slot, next: u16 = absent_slot, generation: u64 = 0, block: ?*Block = null };
const Negative = struct { pc: u64 = absent_pc, word: u32 = 0 };

fn writeLoop(memory: *Memory, address: u64, increment: u12) !void {
    try memory.writeInt(u32, address, 0x91000000 | (@as(u32, increment) << 10));
    try memory.writeInt(u32, address + 4, 0x17ffffff);
}

test "native blocks preserve interpreter state and obey complete block budgets" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try memory.writeInt(u32, 0x1000, 0xd503201f);
    try memory.writeInt(u32, 0x1004, 0x91000400);
    try memory.writeInt(u32, 0x1008, 0x17fffffe);
    var jit = Jit.init(std.testing.allocator);
    defer jit.deinit();
    var cpu: Cpu = .{ .pc = 0x1000, .sp = 0x3000, .nzcv = 13, .counter = std.math.maxInt(u64) - 1, .fpcr = 0x03c09f00, .fpsr = 0x08000091, .exclusive_address = 0x4000, .exclusive_size = 8 };
    cpu.x[0] = std.math.maxInt(u64);
    cpu.x[30] = 0x123456789abcdef0;
    cpu.v[31] = 0xffeeddccbbaa99887766554433221100;
    const initial = cpu;
    for (0..3) |budget| {
        try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, budget));
        try std.testing.expectEqualDeep(initial, cpu);
    }
    var interpreted = cpu;
    for (0..3) |_| _ = try interpreted.step(&memory);
    try std.testing.expectEqual(@as(u32, 3), jit.execute(&cpu, &memory, 3));
    try std.testing.expectEqualDeep(interpreted, cpu);
    try std.testing.expectEqual(@as(u64, 1), jit.compiled_blocks);
    for (0..3) |_| _ = try interpreted.step(&memory);
    try std.testing.expectEqual(@as(u32, 3), jit.execute(&cpu, &memory, 32));
    try std.testing.expectEqualDeep(interpreted, cpu);
    try std.testing.expectEqual(@as(u64, 6), jit.native_instructions);
    try std.testing.expectEqual(@as(u64, 1), jit.compiled_blocks);
}

test "cached code follows writable mutations negative entries permissions and remaps" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try writeLoop(&memory, 0x1000, 1);
    var jit = Jit.init(std.testing.allocator);
    defer jit.deinit();
    var cpu: Cpu = .{ .pc = 0x1000 };
    try std.testing.expectEqual(@as(u32, 2), jit.execute(&cpu, &memory, 2));
    try std.testing.expectEqual(@as(u64, 1), cpu.x[0]);
    try writeLoop(&memory, 0x1000, 7);
    try std.testing.expectEqual(@as(u32, 2), jit.execute(&cpu, &memory, 2));
    try std.testing.expectEqual(@as(u64, 8), cpu.x[0]);
    try std.testing.expectEqual(@as(u64, 2), jit.compiled_blocks);
    try memory.writeInt(u32, 0x1000, 0xd4000001);
    const before = cpu;
    for (0..2) |_| {
        try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
        try std.testing.expectEqualDeep(before, cpu);
    }
    try std.testing.expectEqual(@as(usize, 0), jit.blocks.count());
    try std.testing.expectEqual(@as(usize, 1), jit.negative_entries);
    try writeLoop(&memory, 0x1000, 3);
    try memory.protect(0x1000, 4096, .{ .execute = true });
    try std.testing.expectError(error.AccessDenied, memory.readInt(u32, 0x1000));
    try std.testing.expectEqual(@as(u32, 2), jit.execute(&cpu, &memory, 2));
    try std.testing.expectEqual(@as(u64, 11), cpu.x[0]);
    try memory.protect(0x1000, 4096, .{ .read = true });
    const denied = cpu;
    try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
    try std.testing.expectEqualDeep(denied, cpu);
    try std.testing.expectError(error.AccessDenied, cpu.step(&memory));
    try std.testing.expectEqualDeep(denied, cpu);
    try memory.unmap(0x1000, 4096);
    try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
    try std.testing.expectEqualDeep(denied, cpu);
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try writeLoop(&memory, 0x1000, 9);
    try std.testing.expectEqual(@as(u32, 2), jit.execute(&cpu, &memory, 2));
    try std.testing.expectEqual(@as(u64, 20), cpu.x[0]);
}

test "native lookahead preserves fault timing and stays within one guest page" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try memory.writeInt(u32, 0x1ffc, 0xd503201f);
    var jit = Jit.init(std.testing.allocator);
    defer jit.deinit();
    var cpu: Cpu = .{ .pc = 0x1ffc };
    try std.testing.expectEqual(@as(u32, 1), jit.execute(&cpu, &memory, 32));
    try std.testing.expectEqual(@as(u64, 0x2000), cpu.pc);
    try std.testing.expectEqual(@as(u64, 0x1ffc), cpu.last_pc);
    try std.testing.expectEqual(@as(u64, 1), cpu.counter);
    const before_fault = cpu;
    try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
    try std.testing.expectEqualDeep(before_fault, cpu);
    try std.testing.expectError(error.MemoryFault, cpu.step(&memory));
    try std.testing.expectEqualDeep(before_fault, cpu);
    cpu.pc = 0x1001;
    const unaligned = cpu;
    try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
    try std.testing.expectEqualDeep(unaligned, cpu);
    try std.testing.expectError(error.UnalignedInstruction, cpu.step(&memory));
    for ([_]u64{ address_limit, address_limit + 4, std.math.maxInt(u64) - 3 }) |address| {
        cpu.pc = address;
        const invalid = cpu;
        try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
        try std.testing.expectEqualDeep(invalid, cpu);
        try std.testing.expectError(error.MemoryFault, cpu.step(&memory));
        try std.testing.expectEqualDeep(invalid, cpu);
    }
}

test "native cache observes writes through shared backing aliases" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true });
    try writeLoop(&memory, 0x1000, 1);
    try memory.protect(0x1000, 4096, .{ .execute = true });
    var jit = Jit.init(std.testing.allocator);
    defer jit.deinit();
    var cpu: Cpu = .{ .pc = 0x1000 };
    try std.testing.expectEqual(@as(u32, 2), jit.execute(&cpu, &memory, 2));
    try std.testing.expectEqual(@as(u64, 1), cpu.x[0]);
    try memory.protect(0x1000, 4096, .{ .read = true, .write = true });
    try memory.mapAlias(0x3000, 0x1000, 4096);
    try writeLoop(&memory, 0x3000, 5);
    try memory.unmapAlias(0x3000, 0x1000, 4096);
    try memory.protect(0x1000, 4096, .{ .execute = true });
    try std.testing.expectEqual(@as(u32, 2), jit.execute(&cpu, &memory, 2));
    try std.testing.expectEqual(@as(u64, 6), cpu.x[0]);
}

test "native cache allocation failure leaves guest execution available" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try writeLoop(&memory, 0x1000, 1);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var jit = Jit.init(failing.allocator());
    defer jit.deinit();
    var cpu: Cpu = .{ .pc = 0x1000 };
    const initial = cpu;
    try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
    try std.testing.expectEqualDeep(initial, cpu);
    try std.testing.expectEqual(@as(u64, 0), jit.native_instructions);
    _ = try cpu.step(&memory);
    try std.testing.expectEqual(@as(u64, 1), cpu.x[0]);
}

fn writePressureBlock(memory: *Memory, address: u64) !void {
    for ([_]u32{ 0x91000400, 0x910043ff, 0x91000800, 0x910083ff, 0x91000c01, 0x17fffffb }, 0..) |word, index|
        try memory.writeInt(u32, address + index * 4, word);
}

fn expectPressureBlock(jit: *Jit, cpu: *Cpu, memory: *Memory, pc: u64) !void {
    cpu.pc = pc;
    var reference = cpu.*;
    for (0..6) |_| _ = try reference.step(memory);
    try std.testing.expectEqual(@as(u32, 6), jit.execute(cpu, memory, 6));
    try std.testing.expectEqualDeep(reference, cpu.*);
}

test "native cache pressure retains hot blocks and isolates unsupported entries" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 0x3000, .{ .read = true, .write = true, .execute = true });
    var jit = Jit.initLimited(std.testing.allocator, 16, 16);
    defer jit.deinit();
    var cpu: Cpu = .{ .sp = 0x3000, .fpcr = 0x03c09f00, .fpsr = 0x08000091, .nzcv = 13, .exclusive_address = 0x4000, .exclusive_size = 8 };
    cpu.v[31] = 0xffeeddccbbaa99887766554433221100;
    for (0..26) |index| try writePressureBlock(&memory, 0x1000 + index * 32);
    for ([_]u64{ 0x1000, 0x1020 }) |pc| {
        try expectPressureBlock(&jit, &cpu, &memory, pc);
        const before_budget = cpu;
        try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 5));
        try std.testing.expectEqualDeep(before_budget, cpu);
    }
    for (2..26) |index| {
        try expectPressureBlock(&jit, &cpu, &memory, 0x1000 + index * 32);
        for ([_]u64{ 0x1000, 0x1020 }) |pc| try expectPressureBlock(&jit, &cpu, &memory, pc);
        try std.testing.expect(jit.blocks.count() <= 16);
    }
    try std.testing.expectEqual(@as(u64, 26), jit.compiled_blocks);
    try std.testing.expectEqual(@as(u64, 10), jit.eviction_count);
    try std.testing.expectEqual(@as(usize, 16), jit.blocks.count());
    for (0..48) |index| {
        cpu.pc = 0x2000 + index * 4;
        try memory.writeInt(u32, cpu.pc, 0xd4000001);
        const before_negative = cpu;
        try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
        try std.testing.expectEqualDeep(before_negative, cpu);
        try std.testing.expect(jit.negative_entries <= 16);
    }
    try std.testing.expect(jit.negative_evictions != 0);
    for ([_]u64{ 0x1000, 0x1020 }) |pc| try expectPressureBlock(&jit, &cpu, &memory, pc);
    try std.testing.expectEqual(@as(u64, 26), jit.compiled_blocks);
    try std.testing.expectEqual(@as(u64, 10), jit.eviction_count);
    try memory.writeInt(u32, 0x1000, 0x91001c00);
    try expectPressureBlock(&jit, &cpu, &memory, 0x1000);
    try std.testing.expectEqual(@as(u64, 27), jit.compiled_blocks);
    try std.testing.expectEqual(@as(u64, 10), jit.eviction_count);
    try std.testing.expectEqual(@as(usize, 16), jit.blocks.count());
    try std.testing.expectEqual(@as(usize, 0), jit.free_count);
}

test "native cache installation failures release all owned allocations" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try writeLoop(&memory, 0x1000, 1);
    for (0..16) |failure_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = failure_index });
        var jit = Jit.initLimited(failing.allocator(), 16, 16);
        defer jit.deinit();
        var cpu: Cpu = .{ .pc = 0x1000 };
        const before = cpu;
        const count = jit.execute(&cpu, &memory, 32);
        if (count == 0) {
            try std.testing.expectEqualDeep(before, cpu);
            try std.testing.expectEqual(@as(u64, 0), jit.compiled_blocks);
        } else {
            try std.testing.expectEqual(@as(u32, 2), count);
            try std.testing.expectEqual(@as(u64, 1), cpu.x[0]);
            try std.testing.expectEqual(@as(u64, 1), jit.compiled_blocks);
        }
    }
}

test "Zyra preserves compiled load faults and scalar fallback metadata" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try memory.map(0x4000, 4096, .{ .read = true, .write = true });
    try memory.writeInt(u64, 0x4ff8, 0x0123456789abcdef);
    var jit = Jit.init(std.testing.allocator);
    defer jit.deinit();
    for ([_]u32{ 0xf9400020, 0xa9400440 }) |word| {
        try memory.writeInt(u32, 0x1000, word);
        var cpu: Cpu = .{ .pc = 0x1000, .last_pc = 0x2000, .last_instruction = 0xd503201f, .counter = std.math.maxInt(u64), .nzcv = 13, .fpcr = 0x03c09f00, .fpsr = 0x08000091, .exclusive_address = 0x4000, .exclusive_size = 8 };
        cpu.x[0] = 0xfedcba9876543210;
        cpu.x[1] = 0x6000;
        cpu.x[2] = 0x4ff8;
        cpu.v[31] = 0xffeeddccbbaa99887766554433221100;
        var reference = cpu;
        try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
        try std.testing.expectEqual(@as(?u32, null), jit.fallback_instruction);
        try std.testing.expectEqual(@as(?anyerror, error.MemoryFault), jit.pending_fault);
        try std.testing.expectError(error.MemoryFault, reference.step(&memory));
        try std.testing.expectEqualDeep(reference, cpu);
        try std.testing.expectEqual(@as(u64, 0x1000), cpu.pc);
        try std.testing.expectEqual(std.math.maxInt(u64), cpu.counter);
    }
    for ([_]u32{ 0xd40000a1, 0xd4200000 }) |word| {
        try memory.writeInt(u32, 0x1000, word);
        var cpu: Cpu = .{ .pc = 0x1000, .counter = std.math.maxInt(u64) };
        var reference = cpu;
        try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
        try std.testing.expectEqualDeep(try reference.step(&memory), try cpu.stepFetched(&memory, jit.fallback_instruction.?));
        try std.testing.expectEqualDeep(reference, cpu);
    }
    try memory.writeInt(u32, 0x1000, 0xffffffff);
    var cpu: Cpu = .{ .pc = 0x1000 };
    var reference = cpu;
    try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
    try std.testing.expectError(error.UndefinedInstruction, reference.step(&memory));
    try std.testing.expectError(error.UndefinedInstruction, cpu.stepFetched(&memory, jit.fallback_instruction.?));
    try std.testing.expectEqualDeep(reference, cpu);
}

test "validated fallback fetch resets at every permission budget and address failure" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try writeLoop(&memory, 0x1000, 1);
    var jit = Jit.init(std.testing.allocator);
    defer jit.deinit();
    var cpu: Cpu = .{ .pc = 0x1000 };
    const before = cpu;
    try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 1));
    try std.testing.expectEqual(@as(?u32, 0x91000400), jit.fallback_instruction);
    try std.testing.expectEqualDeep(before, cpu);
    var reference = cpu;
    _ = try reference.step(&memory);
    _ = try cpu.stepFetched(&memory, jit.fallback_instruction.?);
    try std.testing.expectEqualDeep(reference, cpu);
    cpu.pc = 0x1000;
    try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 1));
    try memory.protect(0x1000, 4096, .{ .read = true, .write = true });
    const denied = cpu;
    try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
    try std.testing.expectEqual(@as(?u32, null), jit.fallback_instruction);
    try std.testing.expectEqualDeep(denied, cpu);
    try std.testing.expectError(error.AccessDenied, cpu.step(&memory));
    try std.testing.expectEqualDeep(denied, cpu);
    try memory.protect(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    for ([_]u64{ 0x1001, 0x2000, address_limit, std.math.maxInt(u64) - 3 }) |pc| {
        cpu.pc = 0x1000;
        try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 1));
        try std.testing.expect(jit.fallback_instruction != null);
        cpu.pc = pc;
        const invalid = cpu;
        try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
        try std.testing.expectEqual(@as(?u32, null), jit.fallback_instruction);
        try std.testing.expectEqualDeep(invalid, cpu);
    }
    cpu.pc = 0x1000;
    try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 1));
    try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 0));
    try std.testing.expectEqual(@as(?u32, null), jit.fallback_instruction);
    try std.testing.expectEqual(@as(u32, 2), jit.execute(&cpu, &memory, 2));
    try std.testing.expectEqual(@as(?u32, null), jit.fallback_instruction);
}

test "validated negative fallback reads current mutations without new allocations" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    var allocation_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var jit = Jit.init(allocation_probe.allocator());
    defer jit.deinit();
    var cpu: Cpu = .{ .pc = 0x1000 };
    try memory.writeInt(u32, cpu.pc, 0xd40000a1);
    try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
    const allocations = allocation_probe.allocations;
    allocation_probe.fail_index = allocation_probe.alloc_index;
    for ([_]u32{ 0xd4200000, 0xffffffff, 0xd53be040 }) |word| {
        try memory.writeInt(u32, cpu.pc, word);
        const before = cpu;
        try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
        try std.testing.expectEqual(@as(?u32, word), jit.fallback_instruction);
        try std.testing.expectEqualDeep(before, cpu);
        try std.testing.expectEqual(allocations, allocation_probe.allocations);
        try std.testing.expect(!allocation_probe.has_induced_failure);
    }
    try memory.protect(0x1000, 4096, .{ .read = true });
    try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
    try std.testing.expectEqual(@as(?u32, null), jit.fallback_instruction);
}

test "validated first fallback word is unaffected by lookahead or later fetch faults" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try memory.writeInt(u32, 0x1ff8, 0x91000400);
    try memory.writeInt(u32, 0x1ffc, 0xd503201f);
    var jit = Jit.init(std.testing.allocator);
    defer jit.deinit();
    var cpu: Cpu = .{ .pc = 0x1ff8 };
    try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 1));
    try std.testing.expectEqual(@as(?u32, 0x91000400), jit.fallback_instruction);
    var reference = cpu;
    _ = try reference.step(&memory);
    _ = try cpu.stepFetched(&memory, jit.fallback_instruction.?);
    try std.testing.expectEqualDeep(reference, cpu);
    try std.testing.expectEqual(@as(u32, 1), jit.execute(&cpu, &memory, 32));
    _ = try reference.step(&memory);
    try std.testing.expectEqualDeep(reference, cpu);
    try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 32));
    try std.testing.expectEqual(@as(?u32, null), jit.fallback_instruction);
    try std.testing.expectError(error.MemoryFault, reference.step(&memory));
    try std.testing.expectError(error.MemoryFault, cpu.step(&memory));
    try std.testing.expectEqualDeep(reference, cpu);
}

test "Zyra linked exits preserve budgets mutations permissions and evicted slots" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try memory.writeInt(u32, 0x1000, 0x91000400);
    try memory.writeInt(u32, 0x1004, 0x1400003f);
    try memory.writeInt(u32, 0x1100, 0x91000800);
    try memory.writeInt(u32, 0x1104, 0x17ffffbf);
    var jit = Jit.initLimited(std.testing.allocator, 2, 16);
    defer jit.deinit();
    var cpu: Cpu = .{ .pc = 0x1000, .sp = 0x9000, .nzcv = 0xb, .fpcr = 0x400000, .fpsr = 0x8010091, .exclusive_address = 0x3000, .exclusive_size = 8 };
    const initial = cpu;
    for (0..2) |_| try std.testing.expectEqual(@as(u32, 2), jit.execute(&cpu, &memory, 2));
    for (0..13) |budget| {
        cpu = initial;
        var reference = initial;
        const retired = jit.executeLinked(&cpu, &memory, budget);
        for (0..retired) |_| _ = try reference.step(&memory);
        try std.testing.expect(retired <= budget);
        try std.testing.expectEqualDeep(reference, cpu);
    }
    try std.testing.expect(jit.linked_blocks != 0);
    try memory.writeInt(u32, 0x1100, 0x91001c00);
    cpu = initial;
    var reference = initial;
    for (0..4) |_| _ = try reference.step(&memory);
    const prefix = jit.executeLinked(&cpu, &memory, 4);
    try std.testing.expectEqual(@as(u32, 2), prefix);
    try std.testing.expectEqual(@as(u32, 2), jit.executeLinked(&cpu, &memory, 2));
    try std.testing.expectEqualDeep(reference, cpu);
    try memory.writeInt(u32, 0x1200, 0x91000c00);
    try memory.writeInt(u32, 0x1204, 0x17ffffff);
    cpu.pc = 0x1200;
    try std.testing.expectEqual(@as(u32, 2), jit.execute(&cpu, &memory, 2));
    cpu = initial;
    reference = initial;
    var completed: u32 = 0;
    while (completed < 8) {
        const count = jit.executeLinked(&cpu, &memory, 8 - completed);
        try std.testing.expect(count != 0);
        for (0..count) |_| _ = try reference.step(&memory);
        completed += count;
    }
    try std.testing.expectEqualDeep(reference, cpu);
    try memory.protect(0x1000, 4096, .{ .read = true, .write = true });
    const denied = cpu;
    try std.testing.expectEqual(@as(u32, 0), jit.executeLinked(&cpu, &memory, 8));
    try std.testing.expectEqualDeep(denied, cpu);
    try std.testing.expectEqual(@as(?u32, null), jit.fallback_instruction);
}

test "Zyra stores terminate before modified successor code executes" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try memory.writeInt(u32, 0x1000, 0xb9000020);
    try memory.writeInt(u32, 0x1004, 0x91000442);
    try memory.writeInt(u32, 0x1008, 0x17ffffff);
    var jit = Jit.init(std.testing.allocator);
    defer jit.deinit();
    var cpu: Cpu = .{ .pc = 0x1004 };
    try std.testing.expectEqual(@as(u32, 2), jit.execute(&cpu, &memory, 2));
    cpu = .{ .pc = 0x1000 };
    cpu.x[0] = 0x91001c42;
    cpu.x[1] = 0x1004;
    var reference = cpu;
    try std.testing.expectEqual(@as(u32, 1), jit.executeLinked(&cpu, &memory, 3));
    _ = try reference.step(&memory);
    try std.testing.expectEqualDeep(reference, cpu);
    try std.testing.expectEqual(@as(u32, 2), jit.execute(&cpu, &memory, 2));
    for (0..2) |_| _ = try reference.step(&memory);
    try std.testing.expectEqualDeep(reference, cpu);
    try std.testing.expectEqual(@as(u64, 7), cpu.x[2]);
}

test "Zyra cache churn bounds hash tombstones and preserves hot links" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try memory.writeInt(u32, 0x1000, 0x91000400);
    try memory.writeInt(u32, 0x1004, 0x1400003f);
    try memory.writeInt(u32, 0x1100, 0x91000800);
    try memory.writeInt(u32, 0x1104, 0x17ffffbf);
    var jit = Jit.initLimited(std.testing.allocator, 8, 8);
    defer jit.deinit();
    var cpu: Cpu = .{ .pc = 0x1000, .sp = 0x9000, .nzcv = 13, .fpcr = 0x400000, .fpsr = 0x8010091, .exclusive_address = 0x3000, .exclusive_size = 8 };
    var reference = cpu;
    for (0..2) |_| {
        try std.testing.expectEqual(@as(u32, 2), jit.execute(&cpu, &memory, 2));
        for (0..2) |_| _ = try reference.step(&memory);
    }
    try std.testing.expectEqual(@as(u32, 8), jit.executeLinked(&cpu, &memory, 8));
    for (0..8) |_| _ = try reference.step(&memory);
    const first = jit.blocks.get(0x1000).?;
    const second = jit.blocks.get(0x1100).?;
    const first_link = first.links;
    const second_link = second.links;
    const first_generation = jit.slots[first.slot].generation;
    const second_generation = jit.slots[second.slot].generation;
    for (0..128) |index| {
        const address: u64 = 0x1200 + @as(u64, @intCast(index)) * 8;
        try writeLoop(&memory, address, 3);
        cpu.pc = address;
        reference.pc = address;
        try std.testing.expectEqual(@as(u32, 2), jit.execute(&cpu, &memory, 2));
        for (0..2) |_| _ = try reference.step(&memory);
        cpu.pc = 0x1000;
        reference.pc = 0x1000;
        try std.testing.expectEqual(@as(u32, 8), jit.executeLinked(&cpu, &memory, 8));
        for (0..8) |_| _ = try reference.step(&memory);
        try std.testing.expectEqualDeep(reference, cpu);
        try std.testing.expectEqual(first, jit.blocks.get(0x1000).?);
        try std.testing.expectEqual(second, jit.blocks.get(0x1100).?);
        try std.testing.expectEqualDeep(first_link, first.links);
        try std.testing.expectEqualDeep(second_link, second.links);
        try std.testing.expectEqual(first_generation, jit.slots[first.slot].generation);
        try std.testing.expectEqual(second_generation, jit.slots[second.slot].generation);
        const metadata = jit.blocks.unmanaged.metadata.?[0..jit.blocks.capacity()];
        var tombstones: usize = 0;
        var occupied: usize = 0;
        for (metadata) |entry| {
            tombstones += @intFromBool(entry.isTombstone());
            occupied += @intFromBool(!entry.isFree());
        }
        try std.testing.expect(tombstones <= jit.removals_since_rehash);
        try std.testing.expect(occupied * 4 <= metadata.len * 3);
        try std.testing.expectEqual(@as(?*Block, null), jit.blocks.get(0x3000));
    }
    try std.testing.expect(jit.cache_rehashes != 0);
    try std.testing.expect(jit.linked_blocks >= 128 * 3);
    try std.testing.expect(jit.eviction_count >= 120);
}

test "Zyra modified code removals also bound hash churn" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    if (!supported) return error.SkipZigTest;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    var jit = Jit.initLimited(std.testing.allocator, 8, 8);
    defer jit.deinit();
    var cpu: Cpu = .{ .pc = 0x1000, .nzcv = 11 };
    var reference = cpu;
    for (0..33) |index| {
        try writeLoop(&memory, 0x1000, @intCast(index + 1));
        try std.testing.expectEqual(@as(u32, 2), jit.executeLinked(&cpu, &memory, 2));
        for (0..2) |_| _ = try reference.step(&memory);
        try std.testing.expectEqualDeep(reference, cpu);
        try std.testing.expect(jit.removals_since_rehash < 4);
    }
    try std.testing.expectEqual(@as(u64, 0), jit.eviction_count);
    try std.testing.expectEqual(@as(u64, 8), jit.cache_rehashes);
}

pub const Jit = struct {
    allocator: std.mem.Allocator,
    blocks: std.AutoHashMap(u64, *Block),
    slots: []Slot = &.{},
    free_slots: []u16 = &.{},
    free_count: usize = 0,
    oldest: u16 = absent_slot,
    newest: u16 = absent_slot,
    negative: []Negative = &.{},
    block_limit: usize = max_blocks,
    negative_limit: usize = max_negative,
    native_instructions: u64 = 0,
    compiled_blocks: u64 = 0,
    fallbacks: u64 = 0,
    eviction_count: u64 = 0,
    negative_evictions: u64 = 0,
    negative_entries: usize = 0,
    fallback_instruction: ?u32 = null,
    pending_fault: ?anyerror = null,
    translated_instructions: u64 = 0,
    memory_instructions: u64 = 0,
    vector_instructions: u64 = 0,
    linked_blocks: u64 = 0,
    next_generation: u64 = 1,
    cache_rehashes: u64 = 0,
    removals_since_rehash: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Jit {
        return .{ .allocator = allocator, .blocks = std.AutoHashMap(u64, *Block).init(allocator) };
    }

    fn initLimited(allocator: std.mem.Allocator, block_limit: usize, negative_limit: usize) Jit {
        std.debug.assert(block_limit != 0 and block_limit <= max_blocks);
        std.debug.assert(negative_limit != 0 and negative_limit <= max_negative and negative_limit & (negative_limit - 1) == 0);
        var result = init(allocator);
        result.block_limit = block_limit;
        result.negative_limit = negative_limit;
        return result;
    }

    pub fn deinit(self: *Jit) void {
        var iterator = self.blocks.valueIterator();
        while (iterator.next()) |block| {
            block.*.deinit(self.allocator);
            self.allocator.destroy(block.*);
        }
        self.blocks.deinit();
        self.allocator.free(self.slots);
        self.allocator.free(self.free_slots);
        self.allocator.free(self.negative);
        self.* = undefined;
    }

    pub fn execute(self: *Jit, cpu: *Cpu, memory: *Memory, budget: u64) u32 {
        return self.executeInternal(cpu, memory, budget, false);
    }

    pub fn executeLinked(self: *Jit, cpu: *Cpu, memory: *Memory, budget: u64) u32 {
        return self.executeInternal(cpu, memory, budget, true);
    }

    fn executeInternal(self: *Jit, cpu: *Cpu, memory: *Memory, budget: u64, linked: bool) u32 {
        self.fallback_instruction = null;
        self.pending_fault = null;
        if (comptime !executable.supported) return self.fallback();
        if (budget == 0 or cpu.pc & 3 != 0 or cpu.pc >= address_limit) return self.fallback();
        if (self.blocks.get(cpu.pc)) |block| {
            const bytes = memory.executableBytes(cpu.pc, @as(usize, block.length) * 4) catch return self.fallback();
            self.fallback_instruction = std.mem.readInt(u32, bytes[0..4], .little);
            if (std.mem.eql(u8, bytes, block.bytes[0..bytes.len])) {
                if (!linked) self.touch(block.slot);
                return if (linked) self.runLinked(block, cpu, memory, budget) else self.run(block, cpu, memory, budget);
            }
            self.remove(cpu.pc);
        }
        if (self.negative.len != 0) {
            const candidate = self.negative[self.negativeIndex(cpu.pc)];
            if (candidate.pc == cpu.pc) {
                const word = memory.fetch(cpu.pc) catch return self.fallback();
                self.fallback_instruction = word;
                if (candidate.word == word) return self.fallback();
                if (!backend.supports(word)) {
                    self.rememberNegative(cpu.pc, word);
                    return self.fallback();
                }
            }
        }

        var words: [max_words]u32 = undefined;
        var count: usize = 0;
        const page_end = (cpu.pc & ~@as(u64, 4095)) + 4096;
        while (count < max_words and cpu.pc + count * 4 < page_end) : (count += 1) {
            const word = if (count == 0)
                self.fallback_instruction orelse first: {
                    const fetched = memory.fetch(cpu.pc) catch break;
                    self.fallback_instruction = fetched;
                    break :first fetched;
                }
            else
                memory.fetch(cpu.pc + count * 4) catch break;
            if (!backend.supports(word)) {
                if (count == 0) {
                    self.rememberNegative(cpu.pc, word);
                    return self.fallback();
                }
                break;
            }
            words[count] = word;
            if (backend.terminal(word)) {
                count += 1;
                break;
            }
        }
        if (count == 0) return self.fallback();
        var program = backend.Program.init(self.allocator, words[0..count], cpu.pc) catch return self.fallback();
        const block = self.allocator.create(Block) catch {
            program.deinit(self.allocator);
            return self.fallback();
        };
        block.* = .{ .length = @intCast(count), .program = program };
        for (words[0..count], 0..) |word, index| std.mem.writeInt(u32, block.bytes[index * 4 ..][0..4], word, .little);
        self.install(cpu.pc, block) catch {
            block.deinit(self.allocator);
            self.allocator.destroy(block);
            return self.fallback();
        };
        self.compiled_blocks +%= 1;
        return if (linked) self.runLinked(block, cpu, memory, budget) else self.run(block, cpu, memory, budget);
    }

    fn install(self: *Jit, pc: u64, block: *Block) !void {
        try self.allocateSlots();
        if (self.free_count == 0) {
            self.remove(self.slots[self.oldest].pc);
            self.eviction_count +%= 1;
        }
        self.free_count -= 1;
        const slot = self.free_slots[self.free_count];
        block.slot = slot;
        self.blocks.put(pc, block) catch |err| {
            self.free_slots[self.free_count] = slot;
            self.free_count += 1;
            return err;
        };
        self.slots[slot] = .{ .pc = pc, .previous = self.newest, .generation = self.next_generation, .block = block };
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        if (self.newest != absent_slot) self.slots[self.newest].next = slot else self.oldest = slot;
        self.newest = slot;
    }

    fn run(self: *Jit, block: *const Block, cpu: *Cpu, memory: *Memory, budget: u64) u32 {
        if (block.length > budget) return self.fallback();
        const result = block.program.execute(cpu, memory);
        self.fallback_instruction = null;
        self.pending_fault = result.fault;
        self.native_instructions +%= result.native_count;
        self.translated_instructions +%= result.retired;
        self.memory_instructions +%= result.memory_count;
        self.vector_instructions +%= result.vector_count;
        return result.retired;
    }

    fn runLinked(self: *Jit, first: *Block, cpu: *Cpu, memory: *Memory, budget: u64) u32 {
        var block = first;
        var retired: u32 = 0;
        var traversed: usize = 0;
        while (true) {
            if (block.length > budget - retired) return if (retired == 0) self.fallback() else retired;
            if (traversed != 0) {
                const bytes = memory.executableBytes(cpu.pc, @as(usize, block.length) * 4) catch return retired;
                if (!std.mem.eql(u8, bytes, block.bytes[0..bytes.len])) {
                    self.remove(cpu.pc);
                    return retired;
                }
                self.linked_blocks +%= 1;
            }
            self.touch(block.slot);
            retired += self.run(block, cpu, memory, budget - retired);
            if (self.pending_fault != null or retired == budget or traversed == 127) return retired;
            var next: ?*Block = null;
            for (block.links) |optional| if (optional) |link| {
                if (link.pc == cpu.pc) {
                    const slot = self.slots[link.slot];
                    if (slot.pc == link.pc and slot.generation == link.generation) next = slot.block;
                    break;
                }
            };
            if (next == null) {
                next = self.blocks.get(cpu.pc);
                if (next) |target| {
                    block.links[block.next_link] = .{ .pc = cpu.pc, .slot = target.slot, .generation = self.slots[target.slot].generation };
                    block.next_link ^= 1;
                }
            }
            block = next orelse return retired;
            traversed += 1;
        }
    }

    fn allocateSlots(self: *Jit) !void {
        if (self.slots.len != 0) return;
        const slots = try self.allocator.alloc(Slot, self.block_limit);
        errdefer self.allocator.free(slots);
        const free = try self.allocator.alloc(u16, self.block_limit);
        @memset(slots, .{});
        for (free, 0..) |*slot, index| slot.* = @intCast(self.block_limit - 1 - index);
        self.slots = slots;
        self.free_slots = free;
        self.free_count = free.len;
    }

    fn remove(self: *Jit, pc: u64) void {
        const block = self.blocks.get(pc).?;
        const slot = block.slot;
        std.debug.assert(self.slots[slot].pc == pc);
        self.unlink(slot);
        block.deinit(self.allocator);
        self.allocator.destroy(block);
        _ = self.blocks.remove(pc);
        self.removals_since_rehash += 1;
        if (self.removals_since_rehash >= @max(self.block_limit / 2, 1)) {
            self.blocks.rehash();
            self.removals_since_rehash = 0;
            self.cache_rehashes +%= 1;
        }
        self.slots[slot] = .{};
        self.free_slots[self.free_count] = slot;
        self.free_count += 1;
    }

    fn unlink(self: *Jit, slot: u16) void {
        const item = self.slots[slot];
        if (item.previous != absent_slot) self.slots[item.previous].next = item.next else self.oldest = item.next;
        if (item.next != absent_slot) self.slots[item.next].previous = item.previous else self.newest = item.previous;
    }

    fn touch(self: *Jit, slot: u16) void {
        if (slot == self.newest) return;
        self.unlink(slot);
        self.slots[slot].previous = self.newest;
        self.slots[slot].next = absent_slot;
        self.slots[self.newest].next = slot;
        self.newest = slot;
    }

    fn negativeIndex(self: *const Jit, pc: u64) usize {
        const hash = (pc >> 2) *% 0x9e3779b97f4a7c15;
        return @as(usize, @intCast(hash >> 32)) & (self.negative_limit - 1);
    }

    fn rememberNegative(self: *Jit, pc: u64, word: u32) void {
        if (self.negative.len == 0) {
            self.negative = self.allocator.alloc(Negative, self.negative_limit) catch return;
            @memset(self.negative, .{});
        }
        const index = self.negativeIndex(pc);
        const previous = self.negative[index].pc;
        if (previous == absent_pc) self.negative_entries += 1 else if (previous != pc) self.negative_evictions +%= 1;
        self.negative[index] = .{ .pc = pc, .word = word };
    }

    fn fallback(self: *Jit) u32 {
        self.fallbacks +%= 1;
        return 0;
    }
};
