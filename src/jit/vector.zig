const std = @import("std");
const Cpu = @import("zyra_host").Cpu;

pub const Operation = enum {
    and_bits,
    bic_bits,
    or_bits,
    orn_bits,
    xor_bits,
    select_bits,
    insert_bits,
    insert_not_bits,
    add,
    subtract,
    multiply,
    negate,
    minimum_signed,
    maximum_signed,
    minimum_unsigned,
    maximum_unsigned,
    equal,
    greater_signed,
    greater_equal_signed,
    greater_unsigned,
    greater_equal_unsigned,
    test_bits,
    equal_zero,
    greater_zero,
    greater_equal_zero,
    less_zero,
    less_equal_zero,
    count_bits,
    sum,
    shift_left,
    shift_right_unsigned,
    shift_right_signed,
    duplicate_lane,
    duplicate_register,
    insert_register,
    insert_lane,
    move_unsigned,
    move_signed,
    scalar_lane,
    immediate,
    or_immediate,
    bic_immediate,
    extract,
    unzip,
    transpose,
    zip,
    scalar_abs,
    scalar_negate,
    vector_abs,
    vector_negate,
    move_to_integer,
    move_from_integer,
    move_upper_to_integer,
    move_integer_to_upper,
    scalar_move,
    scalar_immediate,
    scalar_select,
    float_add,
    float_subtract,
    float_multiply,
    float_divide,
    float_fused_add,
    float_fused_subtract,
    float_sqrt,
    float_equal,
    float_greater_equal,
    float_greater,
    scalar_fused,
    scalar_compare,
    scalar_cond_compare,
    convert_to_integer,
    convert_to_float,
};

pub const Decoded = struct {
    operation: Operation,
    rd: u5,
    rn: u5,
    rm: u5,
    lane_bytes: u8 = 1,
    bytes: u8 = 16,
    index: u5 = 0,
    source_index: u5 = 0,
    shift: u8 = 0,
    immediate: u128 = 0,
    count: u8 = 0,
    width: u7 = 64,
    fractional_bits: u7 = 0,
    round_mode: u3 = 0,
    unsigned: bool = false,
    signal: bool = false,
    negate_product: bool = false,
    negate_addend: bool = false,
};

pub fn supports(ins: u32) bool {
    return decode(ins) != null;
}

pub fn decode(ins: u32) ?Decoded {
    var d: Decoded = .{ .operation = undefined, .rd = @truncate(ins), .rn = @truncate(ins >> 5), .rm = @truncate(ins >> 16), .bytes = if (ins & 0x40000000 != 0) 16 else 8 };
    const logical: ?Operation = switch (ins & 0xbfe0fc00) {
        0x0e201c00 => .and_bits,
        0x0e601c00 => .bic_bits,
        0x0ea01c00 => .or_bits,
        0x0ee01c00 => .orn_bits,
        0x2e201c00 => .xor_bits,
        0x2e601c00 => .select_bits,
        0x2ea01c00 => .insert_bits,
        0x2ee01c00 => .insert_not_bits,
        else => null,
    };
    if (logical) |op| {
        d.operation = op;
        return d;
    }
    const three = ins & 0xbf20fc00;
    const same: ?Operation = switch (three) {
        0x0e208400 => .add,
        0x2e208400 => .subtract,
        0x0e209c00 => .multiply,
        0x0e203400 => .greater_signed,
        0x0e203c00 => .greater_equal_signed,
        0x2e203400 => .greater_unsigned,
        0x2e203c00 => .greater_equal_unsigned,
        0x0e208c00 => .test_bits,
        0x2e208c00 => .equal,
        else => null,
    };
    if (same) |op| {
        d.lane_bytes = @as(u8, 1) << @as(u2, @truncate(ins >> 22));
        if (d.lane_bytes == 8 and (d.bytes != 16 or op == .multiply)) return null;
        d.operation = op;
        return d;
    }
    if (ins & 0x9f20f400 == 0x0e206400) {
        d.lane_bytes = @as(u8, 1) << @as(u2, @truncate(ins >> 22));
        if (d.lane_bytes == 8) return null;
        d.operation = if (ins & 0x20000000 != 0) (if (ins & 0x800 != 0) .minimum_unsigned else .maximum_unsigned) else (if (ins & 0x800 != 0) .minimum_signed else .maximum_signed);
        return d;
    }
    const scalar_negate = ins & 0xff3ffc00 == 0x7e20b800;
    if (scalar_negate or ins & 0xbf3ffc00 == 0x2e20b800) {
        d.lane_bytes = @as(u8, 1) << @as(u2, @truncate(ins >> 22));
        if ((scalar_negate and d.lane_bytes != 8) or (!scalar_negate and d.lane_bytes == 8 and d.bytes != 16)) return null;
        if (scalar_negate) d.bytes = 8;
        d.operation = .negate;
        return d;
    }
    const zero: ?Operation = switch (ins & 0xbf3ffc00) {
        0x2e208800 => .greater_equal_zero,
        0x0e208800 => .greater_zero,
        0x2e209800 => .less_equal_zero,
        0x0e20a800 => .less_zero,
        0x0e209800 => .equal_zero,
        else => null,
    };
    if (zero) |op| {
        d.lane_bytes = @as(u8, 1) << @as(u2, @truncate(ins >> 22));
        if (d.lane_bytes == 8 and d.bytes != 16) return null;
        d.operation = op;
        return d;
    }
    if (ins & 0xbf3ffc00 == 0x0e205800) {
        if (ins & 0x00c00000 != 0) return null;
        d.operation = .count_bits;
        return d;
    }
    if (ins & 0xbf3ffc00 == 0x0e31b800) {
        d.lane_bytes = @as(u8, 1) << @as(u2, @truncate(ins >> 22));
        if (d.lane_bytes == 8 or (d.lane_bytes == 4 and d.bytes == 8)) return null;
        d.operation = .sum;
        return d;
    }
    const fp_sign = ins & 0xbfbffc00;
    if (fp_sign == 0x0ea0f800 or fp_sign == 0x2ea0f800) {
        d.lane_bytes = if (ins & 0x00400000 != 0) 8 else 4;
        if (d.lane_bytes == 8 and d.bytes == 8) return null;
        d.operation = if (fp_sign == 0x2ea0f800) .vector_negate else .vector_abs;
        return d;
    }
    const copy = ins & 0xbfe0fc00;
    const scalar_copy = ins & 0xffe0fc00 == 0x5e000400;
    if (scalar_copy or copy == 0x0e000400 or copy == 0x0e000c00 or copy == 0x0e001c00 or copy == 0x0e002c00 or copy == 0x0e003c00 or ins & 0xffe08400 == 0x6e000400) {
        const imm5: u5 = @truncate(ins >> 16);
        if (imm5 == 0) return null;
        const scale = @ctz(imm5);
        if (scale > 3) return null;
        d.lane_bytes = @as(u8, 1) << @as(u3, @intCast(scale));
        d.index = @intCast(imm5 >> @as(u3, @intCast(scale + 1)));
        if (scalar_copy) {
            if (d.lane_bytes != 8) return null;
            d.operation = .scalar_lane;
        } else if (ins & 0xffe08400 == 0x6e000400) {
            const imm4: u4 = @truncate(ins >> 11);
            if (imm4 & (d.lane_bytes - 1) != 0) return null;
            d.source_index = @intCast(imm4 >> @as(u2, @intCast(scale)));
            d.operation = .insert_lane;
        } else switch (copy) {
            0x0e000400 => {
                if (d.lane_bytes == 8 and d.bytes != 16) return null;
                d.operation = .duplicate_lane;
            },
            0x0e000c00 => {
                if (d.index != 0 or d.lane_bytes > d.bytes / 2) return null;
                d.operation = .duplicate_register;
            },
            0x0e001c00 => {
                if (d.bytes != 16) return null;
                d.operation = .insert_register;
            },
            0x0e003c00 => {
                if ((d.bytes == 16) != (d.lane_bytes == 8)) return null;
                d.operation = .move_unsigned;
            },
            0x0e002c00 => {
                if (d.lane_bytes >= (if (d.bytes == 16) @as(u8, 8) else 4)) return null;
                d.operation = .move_signed;
            },
            else => unreachable,
        }
        return d;
    }
    if (ins & 0x9ff80c00 == 0x0f000400) {
        const cmode: u4 = @truncate(ins >> 12);
        const op = ins & 0x20000000 != 0;
        const imm: u8 = @intCast(((ins >> 16) & 7) << 5 | ((ins >> 5) & 31));
        var element: u64 = undefined;
        if (cmode < 8) {
            element = @as(u64, imm) << (@as(u6, cmode >> 1) * 8);
            d.lane_bytes = 4;
        } else if (cmode < 12) {
            element = @as(u64, imm) << @as(u6, if (cmode & 2 != 0) 8 else 0);
            d.lane_bytes = 2;
        } else switch (cmode) {
            12 => {
                element = (@as(u64, imm) << 8) | 255;
                d.lane_bytes = 4;
            },
            13 => {
                element = (@as(u64, imm) << 16) | 65535;
                d.lane_bytes = 4;
            },
            14 => {
                if (op) {
                    element = 0;
                    d.lane_bytes = 8;
                    for (0..8) |bit| if (imm & (@as(u8, 1) << @intCast(bit)) != 0) {
                        element |= @as(u64, 255) << @intCast(bit * 8);
                    };
                } else {
                    element = imm;
                    d.lane_bytes = 1;
                }
            },
            15 => {
                if (op and d.bytes != 16) return null;
                d.lane_bytes = if (op) 8 else 4;
                element = floatImmediate(imm, d.lane_bytes * 8);
            },
            else => unreachable,
        }
        d.immediate = replicate(element, d.lane_bytes);
        if (cmode < 12 and cmode & 1 != 0) d.operation = if (op) .bic_immediate else .or_immediate else {
            d.operation = .immediate;
            if (op and cmode < 14) d.immediate = ~d.immediate;
        }
        return d;
    }
    if (ins & 0xbfe08400 == 0x2e000000) {
        d.index = @as(u4, @truncate(ins >> 11));
        if (d.index >= d.bytes) return null;
        d.operation = .extract;
        return d;
    }
    const left = ins & 0xbf80fc00 == 0x0f005400;
    const right = ins & 0x9f80fc00 == 0x0f000400;
    if (left or right) {
        const imm: u7 = @truncate(ins >> 16);
        const immh: u4 = @truncate(imm >> 3);
        if (immh == 0) return null;
        d.lane_bytes = @as(u8, 1) << @as(u3, @intCast(3 - @clz(immh)));
        if (d.lane_bytes == 8 and d.bytes != 16) return null;
        d.shift = if (left) imm - d.lane_bytes * 8 else d.lane_bytes * 16 - imm;
        d.operation = if (left) .shift_left else if (ins & 0x20000000 != 0) .shift_right_unsigned else .shift_right_signed;
        return d;
    }
    const permute: ?Operation = switch (ins & 0xbf20fc00) {
        0x0e001800, 0x0e005800 => .unzip,
        0x0e002800, 0x0e006800 => .transpose,
        0x0e003800, 0x0e007800 => .zip,
        else => null,
    };
    if (permute) |op| {
        d.lane_bytes = @as(u8, 1) << @as(u2, @truncate(ins >> 22));
        if (d.lane_bytes == 8 and d.bytes != 16) return null;
        d.index = @intCast((ins >> 14) & 1);
        d.operation = op;
        return d;
    }
    const scalar_sign = ins & 0xff3ffc00;
    if (scalar_sign == 0x1e20c000 or scalar_sign == 0x1e214000) {
        if ((ins >> 22) & 3 > 1) return null;
        d.lane_bytes = if (ins & 0x00400000 != 0) 8 else 4;
        d.operation = if (scalar_sign == 0x1e214000) .scalar_negate else .scalar_abs;
        return d;
    }
    if (ins & 0x5f20fc00 == 0x1e200000) {
        const opcode: u5 = @truncate(ins >> 16);
        const fp_type: u2 = @truncate(ins >> 22);
        const width: u8 = if (ins >> 31 != 0) 8 else 4;
        if (opcode == 6 or opcode == 7 or opcode == 14 or opcode == 15) {
            if ((fp_type == 0 and width != 4) or (fp_type == 1 and width != 8) or fp_type == 3 or
                (fp_type == 2 and (width != 8 or opcode < 14)) or (fp_type != 2 and opcode >= 14)) return null;
            d.lane_bytes = width;
            d.operation = if (opcode < 14) (if (opcode & 1 == 0) .move_to_integer else .move_from_integer) else (if (opcode & 1 == 0) .move_upper_to_integer else .move_integer_to_upper);
            return d;
        }
    }
    if ((ins >> 22) & 3 <= 1) {
        d.lane_bytes = if (ins & 0x00400000 != 0) 8 else 4;
        if (ins & 0xff201fe0 == 0x1e201000) {
            d.operation = .scalar_immediate;
            d.immediate = floatImmediate(@truncate(ins >> 13), d.lane_bytes * 8);
            return d;
        }
        if (ins & 0xff200c00 == 0x1e200c00) {
            d.operation = .scalar_select;
            d.index = @intCast((ins >> 12) & 15);
            return d;
        }
        if (ins & 0xff207c00 == 0x1e204000 and (ins >> 15) & 63 == 0) {
            d.operation = .scalar_move;
            return d;
        }
        if (ins & 0xff200c00 == 0x1e200800) {
            d.operation = switch ((ins >> 12) & 15) {
                0 => .float_multiply,
                1 => .float_divide,
                2 => .float_add,
                3 => .float_subtract,
                else => return null,
            };
            d.count = 1;
            return d;
        }
        if (ins & 0xff207c00 == 0x1e204000 and (ins >> 15) & 63 == 3) {
            d.operation = .float_sqrt;
            d.count = 1;
            return d;
        }
        if (ins & 0xff000000 == 0x1f000000) {
            d.operation = .scalar_fused;
            d.index = @truncate(ins >> 10);
            d.negate_product = (ins & 0x00200000 != 0) != (ins & 0x00008000 != 0);
            d.negate_addend = ins & 0x00200000 != 0;
            return d;
        }
        if (ins & 0xff20fc00 == 0x1e202000) {
            if (ins & 7 != 0 or (ins & 8 != 0 and d.rm != 0)) return null;
            d.operation = .scalar_compare;
            d.signal = ins & 16 != 0;
            d.unsigned = ins & 8 != 0;
            return d;
        }
        if (ins & 0xff200c00 == 0x1e200400) {
            d.operation = .scalar_cond_compare;
            d.index = @truncate(ins >> 12);
            d.signal = ins & 16 != 0;
            d.immediate = ins & 15;
            return d;
        }
        if (ins & 0x5f20fc00 == 0x1e200000 or ins & 0x5f200000 == 0x1e000000) {
            const opcode: u5 = @truncate(ins >> 16);
            const fixed = ins & 0x00200000 == 0;
            d.width = if (ins >> 31 != 0) 64 else 32;
            d.fractional_bits = if (fixed) 64 - @as(u7, @intCast((ins >> 10) & 63)) else 0;
            if (fixed and (d.fractional_bits > d.width or (opcode != 2 and opcode != 3 and opcode != 24 and opcode != 25))) return null;
            d.unsigned = opcode & 1 != 0;
            if (opcode == 2 or opcode == 3) d.operation = .convert_to_float else {
                d.operation = .convert_to_integer;
                d.round_mode = switch (opcode & 30) {
                    0 => 0,
                    4 => 4,
                    8 => 1,
                    16 => 2,
                    24 => 3,
                    else => return null,
                };
            }
            return d;
        }
    }
    var float_op: ?Operation = null;
    var scalar = false;
    const scalar_compare = ins & 0xffa0fc00;
    if (scalar_compare == 0x5e20e400 or scalar_compare == 0x7e20e400 or scalar_compare == 0x7ea0e400) scalar = true;
    float_op = switch (if (scalar) scalar_compare else ins & 0xbfa0fc00) {
        0x0e20e400, 0x5e20e400 => .float_equal,
        0x2e20e400, 0x7e20e400 => .float_greater_equal,
        0x2ea0e400, 0x7ea0e400 => .float_greater,
        else => null,
    };
    if (ins & 0xbf20fc00 == 0x0e20d400) float_op = if (ins & 0x00800000 != 0) .float_subtract else .float_add;
    if (ins & 0xbfa0fc00 == 0x2e20dc00) float_op = .float_multiply;
    if (ins & 0xbf20fc00 == 0x0e20cc00) float_op = if (ins & 0x00800000 != 0) .float_fused_subtract else .float_fused_add;
    if (ins & 0xbfa0fc00 == 0x2e20fc00) float_op = .float_divide;
    if (ins & 0xbfbffc00 == 0x2ea1f800) float_op = .float_sqrt;
    if (float_op) |op| {
        d.lane_bytes = if (ins & 0x00400000 != 0) 8 else 4;
        if (!scalar and d.lane_bytes == 8 and d.bytes != 16) return null;
        d.count = if (scalar) 1 else d.bytes / d.lane_bytes;
        d.operation = op;
        return d;
    }
    return null;
}

pub fn execute(cpu: *Cpu, ins: u32) !void {
    std.debug.assert(cpu.pc & 3 == 0);
    cpu.last_pc = cpu.pc;
    cpu.last_instruction = ins;
    const d = decode(ins) orelse return error.UnsupportedInstruction;
    try executeDecoded(cpu, d);
    cpu.pc +%= 4;
    cpu.counter +%= 1;
}

pub fn executeDecoded(cpu: *Cpu, d: Decoded) !void {
    const a = cpu.v[d.rn];
    const b = cpu.v[d.rm];
    const old = cpu.v[d.rd];
    const vector_mask: u128 = if (d.bytes == 16) std.math.maxInt(u128) else std.math.maxInt(u64);
    var value: u128 = undefined;
    switch (d.operation) {
        .float_add, .float_subtract, .float_multiply, .float_divide, .float_fused_add, .float_fused_subtract, .float_sqrt, .float_equal, .float_greater_equal, .float_greater => {
            if (d.lane_bytes == 4) {
                if (fastFloat32(cpu, d, a, b)) |fast| {
                    cpu.v[d.rd] = fast;
                    return;
                }
            }
            const op: Cpu.FloatVectorOperation = switch (d.operation) {
                .float_add => .add,
                .float_subtract => .subtract,
                .float_multiply => .multiply,
                .float_divide => .divide,
                .float_fused_add => .fused_add,
                .float_fused_subtract => .fused_subtract,
                .float_sqrt => .sqrt,
                .float_equal => .equal,
                .float_greater_equal => .greater_equal,
                .float_greater => .greater,
                else => unreachable,
            };
            cpu.v[d.rd] = if (d.lane_bytes == 8) try cpu.evaluateFloatVector(f64, op, a, b, old, d.count) else try cpu.evaluateFloatVector(f32, op, a, b, old, d.count);
            return;
        },
        .scalar_fused => {
            cpu.v[d.rd] = if (d.lane_bytes == 8) try cpu.evaluateFloatFused(f64, @truncate(a), @truncate(b), @truncate(cpu.v[d.index]), d.negate_product, d.negate_addend) else try cpu.evaluateFloatFused(f32, @truncate(a), @truncate(b), @truncate(cpu.v[d.index]), d.negate_product, d.negate_addend);
            return;
        },
        .scalar_compare, .scalar_cond_compare => {
            if (d.operation == .scalar_cond_compare and !condition(cpu.nzcv, @intCast(d.index))) {
                if (cpu.fpcr & 0x00009f00 != 0) return error.UnsupportedFloatingPointTrap;
                cpu.nzcv = @truncate(d.immediate);
                return;
            }
            const second: u64 = if (d.operation == .scalar_compare and d.unsigned) 0 else @truncate(b);
            if (d.lane_bytes == 8) try cpu.evaluateFloatCompare(f64, @truncate(a), second, d.signal) else try cpu.evaluateFloatCompare(f32, @truncate(a), second, d.signal);
            return;
        },
        .convert_to_float, .convert_to_integer => {
            const to_integer = d.operation == .convert_to_integer;
            const source: u64 = if (to_integer) @truncate(a) else register(cpu, d.rn);
            const result = if (d.lane_bytes == 8) try cpu.evaluateFloatConvert(f64, source, d.width, to_integer, d.unsigned, d.fractional_bits, d.round_mode) else try cpu.evaluateFloatConvert(f32, source, d.width, to_integer, d.unsigned, d.fractional_bits, d.round_mode);
            if (to_integer) {
                if (d.rd != 31) cpu.x[d.rd] = result & @as(u64, if (d.width == 64) std.math.maxInt(u64) else std.math.maxInt(u32));
            } else cpu.v[d.rd] = result;
            return;
        },
        .and_bits => value = a & b,
        .bic_bits => value = a & ~b,
        .or_bits => value = a | b,
        .orn_bits => value = a | ~b,
        .xor_bits => value = a ^ b,
        .select_bits => value = (old & a) | (~old & b),
        .insert_bits => value = (old & ~b) | (a & b),
        .insert_not_bits => value = (old & b) | (a & ~b),
        .immediate => value = d.immediate,
        .or_immediate => value = old | d.immediate,
        .bic_immediate => value = old & ~d.immediate,
        .count_bits => value = @bitCast(@as(@Vector(16, u8), @intCast(@popCount(@as(@Vector(16, u8), @bitCast(a)))))),
        .vector_abs, .vector_negate => {
            const signs = replicate(@as(u64, 1) << @as(u6, @intCast(d.lane_bytes * 8 - 1)), d.lane_bytes);
            value = if (d.operation == .vector_negate) a ^ signs else a & ~signs;
        },
        .scalar_abs, .scalar_negate => {
            const sign: u128 = @as(u128, 1) << @as(u7, @intCast(d.lane_bytes * 8 - 1));
            cpu.v[d.rd] = (if (d.operation == .scalar_negate) a ^ sign else a & ~sign) & laneMask(d.lane_bytes);
            return;
        },
        .duplicate_lane => value = replicate(lane(a, d.index, d.lane_bytes), d.lane_bytes),
        .duplicate_register => value = replicate(register(cpu, d.rn), d.lane_bytes),
        .insert_register => {
            cpu.v[d.rd] = insert(old, d.index, d.lane_bytes, register(cpu, d.rn));
            return;
        },
        .insert_lane => {
            cpu.v[d.rd] = insert(old, d.index, d.lane_bytes, lane(a, d.source_index, d.lane_bytes));
            return;
        },
        .scalar_lane => {
            cpu.v[d.rd] = lane(a, d.index, d.lane_bytes);
            return;
        },
        .move_unsigned, .move_signed => {
            const raw = lane(a, d.index, d.lane_bytes);
            const result = if (d.operation == .move_signed) signedBits(raw, d.lane_bytes) else raw;
            if (d.rd != 31) cpu.x[d.rd] = result & @as(u64, if (d.bytes == 16) std.math.maxInt(u64) else std.math.maxInt(u32));
            return;
        },
        .move_to_integer, .move_upper_to_integer => {
            if (d.rd != 31) cpu.x[d.rd] = lane(a, if (d.operation == .move_upper_to_integer) 1 else 0, d.lane_bytes);
            return;
        },
        .move_from_integer => {
            cpu.v[d.rd] = register(cpu, d.rn) & laneMask(d.lane_bytes);
            return;
        },
        .move_integer_to_upper => {
            cpu.v[d.rd] = insert(old, 1, 8, register(cpu, d.rn));
            return;
        },
        .scalar_move => {
            cpu.v[d.rd] = a & laneMask(d.lane_bytes);
            return;
        },
        .scalar_immediate => {
            cpu.v[d.rd] = d.immediate;
            return;
        },
        .scalar_select => {
            cpu.v[d.rd] = (if (condition(cpu.nzcv, @intCast(d.index))) a else b) & laneMask(d.lane_bytes);
            return;
        },
        .extract => {
            const shift: u7 = @as(u7, d.index) * 8;
            value = if (shift == 0) a else (a >> shift) | (b << @as(u7, @intCast(d.bytes * 8 - shift)));
        },
        .unzip, .transpose, .zip => {
            value = 0;
            const count = d.bytes / d.lane_bytes;
            for (0..count) |i| {
                const source = if (d.operation == .unzip) (if (i < count / 2) a else b) else (if (i & 1 == 0) a else b);
                const source_lane: u5 = @intCast(switch (d.operation) {
                    .unzip => (i % (count / 2)) * 2 + d.index,
                    .transpose => (i / 2) * 2 + d.index,
                    .zip => i / 2 + @as(usize, d.index) * (count / 2),
                    else => unreachable,
                });
                value = insert(value, @intCast(i), d.lane_bytes, lane(source, source_lane, d.lane_bytes));
            }
        },
        else => value = switch (d.lane_bytes) {
            1 => arithmetic(u8, d, a & vector_mask, b),
            2 => arithmetic(u16, d, a & vector_mask, b),
            4 => arithmetic(u32, d, a & vector_mask, b),
            8 => arithmetic(u64, d, a & vector_mask, b),
            else => unreachable,
        },
    }
    cpu.v[d.rd] = value & vector_mask;
}

fn fastFloat32(cpu: *Cpu, d: Decoded, a_bits: u128, b_bits: u128) ?u128 {
    if (cpu.fpcr & 0x03c09f00 != 0 or (d.operation != .float_add and d.operation != .float_subtract and d.operation != .float_multiply)) return null;
    const a: [4]f32 = @bitCast(a_bits);
    const b: [4]f32 = @bitCast(b_bits);
    var exact: [4]f64 = @splat(0);
    for (0..d.count) |i| {
        const first: u32 = @bitCast(a[i]);
        const second: u32 = @bitCast(b[i]);
        const ae: u8 = @truncate(first >> 23);
        const be: u8 = @truncate(second >> 23);
        if (ae == 255 or be == 255 or (ae == 0 and first & 0x7fffffff != 0) or (be == 0 and second & 0x7fffffff != 0)) return null;
        if (d.operation != .float_multiply and @abs(@as(i16, ae) - @as(i16, be)) > 29 and first & 0x7fffffff != 0 and second & 0x7fffffff != 0) return null;
        exact[i] = switch (d.operation) {
            .float_add => @as(f64, a[i]) + @as(f64, b[i]),
            .float_subtract => @as(f64, a[i]) - @as(f64, b[i]),
            .float_multiply => @as(f64, a[i]) * @as(f64, b[i]),
            else => unreachable,
        };
        if (exact[i] != 0 and (@abs(exact[i]) < 0x1p-126 or @abs(exact[i]) > std.math.floatMax(f32))) return null;
    }
    const av: @Vector(4, f32) = @bitCast(a_bits);
    const bv: @Vector(4, f32) = @bitCast(b_bits);
    const result: [4]f32 = @bitCast(switch (d.operation) {
        .float_add => av + bv,
        .float_subtract => av - bv,
        .float_multiply => av * bv,
        else => unreachable,
    });
    var bits: u128 = 0;
    var inexact = false;
    for (0..d.count) |i| {
        inexact = inexact or @as(f64, result[i]) != exact[i];
        bits = insert(bits, @intCast(i), 4, @as(u32, @bitCast(result[i])));
    }
    if (inexact) cpu.fpsr |= 16;
    return bits;
}

fn arithmetic(comptime T: type, d: Decoded, a_bits: u128, b_bits: u128) u128 {
    const V = @Vector(16 / @sizeOf(T), T);
    const S = @Int(.signed, @bitSizeOf(T));
    const SV = @Vector(16 / @sizeOf(T), S);
    const Shift = @Vector(16 / @sizeOf(T), std.math.Log2Int(T));
    const a: V = @bitCast(a_bits);
    const b: V = @bitCast(b_bits);
    const sa: SV = @bitCast(a);
    const sb: SV = @bitCast(b);
    const zero: V = @splat(0);
    const szero: SV = @splat(0);
    const ones: V = @splat(std.math.maxInt(T));
    const result: V = switch (d.operation) {
        .add => a +% b,
        .subtract => a -% b,
        .multiply => a *% b,
        .negate => zero -% a,
        .minimum_unsigned => @min(a, b),
        .maximum_unsigned => @max(a, b),
        .minimum_signed => @bitCast(@min(sa, sb)),
        .maximum_signed => @bitCast(@max(sa, sb)),
        .equal => @select(T, a == b, ones, zero),
        .test_bits => @select(T, (a & b) != zero, ones, zero),
        .greater_signed => @select(T, sa > sb, ones, zero),
        .greater_equal_signed => @select(T, sa >= sb, ones, zero),
        .greater_unsigned => @select(T, a > b, ones, zero),
        .greater_equal_unsigned => @select(T, a >= b, ones, zero),
        .equal_zero => @select(T, a == zero, ones, zero),
        .greater_zero => @select(T, sa > szero, ones, zero),
        .greater_equal_zero => @select(T, sa >= szero, ones, zero),
        .less_zero => @select(T, sa < szero, ones, zero),
        .less_equal_zero => @select(T, sa <= szero, ones, zero),
        .shift_left => a << @as(Shift, @splat(@intCast(d.shift))),
        .shift_right_unsigned => if (d.shift == @bitSizeOf(T)) zero else a >> @as(Shift, @splat(@intCast(d.shift))),
        .shift_right_signed => @bitCast(sa >> @as(Shift, @splat(@intCast(@min(d.shift, @bitSizeOf(T) - 1))))),
        .sum => return @as(T, @truncate(@reduce(.Add, @as(@Vector(16 / @sizeOf(T), u64), @intCast(a))))),
        else => unreachable,
    };
    return @bitCast(result);
}

fn laneMask(bytes: u8) u64 {
    return if (bytes == 8) std.math.maxInt(u64) else (@as(u64, 1) << @as(u6, @intCast(bytes * 8))) - 1;
}
fn lane(value: u128, index: u5, bytes: u8) u64 {
    return @as(u64, @truncate(value >> @as(u7, @intCast(index * bytes * 8)))) & laneMask(bytes);
}
fn insert(value: u128, index: u5, bytes: u8, raw: u64) u128 {
    const shift: u7 = @intCast(index * bytes * 8);
    const m: u128 = laneMask(bytes);
    return (value & ~(m << shift)) | ((@as(u128, raw) & m) << shift);
}
fn replicate(raw: u64, bytes: u8) u128 {
    return switch (bytes) {
        1 => @bitCast(@as(@Vector(16, u8), @splat(@truncate(raw)))),
        2 => @bitCast(@as(@Vector(8, u16), @splat(@truncate(raw)))),
        4 => @bitCast(@as(@Vector(4, u32), @splat(@truncate(raw)))),
        8 => @bitCast(@as(@Vector(2, u64), @splat(raw))),
        else => unreachable,
    };
}
fn register(cpu: *const Cpu, reg: u5) u64 {
    return if (reg == 31) 0 else cpu.x[reg];
}
fn signedBits(raw: u64, bytes: u8) u64 {
    const shift: u6 = @intCast(64 - @as(u8, bytes) * 8);
    return @bitCast(@as(i64, @bitCast(raw << shift)) >> shift);
}
fn condition(flags: u4, cond: u4) bool {
    const n = flags & 8 != 0;
    const z = flags & 4 != 0;
    const c = flags & 2 != 0;
    const v = flags & 1 != 0;
    const base = switch (@as(u3, @truncate(cond >> 1))) {
        0 => z,
        1 => c,
        2 => n,
        3 => v,
        4 => c and !z,
        5 => n == v,
        6 => n == v and !z,
        7 => true,
    };
    return if (cond & 1 != 0 and cond != 15) !base else base;
}
fn floatImmediate(imm: u8, bits: u8) u64 {
    const fraction: u6 = if (bits == 64) 52 else 23;
    const exponent: u4 = if (bits == 64) 11 else 8;
    const sign: u64 = @as(u64, imm >> 7) << @as(u6, @intCast(bits - 1));
    const b: u64 = (imm >> 6) & 1;
    const e = ((b ^ 1) << @as(u6, @intCast(exponent - 1))) | (((@as(u64, 1) << @as(u6, @intCast(exponent - 3))) - 1) * b << 2) | ((imm >> 4) & 3);
    return sign | (e << fraction) | (@as(u64, imm & 15) << @as(u6, @intCast(fraction - 4)));
}

fn testCpu(seed: u64) Cpu {
    var cpu: Cpu = .{ .pc = std.math.maxInt(u64) - 3, .sp = 0x129ac350ddffee00, .counter = std.math.maxInt(u64), .nzcv = 13, .fpcr = 0x03c09f00, .fpsr = 0x08000091, .exclusive_address = 0xabc0, .exclusive_size = 8, .tpidr_el0 = 77, .tpidrro_el0 = 33 };
    var state = seed;
    for (&cpu.x) |*reg| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        reg.* = state;
    }
    for (&cpu.v) |*reg| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const low = state;
        state = state *% 6364136223846793005 +% 1442695040888963407;
        reg.* = (@as(u128, state) << 64) | low;
    }
    return cpu;
}

fn differential(ins: u32, initial: Cpu) !void {
    const Memory = @import("zyra_host").Memory;
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();
    var reference = initial;
    var actual = initial;
    try std.testing.expect(supports(ins));
    var expected_error: ?anyerror = null;
    _ = reference.stepFetched(&memory, ins) catch |err| blk: {
        expected_error = err;
        break :blk .next;
    };
    var actual_error: ?anyerror = null;
    execute(&actual, ins) catch |err| {
        actual_error = err;
    };
    try std.testing.expectEqual(expected_error, actual_error);
    try std.testing.expectEqualDeep(reference, actual);
}

test "Zyra integer vectors use raw bits and preserve all CPU state across every legal lane width" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    const bases = [_]u32{ 0x0e228420, 0x2e228420, 0x0e229c20, 0x0e226420, 0x0e226c20, 0x2e226420, 0x2e226c20, 0x0e223420, 0x0e223c20, 0x2e223420, 0x2e223c20, 0x0e228c20, 0x2e228c20, 0x2e20b820, 0x2e208820, 0x0e208820, 0x2e209820, 0x0e20a820, 0x0e209820 };
    for (bases) |base| for (0..2) |q| for (0..4) |size| {
        const ins = base | (@as(u32, @intCast(q)) << 30) | (@as(u32, @intCast(size)) << 22);
        if (!supports(ins)) continue;
        for ([_]u32{ ins, (ins & ~@as(u32, 31)) | 1, (ins & ~@as(u32, 31)) | 2, (ins & ~@as(u32, 31)) | 31 }) |aliased| {
            try differential(aliased, testCpu(0x51));
            try differential(aliased, testCpu(0xfedcba981232));
        }
    };
    for ([_]u32{ 0x0e221c20, 0x0e621c20, 0x0ea21c20, 0x0ee21c20, 0x2e221c20, 0x2e621c20, 0x2ea21c20, 0x2ee21c20, 0x0e205820, 0x0e31b820, 0x0e71b820, 0x4eb1b820, 0x7ee0b820 }) |base| {
        try differential(base, testCpu(10));
        if (base & 0x80000000 == 0 and supports(base | 0x40000000)) try differential(base | 0x40000000, testCpu(11));
    }
}

test "Zyra decoded lane moves immediates permutations and shifts match interpreter bits" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    for (0..2) |q| {
        const qbit = @as(u32, @intCast(q)) << 30;
        for (0..256) |imm| for (0..16) |cmode| for (0..2) |op| {
            const ins = 0x0f000400 | qbit | (@as(u32, @intCast(op)) << 29) | (@as(u32, @intCast(cmode)) << 12) | (@as(u32, @intCast(imm >> 5)) << 16) | (@as(u32, @intCast(imm & 31)) << 5);
            if (supports(ins)) try differential(ins, testCpu(imm));
        };
        for (1..32) |imm5| for ([_]u32{ 0x0e000420, 0x0e000c20, 0x0e001c20, 0x0e002c20, 0x0e003c20 }) |base| {
            const ins = base | qbit | (@as(u32, @intCast(imm5)) << 16);
            if (supports(ins)) try differential(ins, testCpu(imm5));
        };
        for ([_]u32{ 0x0e021820, 0x0e025820, 0x0e022820, 0x0e026820, 0x0e023820, 0x0e027820 }) |base| for (0..4) |size| {
            const ins = base | qbit | (@as(u32, @intCast(size)) << 22);
            if (supports(ins)) try differential(ins, testCpu(size));
        };
        for (1..128) |imm| for ([_]u32{ 0x0f005420, 0x0f000420, 0x2f000420 }) |base| {
            const ins = base | qbit | (@as(u32, @intCast(imm)) << 16);
            if (supports(ins)) try differential(ins, testCpu(imm));
        };
        for (0..16) |offset| {
            const ins = 0x2e020020 | qbit | (@as(u32, @intCast(offset)) << 11);
            if (supports(ins)) try differential(ins, testCpu(offset));
        }
    }
    for (1..32) |imm5| for (0..16) |imm4| {
        const ins = 0x6e000420 | (@as(u32, @intCast(imm5)) << 16) | (@as(u32, @intCast(imm4)) << 11);
        if (supports(ins)) try differential(ins, testCpu(imm5 + imm4));
    };
}

test "Zyra FP raw moves preserve NaN payloads under every FPCR mode" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    for ([_]u32{ 0x1e270020, 0x1e260020, 0x9e670020, 0x9e660020, 0x9eaf0020, 0x9eae0020, 0x1e204020, 0x1e604020, 0x1e20c020, 0x1e60c020, 0x1e214020, 0x1e614020, 0x0ea0f820, 0x2ea0f820, 0x4ea0f820, 0x6ea0f820, 0x4ee0f820, 0x6ee0f820, 0x1e2e1000, 0x1e6e1000 }) |ins| {
        for ([_]u128{ 0x7ff0123456789abc7f80012380000000, 0x80000000000000000000000100000000, std.math.maxInt(u128) }) |bits| {
            var cpu = testCpu(91);
            cpu.v[1] = bits;
            try differential(ins, cpu);
        }
    }
    for (0..16) |cond| for (0..16) |flags| {
        var cpu = testCpu(9);
        cpu.nzcv = @intCast(flags);
        try differential(0x1e220c20 | (@as(u32, @intCast(cond)) << 12), cpu);
        try differential(0x1e620c20 | (@as(u32, @intCast(cond)) << 12), cpu);
    };
}

test "Zyra FP arithmetic keeps rounding exceptions traps and inactive lanes exact" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    const singles = [_]u32{ 0, 0x80000000, 1, 0x007fffff, 0x00800000, 0x3f800000, 0xbf800000, 0x3f800001, 0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000, 0x7fc01234, 0x7f801234 };
    const doubles = [_]u64{ 0, 0x8000000000000000, 1, 0x000fffffffffffff, 0x0010000000000000, 0x3ff0000000000000, 0xbff0000000000000, 0x3ff0000000000001, 0x7fefffffffffffff, 0xffefffffffffffff, 0x7ff0000000000000, 0xfff0000000000000, 0x7ff8123456789abc, 0x7ff0123456789abc };
    for ([_]u32{ 0, 0x00400000, 0x00800000, 0x00c00000, 0x01000000, 0x02000000, 0x03c00000, 0x00000100, 0x00001000 }) |control| {
        for ([_]u32{ 0x1e222820, 0x1e223820, 0x1e220820, 0x1e221820, 0x1e21c020, 0x1f020c20, 0x1f028c20, 0x1f220c20, 0x1f228c20, 0x0e22d420, 0x0ea2d420, 0x2e22dc20, 0x2e22fc20, 0x0e22cc20, 0x0ea2cc20, 0x2ea1f820, 0x0e22e420, 0x2e22e420, 0x2ea2e420, 0x5e22e420, 0x7e22e420, 0x7ea2e420 }) |base| {
            for (0..singles.len) |i| {
                var cpu = testCpu(19);
                cpu.fpcr = control;
                cpu.fpsr = 0x08000080;
                cpu.v[1] = replicate(singles[i], 4);
                cpu.v[2] = replicate(singles[(i + 5) % singles.len], 4);
                cpu.v[3] = replicate(singles[(i + 3) % singles.len], 4);
                try differential(base, cpu);
                if (base & 0x10000000 == 0) try differential(base | 0x40000000, cpu);
                var double_cpu = cpu;
                double_cpu.v[1] = replicate(doubles[i], 8);
                double_cpu.v[2] = replicate(doubles[(i + 5) % doubles.len], 8);
                double_cpu.v[3] = replicate(doubles[(i + 3) % doubles.len], 8);
                const double_ins = base | 0x00400000 | (if (base & 0x10000000 == 0) @as(u32, 0x40000000) else 0);
                if (supports(double_ins)) try differential(double_ins, double_cpu);
            }
        }
    }
}

test "Zyra scalar FP compare and conversion match NZCV FPSR widths and fixed point scaling" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    for ([_]u32{ 0, 0x00400000, 0x00800000, 0x00c00000, 0x01000000, 0x02000000, 0x00000100 }) |control| {
        for ([_]u32{ 0x1e222020, 0x1e222030, 0x1e202028, 0x1e202038, 0x1e220020, 0x1e230020, 0x1e380020, 0x1e390020, 0x1e200020, 0x1e210020, 0x1e240020, 0x1e280020, 0x1e300020, 0x1e02fc20, 0x1e18fc20 }) |base| for (0..2) |wide| for (0..2) |double| {
            const ins = base | (if (wide == 1) @as(u32, 0x80000000) else 0) | (if (double == 1) @as(u32, 0x00400000) else 0);
            if (!supports(ins)) continue;
            var cpu = testCpu(91);
            cpu.fpcr = control;
            cpu.v[1] = 0x7ff00000000000007fc01234;
            try differential(ins, cpu);
            cpu.v[1] = 0x3ff00000000000003f800001;
            try differential(ins, cpu);
        };
    }
    for (0..16) |cond| for (0..16) |flags| {
        var cpu = testCpu(91);
        cpu.fpcr = 0;
        cpu.nzcv = @intCast(flags);
        try differential(0x1e220420 | (@as(u32, @intCast(cond)) << 12), cpu);
    };
}

test "Zyra normal f32 SIMD fast arithmetic reports exact inexact status near rounding boundaries" {
    if (comptime !@hasDecl(Cpu, "stepFetched")) return error.SkipZigTest;
    var state: u64 = 0x123456789abcdef0;
    var accepted: usize = 0;
    for (0..2048) |sample| {
        var cpu = testCpu(sample);
        cpu.fpcr = 0;
        cpu.fpsr = 0x08000081;
        cpu.v[1] = 0;
        cpu.v[2] = 0;
        for (0..4) |index| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            const first: u32 = (@as(u32, @truncate(state)) & 0x807fffff) | (@as(u32, @intCast(96 + (state >> 32) % 64)) << 23);
            state = state *% 6364136223846793005 +% 1442695040888963407;
            const second: u32 = (@as(u32, @truncate(state)) & 0x807fffff) | (@as(u32, @intCast(96 + (state >> 32) % 64)) << 23);
            cpu.v[1] = insert(cpu.v[1], @intCast(index), 4, first);
            cpu.v[2] = insert(cpu.v[2], @intCast(index), 4, second);
        }
        for ([_]u32{ 0x1e222820, 0x1e223820, 0x1e220820, 0x0e22d420, 0x0ea2d420, 0x2e22dc20, 0x4e22d420, 0x4ea2d420, 0x6e22dc20 }) |ins| {
            const decoded = decode(ins).?;
            var probe = cpu;
            if (fastFloat32(&probe, decoded, cpu.v[1], cpu.v[2]) != null) accepted += 1 else try std.testing.expectEqualDeep(cpu, probe);
            try differential(ins, cpu);
            try differential((ins & ~@as(u32, 31)) | 1, cpu);
        }
    }
    try std.testing.expect(accepted > 8000);
}

test "Zyra declines unavailable FP16 reserved lane shapes and unrelated instructions" {
    for ([_]u32{ 0, 0xd4000001, 0x91000400, 0x0ee28420, 0x0ee29c20, 0x4ee29c20, 0x0ee26420, 0x0e000420, 0x0e080420, 0x0e081c20, 0x0ee0f820, 0x0ef8f820, 0x1ee04020, 0x9e270020, 0x1e670020, 0x0e62d420 }) |ins| try std.testing.expect(!supports(ins));
}
