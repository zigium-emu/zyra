const std = @import("std");
const builtin = @import("builtin");
const Cpu = @import("zyra_host").Cpu;

pub fn supports(ins: u32) bool {
    if (ins == 0xd503201f) return true;
    if (ins & 0x1f000000 == 0x10000000) return true;
    if (ins & 0x1f800000 == 0x12800000) {
        const opcode = (ins >> 29) & 3;
        return opcode != 1 and (ins >> 31 != 0 or ins & 0x00400000 == 0);
    }
    if (ins & 0x1f800000 == 0x11000000) return true;
    if (ins & 0x1f800000 == 0x12000000) return bitMasks(ins, true) != null;
    if (ins & 0x1f800000 == 0x13000000) {
        const wide = ins >> 31 != 0;
        return ((ins >> 29) & 3) != 3 and ((ins >> 22) & 1) == @intFromBool(wide) and
            (wide or ins & 0x00208000 == 0) and bitMasks(ins, false) != null;
    }
    if (ins & 0x1f800000 == 0x13800000) return ins & 0x60200000 == 0 and
        ((ins >> 22) & 1) == ins >> 31 and (ins >> 31 != 0 or ins & 0x8000 == 0);
    if (ins & 0x1f000000 == 0x0a000000) {
        return ((ins >> 10) & 63) < (if (ins >> 31 != 0) @as(u32, 64) else 32);
    }
    if (ins & 0x1f000000 == 0x0b000000) return if (ins & 0x00200000 != 0)
        ins & 0x00c00000 == 0 and ((ins >> 10) & 7) <= 4
    else
        ((ins >> 22) & 3) != 3 and ((ins >> 10) & 63) < (if (ins >> 31 != 0) @as(u32, 64) else 32);
    if (ins & 0x1fe0fc00 == 0x1a000000) return true;
    if (ins & 0x1fe00000 == 0x1a400000) return ins & 0x20000410 == 0x20000000;
    if (ins & 0x1fe00000 == 0x1a800000) return ins & 0x20000800 == 0;
    if (ins & 0x1fe00000 == 0x1ac00000) return ins & 0x60000000 == 0 and switch ((ins >> 10) & 63) {
        2, 3, 8, 9, 10, 11 => true,
        else => false,
    };
    if (ins & 0x1f000000 == 0x1b000000) {
        if (ins & 0x60000000 != 0) return false;
        return switch ((ins >> 21) & 7) {
            0 => true,
            1, 5 => ins >> 31 != 0,
            2, 6 => ins >> 31 != 0 and ins & 0xfc00 == 0x7c00,
            else => false,
        };
    }
    if (ins & 0x7c000000 == 0x14000000) return true;
    if (ins & 0xff000010 == 0x54000000 or ins & 0x7e000000 == 0x34000000 or ins & 0x7e000000 == 0x36000000) return true;
    const branch = ins & 0xfffffc1f;
    return (branch == 0xd61f0000 or branch == 0xd63f0000 or branch == 0xd65f0000) and
        ((ins >> 5) & 31) != 31;
}

pub fn terminal(ins: u32) bool {
    if (!supports(ins)) return false;
    return ins & 0x7c000000 == 0x14000000 or
        ins & 0xff000010 == 0x54000000 or ins & 0x7e000000 == 0x34000000 or ins & 0x7e000000 == 0x36000000 or
        ins & 0xfffffc1f == 0xd61f0000 or
        ins & 0xfffffc1f == 0xd63f0000 or
        ins & 0xfffffc1f == 0xd65f0000;
}

pub fn compile(allocator: std.mem.Allocator, words: []const u32, start_pc: u64) ![]u8 {
    if (words.len == 0) return error.EmptyBlock;
    if (start_pc & 3 != 0) return error.UnalignedInstruction;
    for (words, 0..) |word, index| {
        if (!supports(word)) return error.UnsupportedInstruction;
        if (terminal(word) and index + 1 != words.len) return error.InvalidBlock;
    }
    var emitter = Emitter{ .allocator = allocator, .cache = selectCache(words) };
    errdefer emitter.bytes.deinit(allocator);
    try emitter.put(&.{ 0x49, 0x89, if (builtin.os.tag == .windows) 0xca else 0xfa });
    try emitter.preload();
    for (words, 0..) |word, index| {
        const pc = start_pc +% (@as(u64, @intCast(index)) *% 4);
        try emitter.instruction(word, pc);
    }
    try emitter.flush();
    const last_pc = start_pc +% (@as(u64, @intCast(words.len - 1)) *% 4);
    if (!terminal(words[words.len - 1])) {
        try emitter.immediate(.rax, last_pc +% 4);
        try emitter.store(.rax, @offsetOf(Cpu, "pc"));
    }
    try emitter.immediate(.rax, last_pc);
    try emitter.store(.rax, @offsetOf(Cpu, "last_pc"));
    try emitter.put(&.{ 0x41, 0xc7, 0x82 });
    try emitter.integer(u32, @offsetOf(Cpu, "last_instruction"));
    try emitter.integer(u32, words[words.len - 1]);
    try emitter.immediate(.rax, @intCast(words.len));
    try emitter.put(&.{ 0x49, 0x01, 0x82 });
    try emitter.integer(u32, @offsetOf(Cpu, "counter"));
    try emitter.put(&.{0xc3});
    return emitter.bytes.toOwnedSlice(allocator);
}

const Register = enum { rax, rcx, rdx };
const HostRegister = enum(u3) { r8 = 0, r9 = 1, r11 = 3 };
const CachedRegister = struct { host: HostRegister, guest: ?u5 = null, dirty: bool = false };

fn countGuest(frequencies: *[32]usize, guest: u5, use_sp: bool) void {
    if (guest != 31 or use_sp) frequencies[guest] +|= 1;
}

fn selectCache(words: []const u32) [3]CachedRegister {
    var selected = [_]CachedRegister{ .{ .host = .r8 }, .{ .host = .r9 }, .{ .host = .r11 } };
    if (words.len < 3) return selected;
    var frequencies: [32]usize = @splat(0);
    for (words) |ins| {
        if (ins == 0xd503201f) continue;
        const rd: u5 = @truncate(ins);
        const rn: u5 = @truncate(ins >> 5);
        const rm: u5 = @truncate(ins >> 16);
        if (ins & 0x1f000000 == 0x10000000) {
            countGuest(&frequencies, rd, false);
        } else if (ins & 0x1f800000 == 0x12800000) {
            countGuest(&frequencies, rd, false);
            if (((ins >> 29) & 3) == 3) countGuest(&frequencies, rd, false);
        } else if (ins & 0x1f800000 == 0x11000000) {
            countGuest(&frequencies, rn, true);
            countGuest(&frequencies, rd, ins & 0x20000000 == 0);
        } else if (ins & 0x1f000000 == 0x0a000000) {
            if (rd != 31) {
                countGuest(&frequencies, rn, false);
                countGuest(&frequencies, rm, false);
                countGuest(&frequencies, rd, false);
            }
        } else if (ins & 0x1f000000 == 0x0b000000 or ins & 0x1fe0fc00 == 0x1a000000 or ins & 0x1fe00000 == 0x1a400000 or ins & 0x1fe00000 == 0x1a800000 or ins & 0x1fe00000 == 0x1ac00000 or ins & 0x1f000000 == 0x1b000000) {
            const extended = ins & 0x1f000000 == 0x0b000000 and ins & 0x00200000 != 0;
            countGuest(&frequencies, rn, extended);
            countGuest(&frequencies, rm, false);
            countGuest(&frequencies, rd, extended and ins & 0x20000000 == 0);
            if (ins & 0x1f000000 == 0x1b000000) countGuest(&frequencies, @truncate(ins >> 10), false);
        } else if (ins & 0x1f800000 == 0x12000000 or ins & 0x1f800000 == 0x13000000 or ins & 0x1f800000 == 0x13800000) {
            countGuest(&frequencies, rn, false);
            countGuest(&frequencies, rd, ins & 0x1f800000 == 0x12000000 and (ins >> 29) & 3 != 3);
            if (ins & 0x1f800000 == 0x13800000) countGuest(&frequencies, rm, false);
        } else if (ins & 0xff000010 == 0x54000000) {
            continue;
        } else if (ins & 0x7e000000 == 0x34000000 or ins & 0x7e000000 == 0x36000000) {
            countGuest(&frequencies, rd, false);
        } else if (ins & 0x7c000000 == 0x14000000) {
            if (ins >> 31 != 0) countGuest(&frequencies, 30, false);
        } else {
            countGuest(&frequencies, rn, false);
            if (ins & 0xfffffc1f == 0xd63f0000) countGuest(&frequencies, 30, false);
        }
    }
    for (&selected) |*entry| {
        var best: usize = 2;
        for (frequencies, 0..) |frequency, guest| {
            if (frequency > best) {
                best = frequency;
                entry.guest = @intCast(guest);
            }
        }
        if (entry.guest) |guest| frequencies[guest] = 0;
    }
    return selected;
}

fn guestOffset(guest: u5) u32 {
    return @intCast(if (guest == 31) @offsetOf(Cpu, "sp") else @offsetOf(Cpu, "x") + @as(u32, guest) * 8);
}

fn hostCode(register: Register) u8 {
    return switch (register) {
        .rax => 0,
        .rcx => 1,
        .rdx => 2,
    };
}

fn widthMask(width: u7) u64 {
    return if (width == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(width)) - 1;
}

fn rotated(value: u64, amount: u6, width: u7) u64 {
    if (amount == 0) return value & widthMask(width);
    return ((value >> amount) | (value << @intCast(width - amount))) & widthMask(width);
}

const BitMasks = struct { write: u64, top: u64 };

fn bitMasks(ins: u32, immediate: bool) ?BitMasks {
    const width: u7 = if (ins >> 31 != 0) 64 else 32;
    const n: u7 = @intCast((ins >> 22) & 1);
    const s: u6 = @truncate(ins >> 10);
    const r: u6 = @truncate(ins >> 16);
    if (width == 32 and n != 0) return null;
    const encoded: u7 = (n << 6) | @as(u7, (~s) & 63);
    if (encoded < 2) return null;
    const length: u3 = @intCast(6 - @clz(encoded));
    const size: u7 = @as(u7, 1) << length;
    if (size > width) return null;
    const levels: u6 = @intCast(size - 1);
    if (immediate and s & levels == levels) return null;
    const ones = widthMask(@as(u7, s & levels) + 1);
    const top_ones = widthMask(@as(u7, (s -% r) & levels) + 1);
    const element = rotated(ones, r & levels, size);
    var result = BitMasks{ .write = 0, .top = 0 };
    var shift: u7 = 0;
    while (shift < width) : (shift += size) {
        result.write |= element << @intCast(shift);
        result.top |= top_ones << @intCast(shift);
    }
    return result;
}

fn conditionMask(cond: u4) u16 {
    var result: u16 = 0;
    for (0..16) |flags| {
        const n = flags & 8 != 0;
        const z = flags & 4 != 0;
        const c = flags & 2 != 0;
        const v = flags & 1 != 0;
        var matches = switch (cond >> 1) {
            0 => z,
            1 => c,
            2 => n,
            3 => v,
            4 => c and !z,
            5 => n == v,
            6 => n == v and !z,
            7 => true,
            else => unreachable,
        };
        if (cond & 1 != 0 and cond != 15) matches = !matches;
        if (matches) result |= @as(u16, 1) << @intCast(flags);
    }
    return result;
}

const Emitter = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    cache: [3]CachedRegister,

    fn put(self: *Emitter, bytes: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, bytes);
    }

    fn integer(self: *Emitter, comptime T: type, value: T) !void {
        var encoded: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &encoded, value, .little);
        try self.put(&encoded);
    }

    fn immediate(self: *Emitter, register: Register, value: u64) !void {
        try self.put(&.{ 0x48, 0xb8 + hostCode(register) });
        try self.integer(u64, value);
    }

    fn load(self: *Emitter, register: Register, offset: u32, wide: bool) !void {
        try self.put(&.{ if (wide) 0x49 else 0x41, 0x8b, 0x82 + (hostCode(register) << 3) });
        try self.integer(u32, offset);
    }

    fn store(self: *Emitter, register: Register, offset: u32) !void {
        try self.put(&.{ 0x49, 0x89, 0x82 + (hostCode(register) << 3) });
        try self.integer(u32, offset);
    }

    fn preload(self: *Emitter) !void {
        for (self.cache) |entry| {
            if (entry.guest) |guest| {
                try self.put(&.{ 0x4d, 0x8b, 0x82 | (@as(u8, @backingInt(entry.host)) << 3) });
                try self.integer(u32, guestOffset(guest));
            }
        }
    }

    fn flush(self: *Emitter) !void {
        for (self.cache) |entry| {
            if (entry.dirty) {
                try self.put(&.{ 0x4d, 0x89, 0x82 | (@as(u8, @backingInt(entry.host)) << 3) });
                try self.integer(u32, guestOffset(entry.guest.?));
            }
        }
    }

    fn cached(self: *const Emitter, guest: u5) ?usize {
        for (self.cache, 0..) |entry, index| if (entry.guest == guest) return index;
        return null;
    }

    fn loadGuest(self: *Emitter, register: Register, guest: u5, wide: bool, use_sp: bool) !void {
        if (guest == 31 and !use_sp) {
            try self.put(&.{ 0x31, 0xc0 + hostCode(register) * 9 });
            return;
        }
        if (self.cached(guest)) |index| {
            const source = @as(u8, @backingInt(self.cache[index].host)) << 3;
            try self.put(&.{ if (wide) 0x4c else 0x44, 0x89, 0xc0 | source | hostCode(register) });
        } else try self.load(register, guestOffset(guest), wide);
    }

    fn storeGuest(self: *Emitter, guest: u5, use_sp: bool) !void {
        try self.storeGuestFrom(.rax, guest, use_sp);
    }

    fn storeGuestFrom(self: *Emitter, register: Register, guest: u5, use_sp: bool) !void {
        if (guest == 31 and !use_sp) return;
        if (self.cached(guest)) |index| {
            const destination: u8 = @backingInt(self.cache[index].host);
            try self.put(&.{ 0x49, 0x89, 0xc0 | destination | (hostCode(register) << 3) });
            self.cache[index].dirty = true;
        } else try self.store(register, guestOffset(guest));
    }

    fn shift(self: *Emitter, register: Register, kind: u2, amount: u8, wide: bool) !void {
        if (amount == 0) return;
        if (wide) try self.put(&.{0x48});
        try self.put(&.{ 0xc1, (@as(u8, switch (kind) {
            0 => 0xe0,
            1 => 0xe8,
            2 => 0xf8,
            3 => 0xc8,
        })) + hostCode(register), amount });
    }

    fn flags(self: *Emitter, subtract: bool, logical: bool) !void {
        try self.put(&.{ 0x9c, 0x59, 0x50, 0x89, 0xca, 0xc1, 0xea, 4, 0x83, 0xe2, 12 });
        if (!logical) {
            try self.put(&.{ 0x89, 0xc8, 0x83, 0xe0, 1 });
            if (subtract) try self.put(&.{ 0x83, 0xf0, 1 });
            try self.put(&.{ 0xd1, 0xe0, 0x09, 0xc2, 0xc1, 0xe9, 11, 0x83, 0xe1, 1, 0x09, 0xca });
        }
        try self.put(&.{ 0x41, 0x88, 0x92 });
        try self.integer(u32, @offsetOf(Cpu, "nzcv"));
        try self.put(&.{0x58});
    }

    fn condition(self: *Emitter, cond: u4) !void {
        try self.put(&.{ 0x52, 0x41, 0x0f, 0xb6, 0x8a });
        try self.integer(u32, @offsetOf(Cpu, "nzcv"));
        try self.immediate(.rdx, conditionMask(cond));
        try self.put(&.{ 0x0f, 0xa3, 0xca, 0x5a });
    }

    fn jump(self: *Emitter, opcode: u8) !usize {
        if (opcode == 0xe9) try self.put(&.{opcode}) else try self.put(&.{ 0x0f, opcode });
        const offset = self.bytes.items.len;
        try self.integer(u32, 0);
        return offset;
    }

    fn patch(self: *Emitter, offset: usize) void {
        std.mem.writeInt(u32, self.bytes.items[offset..][0..4], @intCast(self.bytes.items.len - offset - 4), .little);
    }

    fn instruction(self: *Emitter, ins: u32, pc: u64) !void {
        if (ins == 0xd503201f) return;
        const rd: u5 = @truncate(ins);
        const rn: u5 = @truncate(ins >> 5);
        const rm: u5 = @truncate(ins >> 16);
        const wide = ins >> 31 != 0;
        if (ins & 0x1f000000 == 0x10000000) {
            if (rd == 31) return;
            const displacement = signedImmediate((((ins >> 5) & 0x7ffff) << 2) | ((ins >> 29) & 3), 21);
            const value = if (wide) (pc & ~@as(u64, 4095)) +% (displacement << 12) else pc +% displacement;
            try self.immediate(.rax, value);
            try self.storeGuest(rd, false);
            return;
        }
        if (ins & 0x1f800000 == 0x12800000) {
            if (rd == 31) return;
            const opcode = (ins >> 29) & 3;
            const halfword_shift: u6 = @intCast(((ins >> 21) & 3) * 16);
            const value = @as(u64, (ins >> 5) & 0xffff) << halfword_shift;
            if (opcode == 3) {
                try self.loadGuest(.rax, rd, wide, false);
                try self.immediate(.rdx, ~(@as(u64, 0xffff) << halfword_shift));
                try self.put(&.{ 0x48, 0x21, 0xd0 });
                try self.immediate(.rdx, value);
                try self.put(&.{ 0x48, 0x09, 0xd0 });
            } else {
                const result = if (opcode == 0) ~value else value;
                try self.immediate(.rax, if (wide) result else result & 0xffffffff);
            }
            try self.storeGuest(rd, false);
            return;
        }
        if (ins & 0x1f800000 == 0x11000000) {
            try self.loadGuest(.rax, rn, wide, true);
            const value: u32 = ((ins >> 10) & 0xfff) << @as(u5, if (ins & 0x00400000 != 0) 12 else 0);
            if (wide) try self.put(&.{0x48});
            try self.put(&.{ 0x81, if (ins & 0x40000000 != 0) 0xe8 else 0xc0 });
            try self.integer(u32, value);
            if (ins & 0x20000000 != 0) try self.flags(ins & 0x40000000 != 0, false);
            try self.storeGuest(rd, ins & 0x20000000 == 0);
            return;
        }
        if (ins & 0x1f800000 == 0x12000000) {
            const opcode = (ins >> 29) & 3;
            try self.loadGuest(.rax, rn, wide, false);
            try self.immediate(.rdx, bitMasks(ins, true).?.write);
            if (wide) try self.put(&.{0x48});
            try self.put(&.{ switch (opcode) {
                0, 3 => @as(u8, 0x21),
                1 => 0x09,
                2 => 0x31,
                else => unreachable,
            }, 0xd0 });
            if (opcode == 3) try self.flags(false, true);
            try self.storeGuest(rd, opcode != 3);
            return;
        }
        if (ins & 0x1f800000 == 0x13000000) {
            const opcode = (ins >> 29) & 3;
            const masks = bitMasks(ins, false).?;
            try self.loadGuest(.rax, rn, wide, false);
            if (opcode == 0) {
                try self.put(&.{ 0x48, 0x89, 0xc1 });
                const sign_bit: u8 = @intCast((ins >> 10) & 63);
                try self.shift(.rcx, 0, 63 - sign_bit, true);
                try self.shift(.rcx, 2, 63, true);
                try self.immediate(.rdx, ~masks.top & widthMask(if (wide) 64 else 32));
                try self.put(&.{ 0x48, 0x21, 0xd1 });
            }
            try self.shift(.rax, 3, @intCast((ins >> 16) & 63), wide);
            try self.immediate(.rdx, masks.write & masks.top);
            try self.put(&.{ 0x48, 0x21, 0xd0 });
            if (opcode == 0) try self.put(&.{ 0x48, 0x09, 0xc8 }) else if (opcode == 1) {
                try self.loadGuest(.rcx, rd, wide, false);
                try self.immediate(.rdx, ~(masks.write & masks.top) & widthMask(if (wide) 64 else 32));
                try self.put(&.{ 0x48, 0x21, 0xd1, 0x48, 0x09, 0xc8 });
            }
            try self.storeGuest(rd, false);
            return;
        }
        if (ins & 0x1f800000 == 0x13800000) {
            const amount: u8 = @intCast((ins >> 10) & 63);
            try self.loadGuest(.rax, rm, wide, false);
            if (amount != 0) {
                try self.loadGuest(.rdx, rn, wide, false);
                if (wide) try self.put(&.{0x48});
                try self.put(&.{ 0x0f, 0xac, 0xd0, amount });
            }
            try self.storeGuest(rd, false);
            return;
        }
        if (ins & 0x1f000000 == 0x0a000000) {
            const flags_set = ((ins >> 29) & 3) == 3;
            if (rd == 31 and !flags_set) return;
            try self.loadGuest(.rax, rn, wide, false);
            try self.loadGuest(.rdx, rm, wide, false);
            const amount: u8 = @intCast((ins >> 10) & 63);
            if (amount != 0) {
                if (wide) try self.put(&.{0x48});
                const shift_modrm: u8 = switch ((ins >> 22) & 3) {
                    0 => 0xe2,
                    1 => 0xea,
                    2 => 0xfa,
                    3 => 0xca,
                    else => unreachable,
                };
                try self.put(&.{ 0xc1, shift_modrm, amount });
            }
            if (ins & 0x00200000 != 0) {
                if (wide) try self.put(&.{0x48});
                try self.put(&.{ 0xf7, 0xd2 });
            }
            if (wide) try self.put(&.{0x48});
            const opcode: u8 = switch ((ins >> 29) & 3) {
                0, 3 => 0x21,
                1 => 0x09,
                2 => 0x31,
                else => unreachable,
            };
            try self.put(&.{ opcode, 0xd0 });
            if (flags_set) try self.flags(false, true);
            try self.storeGuest(rd, false);
            return;
        }
        if (ins & 0x1f000000 == 0x0b000000) {
            const extended = ins & 0x00200000 != 0;
            try self.loadGuest(.rax, rn, wide, extended);
            try self.loadGuest(.rdx, rm, if (extended) true else wide, false);
            if (extended) {
                const option: u3 = @truncate(ins >> 13);
                const bits: u8 = @as(u8, 8) << @as(u2, @truncate(option));
                if (bits != 64) {
                    try self.shift(.rdx, 0, 64 - bits, true);
                    try self.shift(.rdx, if (option & 4 != 0) 2 else 1, 64 - bits, true);
                }
                try self.shift(.rdx, 0, @intCast((ins >> 10) & 7), true);
            } else try self.shift(.rdx, @truncate(ins >> 22), @intCast((ins >> 10) & 63), wide);
            const subtract = ins & 0x40000000 != 0;
            if (wide) try self.put(&.{0x48});
            try self.put(&.{ if (subtract) @as(u8, 0x29) else 0x01, 0xd0 });
            if (ins & 0x20000000 != 0) try self.flags(subtract, false);
            try self.storeGuest(rd, extended and ins & 0x20000000 == 0);
            return;
        }
        if (ins & 0x1fe00000 == 0x1a800000) {
            try self.loadGuest(.rax, rn, wide, false);
            try self.loadGuest(.rdx, rm, wide, false);
            if (ins & 0x40000000 != 0) {
                if (wide) try self.put(&.{0x48});
                try self.put(&.{ 0xf7, 0xd2 });
            }
            if (ins & 0x400 != 0) {
                if (wide) try self.put(&.{0x48});
                try self.put(&.{ 0x83, 0xc2, 1 });
            }
            try self.condition(@truncate(ins >> 12));
            if (wide) try self.put(&.{0x48});
            try self.put(&.{ 0x0f, 0x43, 0xc2 });
            try self.storeGuest(rd, false);
            return;
        }
        if (ins & 0x1fe0fc00 == 0x1a000000) {
            const subtract = ins & 0x40000000 != 0;
            try self.loadGuest(.rax, rn, wide, false);
            try self.loadGuest(.rdx, rm, wide, false);
            try self.put(&.{ 0x41, 0x0f, 0xb6, 0x8a });
            try self.integer(u32, @offsetOf(Cpu, "nzcv"));
            try self.put(&.{ 0x0f, 0xba, 0xe1, 1 });
            if (subtract) try self.put(&.{0xf5});
            if (wide) try self.put(&.{0x48});
            try self.put(&.{ if (subtract) @as(u8, 0x19) else 0x11, 0xd0 });
            if (ins & 0x20000000 != 0) try self.flags(subtract, false);
            try self.storeGuest(rd, false);
            return;
        }
        if (ins & 0x1fe00000 == 0x1a400000) {
            try self.condition(@truncate(ins >> 12));
            const alternate = try self.jump(0x83);
            try self.loadGuest(.rax, rn, wide, false);
            if (ins & 0x800 != 0) try self.immediate(.rdx, rm) else try self.loadGuest(.rdx, rm, wide, false);
            const subtract = ins & 0x40000000 != 0;
            if (wide) try self.put(&.{0x48});
            try self.put(&.{ if (subtract) @as(u8, 0x29) else 0x01, 0xd0 });
            try self.flags(subtract, false);
            const done = try self.jump(0xe9);
            self.patch(alternate);
            try self.put(&.{ 0x41, 0xc6, 0x82 });
            try self.integer(u32, @offsetOf(Cpu, "nzcv"));
            try self.put(&.{@as(u8, @truncate(ins & 15))});
            self.patch(done);
            return;
        }
        if (ins & 0x1fe00000 == 0x1ac00000) {
            const opcode = (ins >> 10) & 63;
            try self.loadGuest(.rax, rn, wide, false);
            try self.loadGuest(.rcx, rm, wide, false);
            if (opcode >= 8) {
                if (wide) try self.put(&.{0x48});
                try self.put(&.{ 0xd3, switch (opcode) {
                    8 => @as(u8, 0xe0),
                    9 => 0xe8,
                    10 => 0xf8,
                    11 => 0xc8,
                    else => unreachable,
                } });
            } else {
                if (wide) try self.put(&.{0x48});
                try self.put(&.{ 0x85, 0xc9 });
                const zero = try self.jump(0x84);
                var overflow: ?usize = null;
                if (opcode == 3) {
                    try self.immediate(.rdx, if (wide) 0x8000000000000000 else 0x80000000);
                    if (wide) try self.put(&.{0x48});
                    try self.put(&.{ 0x39, 0xd0 });
                    const ordinary = try self.jump(0x85);
                    if (wide) try self.put(&.{0x48});
                    try self.put(&.{ 0x83, 0xf9, 0xff });
                    overflow = try self.jump(0x84);
                    self.patch(ordinary);
                    try self.put(if (wide) &.{ 0x48, 0x99 } else &.{0x99});
                } else try self.put(&.{ 0x31, 0xd2 });
                if (wide) try self.put(&.{0x48});
                try self.put(&.{ 0xf7, if (opcode == 3) @as(u8, 0xf9) else 0xf1 });
                const done = try self.jump(0xe9);
                self.patch(zero);
                try self.put(&.{ 0x31, 0xc0 });
                self.patch(done);
                if (overflow) |offset| self.patch(offset);
            }
            try self.storeGuest(rd, false);
            return;
        }
        if (ins & 0x1f000000 == 0x1b000000) {
            const op = (ins >> 21) & 7;
            const ra: u5 = @truncate(ins >> 10);
            try self.loadGuest(.rax, rn, wide and op != 1 and op != 5, false);
            try self.loadGuest(.rdx, rm, wide and op != 1 and op != 5, false);
            if (op == 1) try self.put(&.{ 0x48, 0x63, 0xc0, 0x48, 0x63, 0xd2 });
            if (op == 2 or op == 6) {
                try self.put(&.{ 0x48, 0xf7, if (op == 2) @as(u8, 0xea) else 0xe2, 0x48, 0x89, 0xd0 });
            } else {
                if (wide) try self.put(&.{0x48});
                try self.put(&.{ 0x0f, 0xaf, 0xc2 });
                try self.loadGuest(.rdx, ra, wide, false);
                if (wide) try self.put(&.{0x48});
                if (ins & 0x8000 != 0) {
                    try self.put(&.{ 0x29, 0xc2, 0x48, 0x89, 0xd0 });
                } else try self.put(&.{ 0x01, 0xd0 });
            }
            try self.storeGuest(rd, false);
            return;
        }
        if (ins & 0xff000010 == 0x54000000 or ins & 0x7e000000 == 0x34000000 or ins & 0x7e000000 == 0x36000000) {
            var cmov: u8 = 0x42;
            var displacement: u64 = undefined;
            if (ins & 0xff000010 == 0x54000000) {
                try self.condition(@truncate(ins));
                displacement = signedImmediate((ins >> 5) & 0x7ffff, 19);
            } else {
                try self.loadGuest(.rax, rd, if (ins & 0x7e000000 == 0x34000000) wide else true, false);
                if (ins & 0x7e000000 == 0x34000000) {
                    if (wide) try self.put(&.{0x48});
                    try self.put(&.{ 0x85, 0xc0 });
                    cmov = if (ins & 0x01000000 != 0) 0x45 else 0x44;
                    displacement = signedImmediate((ins >> 5) & 0x7ffff, 19);
                } else {
                    try self.put(&.{ 0x48, 0x0f, 0xba, 0xe0, @intCast(((ins >> 31) << 5) | ((ins >> 19) & 31)) });
                    cmov = if (ins & 0x01000000 != 0) 0x42 else 0x43;
                    displacement = signedImmediate((ins >> 5) & 0x3fff, 14);
                }
            }
            try self.immediate(.rax, pc +% 4);
            try self.immediate(.rdx, pc +% displacement *% 4);
            try self.put(&.{ 0x48, 0x0f, cmov, 0xc2 });
            try self.store(.rax, @offsetOf(Cpu, "pc"));
            return;
        }
        if (ins & 0x7c000000 == 0x14000000) {
            if (wide) {
                try self.immediate(.rax, pc +% 4);
                try self.storeGuest(30, false);
            }
            try self.immediate(.rax, pc +% (signedImmediate(ins & 0x03ffffff, 26) *% 4));
            try self.store(.rax, @offsetOf(Cpu, "pc"));
            return;
        }
        try self.loadGuest(.rax, rn, true, false);
        if (ins & 0xfffffc1f == 0xd63f0000) {
            try self.immediate(.rdx, pc +% 4);
            try self.storeGuestFrom(.rdx, 30, false);
        }
        try self.store(.rax, @offsetOf(Cpu, "pc"));
    }
};

fn signedImmediate(value: u32, comptime bits: u6) u64 {
    const sign: u64 = @as(u64, 1) << (bits - 1);
    return (@as(u64, value) ^ sign) -% sign;
}

test "x64 compiler excludes reserved and unsupported encodings" {
    for ([_]u32{ 0xd503201f, 0x10000000, 0x9000001f, 0x52800000, 0x92800000, 0xf2e0001e, 0x11000000, 0xd10003ff, 0x2a0103e0, 0x8ac1fc20, 0x14000000, 0x94000000, 0xd61f0000, 0xd63f03c0, 0xd65f03c0 }) |word| try std.testing.expect(supports(word));
    for ([_]u32{
        0,          0x32800000, 0x52c00000, 0x72e00000, 0x0a008000, 0xd61f03e0, 0xd63f03e0, 0xd65f03e0, 0xd4000001, 0xd503203f, 0x9e670000, 0xf9400000,
        0x0bc00000, 0x0b008000, 0x0b201400, 0x0b600000, 0x12400000, 0x1200fc00, 0x13400000, 0x53008000, 0x53600000, 0x73000000, 0x13808000, 0x13c00000,
        0x13a00000, 0x1a800800, 0x3a800000, 0x3ac02000, 0x1ac00000, 0x1b200000, 0x9b400000, 0x9b408000,
    }) |word| try std.testing.expect(!supports(word));
    try std.testing.expectError(error.EmptyBlock, compile(std.testing.allocator, &.{}, 0x1000));
    try std.testing.expectError(error.UnalignedInstruction, compile(std.testing.allocator, &.{0xd503201f}, 0x1001));
    try std.testing.expectError(error.UnsupportedInstruction, compile(std.testing.allocator, &.{0xd4000001}, 0x1000));
    try std.testing.expectError(error.InvalidBlock, compile(std.testing.allocator, &.{ 0x14000000, 0xd503201f }, 0x1000));
    for ([_]u32{ 0x54000000, 0x34000000, 0x35000000, 0x36000000, 0x37000000 }) |branch| {
        try std.testing.expect(terminal(branch));
        try std.testing.expectError(error.InvalidBlock, compile(std.testing.allocator, &.{ branch, 0xd503201f }, 0x1000));
    }
}

fn referenceCpu() Cpu {
    var cpu = Cpu{
        .pc = 0x1000,
        .sp = 0xffffffff80000000,
        .nzcv = 0xf,
        .fpcr = 0x07c89f00,
        .fpsr = 0x0800009f,
        .counter = std.math.maxInt(u64) - 2,
        .tpidr_el0 = 0x0102030405060708,
        .tpidrro_el0 = 0x1112131415161718,
        .exclusive_address = 0x12340,
        .exclusive_size = 16,
        .v = @splat(0xfedcba98765432100123456789abcdef),
    };
    for (&cpu.x, 0..) |*value, index| value.* = 0xf123456789abcdef ^ (@as(u64, @intCast(index)) *% 0x9e3779b97f4a7c15);
    cpu.x[0] = 0xffffffffffffffff;
    cpu.x[1] = 0x8000000080000001;
    cpu.x[30] = 0xfedcba9876543210;
    return cpu;
}

fn differential(words: []const u32) !void {
    return differentialCpu(words, referenceCpu());
}

fn differentialCpu(words: []const u32, initial: Cpu) !void {
    const executable = @import("executable.zig");
    if (!executable.supported) return error.SkipZigTest;
    const Memory = @import("zyra_host").Memory;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    try memory.map(0x1000, 0x1000, .{ .read = true, .write = true, .execute = true });
    for (words, 0..) |word, index| try memory.writeInt(u32, 0x1000 + @as(u64, @intCast(index)) * 4, word);
    var expected = initial;
    var actual = expected;
    for (words) |_| try std.testing.expectEqual(.next, try expected.step(&memory));
    const bytes = try compile(std.testing.allocator, words, actual.pc);
    defer std.testing.allocator.free(bytes);
    var code = try executable.Code.init(bytes);
    defer code.deinit();
    code.entry(*const fn (*Cpu) callconv(.c) void)(&actual);
    try std.testing.expectEqualDeep(expected, actual);
}

test "x64 native PC-relative and move-wide operations match interpreter" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    try differential(&.{0xd503201f});
    for ([_]u32{ 0, 1 }) |page| {
        for ([_]u32{ 0, 1, 0xfffff, 0x100000, 0x1ffffe, 0x1fffff }) |immediate| {
            for ([_]u32{ 0, 31 }) |destination| {
                const word = (page << 31) | 0x10000000 | ((immediate & 3) << 29) | ((immediate >> 2) << 5) | destination;
                try differential(&.{word});
            }
        }
    }
    for ([_]u32{ 0, 1 }) |wide| {
        for ([_]u32{ 0, 2, 3 }) |opcode| {
            for (0..(if (wide == 1) @as(usize, 4) else 2)) |halfword| {
                for ([_]u32{ 0, 1, 0x8000, 0xffff }) |immediate| {
                    for ([_]u32{ 0, 30, 31 }) |destination| {
                        const word = (wide << 31) | (opcode << 29) | 0x12800000 | (@as(u32, @intCast(halfword)) << 21) | (immediate << 5) | destination;
                        try differential(&.{word});
                    }
                }
            }
        }
    }
}

test "x64 native add and subtract immediate preserve SP and W semantics" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    for ([_]u32{ 0, 1 }) |wide| {
        for ([_]u32{ 0, 1 }) |subtract| {
            for ([_]u32{ 0, 1 }) |shift| {
                for ([_]u32{ 0, 1, 0x800, 0xfff }) |immediate| {
                    for ([_]u32{ 0, 1, 31 }) |source| {
                        for ([_]u32{ 0, 1, 31 }) |destination| {
                            const word = (wide << 31) | (subtract << 30) | 0x11000000 | (shift << 22) | (immediate << 10) | (source << 5) | destination;
                            try differential(&.{word});
                        }
                    }
                }
            }
        }
    }
}

test "x64 native logical operations match interpreter for shifts inversion and aliases" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    const registers = [_][3]u32{
        .{ 0, 1, 2 },
        .{ 1, 1, 1 },
        .{ 1, 31, 1 },
        .{ 1, 1, 31 },
        .{ 31, 1, 2 },
        .{ 2, 0, 2 },
    };
    for ([_]u32{ 0, 1 }) |wide| {
        for ([_]u32{ 0, 1, 2 }) |opcode| {
            for ([_]u32{ 0, 1 }) |invert| {
                for ([_]u32{ 0, 1, 2, 3 }) |shift| {
                    for ([_]u32{ 0, 1, if (wide == 1) 63 else 31 }) |amount| {
                        for (registers) |regs| {
                            const word = (wide << 31) | (opcode << 29) | 0x0a000000 | (shift << 22) | (invert << 21) | (regs[2] << 16) | (amount << 10) | (regs[1] << 5) | regs[0];
                            try differential(&.{word});
                        }
                    }
                }
            }
        }
    }
}

test "x64 native branch targets and link aliases match interpreter" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    for ([_]u32{ 0, 1 }) |link| {
        for ([_]u32{ 0, 1, 0x03ffffff, 0x03fff800, 0x02000000, 0x01ffffff }) |immediate| {
            try differential(&.{(link << 31) | 0x14000000 | immediate});
        }
    }
    for ([_]u32{ 0xd61f0000, 0xd63f0000, 0xd65f0000 }) |opcode| {
        for ([_]u32{ 0, 1, 30 }) |source| try differential(&.{opcode | (source << 5)});
    }
    try differential(&.{ 0xd2800020, 0xf2e24680, 0x9100001f, 0x11000401, 0x2a0103e2, 0xaa020001, 0x14000000 });
    try differential(&.{ 0x5280001e, 0x12800000, 0x5100041f, 0xf2cffffe, 0xd63f03c0 });
}

test "x64 native cached registers preserve mixed W SP and zero-register operations" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    const words = [_]u32{
        0xf2e24681,
        0x91000421,
        0x91000421,
        0x11000421,
        0xf2a35782,
        0x91000442,
        0x11000442,
        0x910043ff,
        0x110007ff,
        0xd10003ff,
        0x2a1f03e1,
        0xaa0103e2,
        0xf2c579a1,
        0xaa0103ff,
        0x0a020022,
        0xd503201f,
    };
    const selected = selectCache(&words);
    var caches_sp = false;
    for (selected) |entry| caches_sp = caches_sp or entry.guest == 31;
    try std.testing.expect(caches_sp);
    for (3..words.len + 1) |length| try differential(words[0..length]);
}

test "x64 native cached link register overlaps work in each caller-save cache register" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    for (0..3) |variant| {
        var words: [32]u32 = undefined;
        var length: usize = 0;
        for (0..3 + variant * 2) |_| {
            words[length] = 0x91000421;
            length += 1;
            words[length] = 0x110007ff;
            length += 1;
        }
        words[length] = 0x72a2469e;
        length += 1;
        for (0..3) |_| {
            words[length] = 0x910007de;
            length += 1;
        }
        words[length] = 0xd63f03c0;
        const selected = selectCache(words[0 .. length + 1]);
        try std.testing.expectEqual(@as(?u5, 30), selected[variant].guest);
        for ([_]u32{ 0xd61f03c0, 0xd63f03c0, 0xd65f03c0, 0xd63f0020, 0x94000000 }) |branch| {
            words[length] = branch;
            try differential(words[0 .. length + 1]);
        }
    }
}

test "x64 native read-only cached registers preserve their full raw bits" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    const words = [_]u32{
        0xaa010040,
        0x2a010040,
        0xaa010040,
        0x2a010040,
        0xaa010040,
        0x2a010040,
        0xd65f03c0,
    };
    const selected = selectCache(&words);
    try std.testing.expectEqual(@as(?u5, 1), selected[1].guest);
    try std.testing.expectEqual(@as(?u5, 2), selected[2].guest);
    try differential(&words);
}

test "x64 native arithmetic flags shifts and extensions match complete CPU state" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    const registers = [_][3]u32{ .{ 0, 0, 1 }, .{ 1, 1, 1 }, .{ 31, 31, 31 }, .{ 2, 31, 0 }, .{ 31, 0, 31 } };
    const values = [_]u64{ 0, 1, 0x7fffffff, 0x80000000, 0xffffffff, 0x7fffffffffffffff, 0x8000000000000000, 0xffffffffffffffff };
    for ([_]u32{ 0, 1 }) |wide| {
        for ([_]u32{ 0, 1 }) |subtract| {
            for (values) |value| {
                var initial = referenceCpu();
                initial.x[0] = value;
                initial.x[1] = value;
                initial.sp = value;
                for (registers) |regs| {
                    for ([_]u32{ 0, 1, 0xfff }) |immediate| {
                        const word = (wide << 31) | (subtract << 30) | 0x31000000 | (immediate << 10) | (regs[1] << 5) | regs[0];
                        try differentialCpu(&.{word}, initial);
                    }
                    for ([_]u32{ 0, 1, 2 }) |kind| {
                        for ([_]u32{ 0, 1, if (wide == 1) 63 else 31 }) |amount| {
                            const word = (wide << 31) | (subtract << 30) | 0x2b000000 | (kind << 22) | (regs[2] << 16) | (amount << 10) | (regs[1] << 5) | regs[0];
                            try differentialCpu(&.{word}, initial);
                        }
                    }
                    for (0..8) |option| {
                        for ([_]u32{ 0, 4 }) |amount| {
                            const word = (wide << 31) | (subtract << 30) | 0x2b200000 | (regs[2] << 16) | (@as(u32, @intCast(option)) << 13) | (amount << 10) | (regs[1] << 5) | regs[0];
                            try differentialCpu(&.{word}, initial);
                        }
                    }
                }
            }
        }
    }
    try differential(&.{ 0x910007ff, 0xb10007ff, 0xcb010021, 0xeb81fc3f, 0x31000400, 0xab214001, 0x2b21401f, 0x8b2143ff, 0x91000421, 0x91000421, 0x540000a8 });
}

test "x64 native logical immediates bitfields extract and flag chains match interpreter" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    for ([_]u32{ 0, 1 }) |wide| {
        for ([_]u32{ 0, 1 }) |n| {
            for ([_]u32{ 0, 1, 7, 15, 31, 32, 63 }) |s| {
                for ([_]u32{ 0, 1, 15, 31, 32, 63 }) |r| {
                    for (0..4) |opcode| {
                        const logical = (wide << 31) | (@as(u32, @intCast(opcode)) << 29) | 0x12000000 | (n << 22) | (r << 16) | (s << 10) | (1 << 5);
                        if (supports(logical)) {
                            try differential(&.{logical});
                            try differential(&.{ logical | 31, 0x54000082 });
                        }
                        if (opcode == 3) continue;
                        const bitfield = (wide << 31) | (@as(u32, @intCast(opcode)) << 29) | 0x13000000 | (n << 22) | (r << 16) | (s << 10) | (1 << 5);
                        if (supports(bitfield)) {
                            try differential(&.{bitfield});
                            try differential(&.{ bitfield | 1, bitfield | 31 });
                        }
                    }
                }
            }
        }
        for ([_]u32{ 0, 1, if (wide == 1) 63 else 31 }) |amount| {
            const extr = (wide << 31) | 0x13800000 | (wide << 22) | (1 << 16) | (amount << 10) | (2 << 5);
            try differential(&.{extr});
            try differential(&.{extr | 1});
            try differential(&.{extr | 31});
        }
        for (0..4) |shift_kind| {
            for ([_]u32{ 0, 1, if (wide == 1) 63 else 31 }) |amount| {
                const ands = (wide << 31) | 0x6a010020 | (@as(u32, @intCast(shift_kind)) << 22) | (amount << 10);
                try differential(&.{ ands, 0x54000088 });
                try differential(&.{ ands | 0x0020001f, 0x54000088 });
            }
        }
    }
}

test "x64 native conditional exits and select families match every NZCV condition" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    for (0..16) |flags_value| {
        var initial = referenceCpu();
        initial.nzcv = @intCast(flags_value);
        for (0..16) |condition_value| {
            const cond: u32 = @intCast(condition_value);
            for ([_]u32{ 0, 1, 0x7ffff, 0x40000 }) |immediate| try differentialCpu(&.{0x54000000 | (immediate << 5) | cond}, initial);
            for ([_]u32{ 0, 1 }) |wide| {
                for ([_]u32{ 0, 1 }) |invert| {
                    for ([_]u32{ 0, 1 }) |increment| {
                        const word = (wide << 31) | (invert << 30) | 0x1a810040 | (cond << 12) | (increment << 10);
                        try differentialCpu(&.{word}, initial);
                        try differentialCpu(&.{ word | 1, word | 31 }, initial);
                    }
                }
            }
        }
    }
    for ([_]u64{ 0, 1, 0x100000000, 0x8000000000000000, 0xffffffffffffffff }) |value| {
        var initial = referenceCpu();
        initial.x[0] = value;
        for ([_]u32{ 0, 1 }) |wide| {
            for ([_]u32{ 0, 1 }) |nonzero| {
                for ([_]u32{ 0, 1, 0x7ffff, 0x40000 }) |immediate| {
                    const cb = (wide << 31) | (nonzero << 24) | 0x34000000 | (immediate << 5);
                    try differentialCpu(&.{cb}, initial);
                    try differentialCpu(&.{cb | 31}, initial);
                }
                for ([_]u32{ 0, 1, 15, 31 }) |bit| {
                    for ([_]u32{ 0, 1, 0x3fff, 0x2000 }) |immediate| {
                        const tb = (wide << 31) | (nonzero << 24) | 0x36000000 | (bit << 19) | (immediate << 5);
                        try differentialCpu(&.{tb}, initial);
                        try differentialCpu(&.{tb | 31}, initial);
                    }
                }
            }
        }
    }
}

test "x64 native multiply divide and variable shifts preserve exact integer boundary semantics" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    const values = [_]u64{ 0, 1, 2, 31, 32, 63, 64, 0x7fffffff, 0x80000000, 0xffffffff, 0x7fffffffffffffff, 0x8000000000000000, 0xffffffffffffffff };
    for ([_]u32{ 0, 1 }) |wide| {
        for (values) |lhs| {
            for (values) |rhs| {
                var initial = referenceCpu();
                initial.x[0] = lhs;
                initial.x[1] = rhs;
                for ([_]u32{ 2, 3, 8, 9, 10, 11 }) |opcode| {
                    const word = (wide << 31) | 0x1ac10000 | (opcode << 10);
                    try differentialCpu(&.{word}, initial);
                }
                for ([_]u32{ 0, 1, 2, 5, 6 }) |opcode| {
                    if (wide == 0 and opcode != 0) continue;
                    for ([_]u32{ 0, 1 }) |subtract| {
                        if ((opcode == 2 or opcode == 6) and subtract != 0) continue;
                        const accumulator: u32 = if (opcode == 2 or opcode == 6) 31 else 2;
                        const word = (wide << 31) | 0x1b010000 | (opcode << 21) | (subtract << 15) | (accumulator << 10);
                        try differentialCpu(&.{word}, initial);
                    }
                }
            }
        }
    }
    try differential(&.{ 0x91000421, 0x91000421, 0x9b017c20, 0x9ac12021, 0x9ac10c00, 0x9b218022, 0x1ac02442, 0x9b017c42, 0x91000442, 0x91000421, 0xb100043f, 0x54000082 });
}

test "x64 native carry arithmetic and conditional compares preserve exact flags and fallback choices" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    const values = [_]u64{ 0, 1, 0x7fffffff, 0x80000000, 0xffffffff, 0x7fffffffffffffff, 0x8000000000000000, 0xffffffffffffffff };
    for ([_]u32{ 0, 1 }) |wide| {
        for ([_]u32{ 0, 1 }) |subtract| {
            for ([_]u32{ 0, 1 }) |set_flags| {
                for (values) |lhs| {
                    for (values) |rhs| {
                        for ([_]u4{ 0, 2, 13, 15 }) |flags_value| {
                            var initial = referenceCpu();
                            initial.nzcv = flags_value;
                            initial.x[0] = lhs;
                            initial.x[1] = rhs;
                            const word = (wide << 31) | (subtract << 30) | (set_flags << 29) | 0x1a010000;
                            try differentialCpu(&.{word}, initial);
                            try differentialCpu(&.{word | 31}, initial);
                        }
                    }
                }
            }
            for (0..16) |condition_value| {
                for (0..16) |flags_value| {
                    var initial = referenceCpu();
                    initial.nzcv = @intCast(flags_value);
                    for ([_]u32{ 0, 1 }) |immediate| {
                        const word = (wide << 31) | (subtract << 30) | 0x3a410007 | (@as(u32, @intCast(condition_value)) << 12) | (immediate << 11);
                        try differentialCpu(&.{word}, initial);
                    }
                }
            }
        }
    }
    try differential(&.{ 0x91000421, 0x91000421, 0xb1000400, 0xba010021, 0xfa010021, 0x3a41d805, 0x7a41a001, 0x54000082 });
}

test "x64 native wider integer chunks preserve dependent registers flags and complete metadata" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    const instructions = [_]u32{
        0x8b020020, 0xab020020, 0xcb020020, 0xeb020020,
        0x8b820020, 0xeb420020, 0x8b22c020, 0xab22c020,
        0xba020020, 0xfa020020, 0x1a020020, 0x5a020020,
        0xaa020020, 0x6a020020, 0xea220020, 0x2a420020,
        0x92401c20, 0xb2401c20, 0xf2401c20, 0xd3401c20,
        0x93401c20, 0xb3401c20, 0x93c22020, 0x13822020,
        0x9a820020, 0xda820420, 0x1a820420, 0x5a820020,
        0x9ac22020, 0x1ac22420, 0x9ac22820, 0x9ac22c20,
        0x9b020c20, 0x1b028c20, 0x9b22fc20, 0x9ba20c20,
        0x9b427c20, 0x9bc27c20, 0x9ac20c20, 0x1ac20820,
        0x3a420020, 0x7a420825, 0x91000420, 0x7100043f,
    };
    var random: u64 = 0x214d314159265359;
    for (0..128) |variant| {
        var words: [32]u32 = undefined;
        for (&words, 0..) |*word, index| {
            random ^= random << 13;
            random ^= random >> 7;
            random ^= random << 17;
            const selected: usize = @intCast(random % instructions.len);
            word.* = instructions[selected];
            if (selected >= 24 and selected < 28 or selected >= 40 and selected < 42) word.* |= @as(u32, @intCast((variant + index) % 16)) << 12;
        }
        words[31] = 0x54000000 | @as(u32, @intCast(variant % 16));
        var initial = referenceCpu();
        initial.nzcv = @intCast(variant % 16);
        initial.x[0] = random;
        initial.x[1] = ~random;
        initial.x[2] = random +% 1;
        try differentialCpu(&words, initial);
        for ([_]usize{ 3, 7, 15, 31 }) |length| try differentialCpu(words[0..length], initial);
    }
}

test "x64 reserved wider integer encodings decline before guest execution" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    const Memory = @import("zyra_host").Memory;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    const words = [_]u32{
        0x0bc00000, 0x0b008000, 0x0b201400, 0x0b600000,
        0x12400000, 0x1200fc00, 0x13400000, 0x53008000,
        0x53600000, 0x73000000, 0x13808000, 0x13c00000,
        0x13a00000, 0x1a800800, 0x3a800000, 0x3ac02000,
        0x1b200000, 0x9b400000, 0x9b408000, 0x1a400000,
        0x3a400010, 0x3a400400,
    };
    for (words) |word| {
        try std.testing.expect(!supports(word));
        try std.testing.expectError(error.UnsupportedInstruction, compile(std.testing.allocator, &.{word}, 0x1000));
        var expected = referenceCpu();
        try std.testing.expectError(error.UndefinedInstruction, expected.stepFetched(&memory, word));
        var faulted = referenceCpu();
        faulted.last_pc = faulted.pc;
        faulted.last_instruction = word;
        try std.testing.expectEqualDeep(faulted, expected);
    }
}
