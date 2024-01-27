const std = @import("std");
const chunks = @import("chunk.zig");
const values = @import("value.zig");

const OpCode = chunks.OpCode;

pub const debug_print = false;
pub const debug_trace_stack = false;

pub fn disassembleChunk(chunk: *chunks.Chunk, name: [*:0]const u8) void {
    std.debug.print("== {s} ==\n", .{name});

    var offset: usize = 0;

    while (offset < chunk.code.items.len) {
        offset = disassembleInstruction(chunk, offset);
    }
}

pub fn disassembleInstruction(chunk: *chunks.Chunk, offset: usize) usize {
    std.debug.print("{d:0>4} ", .{offset});

    if (offset > 0 and chunk.lines.items[offset] == chunk.lines.items[offset - 1]) {
        std.debug.print("   | ", .{});
    } else {
        std.debug.print("{d:4} ", .{chunk.lines.items[offset]});
    }

    const instruction: OpCode = @enumFromInt(chunk.code.items[offset]);
    switch (instruction) {
        OpCode.Constant => return constantInstruction(
            "OP_CONSTANT",
            chunk,
            offset,
        ),
        OpCode.Constant_16 => return constant16Instruction(
            "OP_CONSTANT_16",
            chunk,
            offset,
        ),
        OpCode.Null => return simpleInstruction("OP_NULL", offset),
        OpCode.True => return simpleInstruction("OP_TRUE", offset),
        OpCode.False => return simpleInstruction("OP_FALSE", offset),
        OpCode.GetLocal => return byteInstruction("OP_GET_LOCAL", chunk, offset),
        OpCode.GetLocal_16 => return byteInstruction_16("OP_GET_LOCAL_16", chunk, offset),
        OpCode.SetLocal => return byteInstruction("OP_SET_LOCAL", chunk, offset),
        OpCode.SetLocal_16 => return byteInstruction_16("OP_SET_LOCAL_16", chunk, offset),
        OpCode.GetGlobal => return constantInstruction(
            "OP_GET_GLOBAL",
            chunk,
            offset,
        ),
        OpCode.GetGlobal_16 => return constant16Instruction(
            "OP_GET_GLOBAL_16",
            chunk,
            offset,
        ),
        OpCode.DefineGlobal => return constantInstruction(
            "OP_DEFINE_GLOBAL",
            chunk,
            offset,
        ),
        OpCode.DefineGlobal_16 => return constant16Instruction(
            "OP_DEFINE_GLOBAL_16",
            chunk,
            offset,
        ),
        OpCode.SetGlobal => return constantInstruction(
            "OP_SET_GLOBAL_16",
            chunk,
            offset,
        ),
        OpCode.SetGlobal_16 => return constant16Instruction(
            "OP_SET_GLOBAL_16",
            chunk,
            offset,
        ),
        OpCode.Equal => return simpleInstruction("OP_EQUAL", offset),
        OpCode.Pop => return simpleInstruction("OP_POP", offset),
        OpCode.Greater => return simpleInstruction("OP_GREATER", offset),
        OpCode.Less => return simpleInstruction("OP_LESS", offset),
        OpCode.Add => return simpleInstruction("OP_ADD", offset),
        OpCode.Subtract => return simpleInstruction("OP_SUBTRACT", offset),
        OpCode.Multiply => return simpleInstruction("OP_MULTIPLY", offset),
        OpCode.Divide => return simpleInstruction("OP_DIVIDE", offset),
        OpCode.Not => return simpleInstruction("OP_NOT", offset),
        OpCode.Negate => return simpleInstruction("OP_NEGATE", offset),
        OpCode.Print => return simpleInstruction("OP_PRINT", offset),
        OpCode.Jump => return jumpInstruction("OP_JUMP", 1, chunk, offset),
        OpCode.JumpIfFalse => return jumpInstruction("OP_JUMP_IF_FALSE", 1, chunk, offset),
        OpCode.Loop => return jumpInstruction("OP_LOOP", -1, chunk, offset),
        OpCode.Call => return byteInstruction("OP_CALL", chunk, offset),
        OpCode.Closure => {
            const constant = chunk.code.items[offset + 1];
            std.debug.print("{s} {d:0>4}", .{ "OP_CLOSURE", constant });
            values.printValue(chunk.constants.values.items[constant]);
            std.debug.print("\n", .{});
            return offset + 2;
        },
        OpCode.Return => return simpleInstruction("OP_RETURN", offset),
    }
}

fn constantInstruction(name: [*:0]const u8, chunk: *chunks.Chunk, offset: usize) usize {
    var constant: usize = undefined;
    var new_offset = offset + 1;

    constant = chunk.code.items[offset + 1];
    new_offset += 1;

    std.debug.print("{s} {d:4} '", .{ name, constant });
    values.printValue(chunk.constants.values.items[constant]);
    std.debug.print("'\n", .{});
    return new_offset;
}

fn constant16Instruction(name: [*:0]const u8, chunk: *chunks.Chunk, offset: usize) usize {
    var constant: usize = undefined;
    var new_offset = offset + 1;

    const big_end: u16 = chunk.code.items[offset + 1];
    const little_end: u16 = chunk.code.items[offset + 2];
    constant = (big_end * 256) + little_end;
    new_offset += 2;

    std.debug.print("{s} {d:4} '", .{ name, constant });
    values.printValue(chunk.constants.values.items[constant]);
    std.debug.print("'\n", .{});
    return new_offset;
}

fn simpleInstruction(name: [*:0]const u8, offset: usize) usize {
    std.debug.print("{s}\n", .{name[0..]});
    return offset + 1;
}

fn byteInstruction(name: [*:0]const u8, chunk: *chunks.Chunk, offset: usize) usize {
    const slot: usize = chunk.code.items[offset + 1];
    std.debug.print("{s} {d:4}\n", .{ name, slot });
    return offset + 2;
}

fn byteInstruction_16(name: [*:0]const u8, chunk: *chunks.Chunk, offset: usize) usize {
    const slot: usize = @as(usize, @intCast(chunk.code.items[offset + 1])) * 256 + chunk.code.items[offset + 2];
    std.debug.print("{s} {d:4}", .{ name, slot });
    return offset + 3;
}

fn jumpInstruction(name: [*:0]const u8, sign: i32, chunk: *chunks.Chunk, offset: usize) usize {
    const jump: usize = @as(usize, @intCast(chunk.code.items[offset + 1])) * 256 + chunk.code.items[offset + 2];
    std.debug.print("{s} {d} -> {d}", .{ name, offset, @as(i32, @intCast((offset + 3))) + sign * @as(i32, @intCast(jump)) });
    return offset + 3;
}
