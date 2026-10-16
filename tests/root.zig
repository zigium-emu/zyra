const std = @import("std");
const zyra = @import("zyra");
const host = @import("zyra_host");

fn memoryFixture() !host.Memory {
    var memory = host.Memory.init(std.testing.allocator);
    try memory.map(0x1000, 4096, .{ .read = true, .write = true, .execute = true });
    try memory.map(0x2000, 4096, .{ .read = true, .write = true });
    return memory;
}

test "standalone native flags and conditional branch produce known state" {
    if (!zyra.supported) return error.SkipZigTest;
    var memory = try memoryFixture();
    defer memory.deinit();
    const words = [_]u32{ 0xb1000400, 0x54000040 };
    var program = try zyra.program.Program.init(std.testing.allocator, &words, 0x1000);
    defer program.deinit(std.testing.allocator);
    var cpu: host.Cpu = .{ .pc = 0x1000, .counter = std.math.maxInt(u64), .fpsr = 0x81 };
    cpu.x[0] = std.math.maxInt(u64);
    const result = program.execute(&cpu, &memory);
    try std.testing.expectEqual(@as(u32, 2), result.retired);
    try std.testing.expectEqual(@as(u32, 2), result.native_count);
    try std.testing.expectEqual(@as(u64, 0), cpu.x[0]);
    try std.testing.expectEqual(@as(u4, 6), cpu.nzcv);
    try std.testing.expectEqual(@as(u64, 0x100c), cpu.pc);
    try std.testing.expectEqual(@as(u64, 1), cpu.counter);
    try std.testing.expectEqual(@as(u32, 0x81), cpu.fpsr);
}

test "standalone mixed loads stores and faults preserve retired prefix" {
    if (!zyra.supported) return error.SkipZigTest;
    var memory = try memoryFixture();
    defer memory.deinit();
    try memory.writeInt(u64, 0x2000, 0x123456789abcdef0);
    const words = [_]u32{ 0x91000442, 0xf9400020, 0x91001c00, 0xf9000020 };
    var program = try zyra.program.Program.init(std.testing.allocator, &words, 0x1000);
    defer program.deinit(std.testing.allocator);
    var cpu: host.Cpu = .{ .pc = 0x1000, .exclusive_address = 0x2000, .exclusive_size = 8 };
    cpu.x[1] = 0x2000;
    const result = program.execute(&cpu, &memory);
    try std.testing.expectEqual(@as(u32, 4), result.retired);
    try std.testing.expectEqual(@as(u32, 2), result.memory_count);
    try std.testing.expectEqual(@as(u64, 0x123456789abcdef7), try memory.readInt(u64, 0x2000));
    try std.testing.expectEqual(@as(?u64, null), cpu.exclusive_address);
    cpu = .{ .pc = 0x1000 };
    cpu.x[1] = 0x3000;
    const failed = program.execute(&cpu, &memory);
    try std.testing.expectEqual(@as(u32, 1), failed.retired);
    try std.testing.expectEqual(@as(?anyerror, error.MemoryFault), failed.fault);
    try std.testing.expectEqual(@as(u64, 0x1004), cpu.pc);
    try std.testing.expectEqual(@as(u64, 0x1004), cpu.last_pc);
    try std.testing.expectEqual(@as(u32, 0xf9400020), cpu.last_instruction);
    try std.testing.expectEqual(@as(u64, 1), cpu.counter);
}

test "standalone vector arithmetic and raw FP moves preserve payload bits" {
    var cpu: host.Cpu = .{ .pc = 0x1000, .fpcr = 0x03c09f00, .fpsr = 0x81, .nzcv = 13 };
    cpu.v[1] = std.math.maxInt(u128);
    cpu.v[2] = 0x01010101010101010101010101010101;
    try zyra.vector.execute(&cpu, 0x4e228420);
    try std.testing.expectEqual(@as(u128, 0), cpu.v[0]);
    cpu.x[1] = 0x7ff0000012345678;
    try zyra.vector.execute(&cpu, 0x9e670020);
    try zyra.vector.execute(&cpu, 0x9e660002);
    try std.testing.expectEqual(@as(u64, 0x7ff0000012345678), cpu.x[2]);
    try std.testing.expectEqual(@as(u32, 0x81), cpu.fpsr);
    try std.testing.expectEqual(@as(u4, 13), cpu.nzcv);
}

test "standalone f32 fast path calculates values and inexact flags" {
    var cpu: host.Cpu = .{ .pc = 0x1000, .fpsr = 0x80 };
    cpu.v[1] = 0x3f800000;
    cpu.v[2] = 0x33800000;
    try zyra.vector.execute(&cpu, 0x1e222820);
    try std.testing.expectEqual(@as(u128, 0x3f800000), cpu.v[0]);
    try std.testing.expectEqual(@as(u32, 0x90), cpu.fpsr);
    cpu.fpcr = 0x400000;
    try std.testing.expectError(error.ExactFloatingPointUnavailable, zyra.vector.execute(&cpu, 0x1e222820));
    try std.testing.expectEqual(@as(u64, 0x1004), cpu.pc);
    try std.testing.expectEqual(@as(u64, 1), cpu.counter);
}

test "standalone cache revalidates live bytes permissions and linked budgets" {
    if (!zyra.supported) return error.SkipZigTest;
    var memory = try memoryFixture();
    defer memory.deinit();
    try memory.writeInt(u32, 0x1000, 0x91000400);
    try memory.writeInt(u32, 0x1004, 0x17ffffff);
    var jit = zyra.Jit.init(std.testing.allocator);
    defer jit.deinit();
    var cpu: host.Cpu = .{ .pc = 0x1000 };
    try std.testing.expectEqual(@as(u32, 8), jit.executeLinked(&cpu, &memory, 8));
    try std.testing.expectEqual(@as(u64, 4), cpu.x[0]);
    try memory.writeInt(u32, 0x1000, 0x91000800);
    try std.testing.expectEqual(@as(u32, 2), jit.executeLinked(&cpu, &memory, 2));
    try std.testing.expectEqual(@as(u64, 6), cpu.x[0]);
    const before = cpu;
    try memory.protect(0x1000, 4096, .{ .read = true, .write = true });
    try std.testing.expectEqual(@as(u32, 0), jit.execute(&cpu, &memory, 2));
    try std.testing.expectEqualDeep(before, cpu);
}
