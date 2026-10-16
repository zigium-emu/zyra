const std = @import("std");

pub const address_limit: u64 = 0x3000;

pub const Cpu = struct {
    x: [31]u64 = @splat(0),
    v: [32]u128 = @splat(0),
    sp: u64 = 0,
    pc: u64 = 0,
    last_pc: u64 = 0,
    last_instruction: u32 = 0,
    nzcv: u4 = 0,
    fpcr: u32 = 0,
    fpsr: u32 = 0,
    counter: u64 = 0,
    exclusive_address: ?u64 = null,
    exclusive_size: u8 = 0,

    pub fn clearExclusive(self: *Cpu) void {
        self.exclusive_address = null;
    }
    pub const FloatVectorOperation = enum { add, subtract, multiply, divide, fused_add, fused_subtract, sqrt, equal, greater_equal, greater };

    fn unavailableFloat(self: *Cpu) !void {
        if (self.fpcr & 0x00009f00 != 0) return error.UnsupportedFloatingPointTrap;
        return error.ExactFloatingPointUnavailable;
    }
    pub fn evaluateFloatVector(self: *Cpu, comptime T: type, _: FloatVectorOperation, _: u128, _: u128, _: u128, _: u8) !u128 {
        _ = T;
        try self.unavailableFloat();
        unreachable;
    }
    pub fn evaluateFloatFused(self: *Cpu, comptime T: type, _: u64, _: u64, _: u64, _: bool, _: bool) !u64 {
        _ = T;
        try self.unavailableFloat();
        unreachable;
    }
    pub fn evaluateFloatCompare(self: *Cpu, comptime T: type, _: u64, _: u64, _: bool) !void {
        _ = T;
        try self.unavailableFloat();
    }
    pub fn evaluateFloatConvert(self: *Cpu, comptime T: type, _: u64, _: u7, _: bool, _: bool, _: u7, _: u3) !u64 {
        _ = T;
        try self.unavailableFloat();
        unreachable;
    }
};

pub const Permission = struct { read: bool = false, write: bool = false, execute: bool = false };

pub const Memory = struct {
    bytes: [8192]u8 = @splat(0),
    permissions: [2]Permission = @splat(.{}),

    pub fn init(_: std.mem.Allocator) Memory {
        return .{};
    }
    pub fn deinit(_: *Memory) void {}
    pub fn map(self: *Memory, address: u64, length: usize, permission: Permission) !void {
        if (address & 4095 != 0 or length != 4096 or address < 0x1000 or address >= address_limit) return error.MemoryFault;
        const page: usize = @intCast((address - 0x1000) / 4096);
        self.permissions[page] = permission;
        @memset(self.bytes[page * 4096 ..][0..4096], 0);
    }
    pub fn protect(self: *Memory, address: u64, length: usize, permission: Permission) !void {
        if (address & 4095 != 0 or length != 4096 or address < 0x1000 or address >= address_limit) return error.MemoryFault;
        self.permissions[@intCast((address - 0x1000) / 4096)] = permission;
    }
    fn checked(self: *Memory, address: u64, length: usize, access: enum { read, write, execute }) ![]u8 {
        if (address < 0x1000 or address >= address_limit or length > address_limit - address) return error.MemoryFault;
        const first: usize = @intCast(address - 0x1000);
        const end = first + length;
        if (length != 0) for (first / 4096..(end - 1) / 4096 + 1) |page| {
            const p = self.permissions[page];
            const allowed = switch (access) {
                .read => p.read,
                .write => p.write,
                .execute => p.execute,
            };
            if (!allowed) return error.PermissionDenied;
        };
        return self.bytes[first..end];
    }
    pub fn readInt(self: *Memory, comptime T: type, address: u64) !T {
        const bytes = try self.checked(address, @sizeOf(T), .read);
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }
    pub fn writeInt(self: *Memory, comptime T: type, address: u64, value: T) !void {
        const bytes = try self.checked(address, @sizeOf(T), .write);
        std.mem.writeInt(T, bytes[0..@sizeOf(T)], value, .little);
    }
    pub fn fetch(self: *Memory, address: u64) !u32 {
        if (address & 3 != 0) return error.UnalignedInstruction;
        const bytes = try self.executableBytes(address, 4);
        return std.mem.readInt(u32, bytes[0..4], .little);
    }
    pub fn executableBytes(self: *Memory, address: u64, length: usize) ![]const u8 {
        return self.checked(address, length, .execute);
    }
};
