const std = @import("std");

const stderr = std.io.getStdErr().writer();

const scanner = @import("scanner.zig");
const chunks = @import("chunk.zig");
const values = @import("value.zig");
const debug = @import("debug.zig");
const object = @import("object.zig");

//types
const Chunk = chunks.Chunk;
const OpCode = chunks.OpCode;
const Token = scanner.Token;
const TokenType = scanner.TokenType;
const Value = @import("value.zig").Value;

var current: *Compiler = undefined;

const Parser = struct {
    current: Token = undefined,
    previous: Token = undefined,
    hadError: bool = false,
    panicMode: bool = false,
};

const Precedence = enum {
    none,
    assignment,
    or_,
    and_,
    equality,
    comparison,
    term,
    factor,
    unary,
    call,
    primary,
};

const ParseFn = *const fn (can_assign: bool) anyerror!void;

const ParseRule = struct {
    prefix: ?ParseFn = null,
    infix: ?ParseFn = null,
    precedence: Precedence = Precedence.none,
};

const Compiler = struct {
    locals: [65536]Local,
    local_count: i32,
    scope_depth: i32,
};

const Local = struct {
    name: Token,
    depth: i32,
};

var parser: Parser = Parser{};
var compilingChunk: *Chunk = undefined;

fn currentChunk() *Chunk {
    return compilingChunk;
}

pub fn compile(source: []const u8, chunk: *Chunk) !bool {
    scanner.initScanner(source);
    var compiler: Compiler = undefined;
    initCompiler(&compiler);
    compilingChunk = chunk;

    parser.hadError = false;
    parser.panicMode = false;

    try advance();
    while (!match(TokenType.eof)) {
        declaration();
    }
    try endCompiler();
    return !parser.hadError;
}

fn advance() !void {
    parser.previous = parser.current;

    while (true) {
        parser.current = scanner.scanToken();
        if (parser.current.type != TokenType.error_) break;

        try errorAtCurrent(parser.current.start[0..parser.current.length :0].ptr);
    }
}

fn consume(token_type: TokenType, message: [*:0]const u8) !void {
    if (parser.current.type == token_type) {
        try advance();
        return;
    }

    try errorAtCurrent(message);
}

fn check(token_type: TokenType) bool {
    return parser.current.type == token_type;
}

fn match(token_type: TokenType) bool {
    if (!check(token_type)) return false;
    advance() catch {};
    return true;
}

fn emitByte(byte: u8) void {
    chunks.writeChunk(currentChunk(), byte, parser.previous.line) catch {};
}

fn emitBytes(byte_1: u8, byte_2: u8) void {
    emitByte(byte_1);
    emitByte(byte_2);
}

fn emitReturn() !void {
    emitByte(@intFromEnum(OpCode.Return));
}

fn emitJump(instruction: OpCode) usize {
    emitByte(@intFromEnum(instruction));
    emitByte(0xff);
    emitByte(0xff);
    return currentChunk().code.items.len - 2;
}

fn emitLoop(loop_start: usize) void {
    emitByte(@intFromEnum(OpCode.Loop));

    const offset = currentChunk().code.items.len - loop_start + 2;
    if (offset > 0xffff) error_("Loop body too large.") catch {};

    emitByte(@intCast(@divFloor(offset, 256)));
    emitByte(@intCast(@mod(offset, 256)));
}

fn makeConstant(value: values.Value) !u16 {
    const constant = try chunks.addConstant(currentChunk(), value);
    if (constant > 65535) {
        try error_("Too many constants in one chunk.");
        return 0;
    }

    return @intCast(@mod(constant, 65536));
}

fn emitConstant(value: values.Value) !void {
    const constant = try makeConstant(value);
    if (constant <= 255) {
        emitBytes(@intFromEnum(OpCode.Constant), @as(u8, @intCast(@mod(constant, 256))));
    } else {
        emitByte(@intFromEnum(OpCode.Constant_16));
        const byte_1: u8 = @intCast(@mod(@divFloor(constant, 256), 256));
        const byte_2: u8 = @intCast(@mod(constant, 256));
        emitBytes(byte_1, byte_2);
    }
}

fn patchJump(offset: usize) void {
    const jump = currentChunk().code.items.len - offset - 2;
    if (jump > 0xffff) {
        error_("Too much code to jump over.") catch {};
    }

    currentChunk().code.items[offset] = @intCast(@divFloor(jump, 256));
    currentChunk().code.items[offset + 1] = @intCast(@mod(jump, 256));
}

fn initCompiler(compiler: *Compiler) void {
    compiler.local_count = 0;
    compiler.scope_depth = 0;
    current = compiler;
}

fn endCompiler() !void {
    try emitReturn();
    if (debug.debug_print) {
        if (!parser.hadError) {
            debug.disassembleChunk(currentChunk(), "code");
        }
    }
}

fn beginScope() void {
    current.scope_depth += 1;
}

fn endScope() void {
    current.scope_depth -= 1;

    while (current.local_count > 0 and current.locals[@intCast(current.local_count - 1)].depth > current.scope_depth) {
        emitByte(@intFromEnum(OpCode.Pop));
        current.local_count -= 1;
    }
}

fn unary(can_assign: bool) !void {
    _ = can_assign;
    const operatorType = parser.previous.type;

    //compile the operand.
    try parsePrecedence(Precedence.unary);

    //Emit the operator instruction.
    switch (operatorType) {
        TokenType.bang => emitByte(@intFromEnum(OpCode.Not)),
        TokenType.minus => emitByte(@intFromEnum(OpCode.Negate)),
        else => return,
    }
}

fn binary(can_assign: bool) !void {
    _ = can_assign;
    const operatorType = parser.previous.type;
    const rule = getRule(operatorType);
    try parsePrecedence(@enumFromInt(@intFromEnum(rule.precedence) + 1));

    switch (operatorType) {
        TokenType.bang_equal => emitBytes(@intFromEnum(OpCode.Equal), @intFromEnum(OpCode.Not)),
        TokenType.equal_equal => emitByte(@intFromEnum(OpCode.Equal)),
        TokenType.greater => emitByte(@intFromEnum(OpCode.Greater)),
        TokenType.greater_equal => emitBytes(@intFromEnum(OpCode.Less), @intFromEnum(OpCode.Not)),
        TokenType.less => emitByte(@intFromEnum(OpCode.Less)),
        TokenType.less_equal => emitBytes(@intFromEnum(OpCode.Greater), @intFromEnum(OpCode.Not)),
        TokenType.plus => emitByte(@intFromEnum(OpCode.Add)),
        TokenType.minus => emitByte(@intFromEnum(OpCode.Subtract)),
        TokenType.star => emitByte(@intFromEnum(OpCode.Multiply)),
        TokenType.slash => emitByte(@intFromEnum(OpCode.Divide)),
        else => return,
    }
}

fn literal(can_assign: bool) !void {
    _ = can_assign;
    switch (parser.previous.type) {
        TokenType.false_keyword => emitByte(@intFromEnum(OpCode.False)),
        TokenType.null_keyword => emitByte(@intFromEnum(OpCode.Null)),
        TokenType.true_keyword => emitByte(@intFromEnum(OpCode.True)),
        else => return,
    }
}

fn grouping(can_assign: bool) !void {
    _ = can_assign;
    try expression();
    try consume(TokenType.right_paren, "Expect ')' after expression.");
}

fn number(can_assign: bool) !void {
    _ = can_assign;
    const value: f64 = try std.fmt.parseFloat(f64, parser.previous.start[0..parser.previous.length]);
    try emitConstant(Value.makeNumber(value));
}

fn string(can_assign: bool) !void {
    _ = can_assign;
    const obj_string = try object.copyString(parser.previous.start + 1, parser.previous.length - 2);
    const obj: *object.Obj = @ptrCast(obj_string);
    emitConstant(Value.makeObj(obj)) catch {};
}

fn variable(can_assign: bool) !void {
    try namedVariable(parser.previous, can_assign);
}

fn namedVariable(name: Token, can_assign: bool) !void {
    var arg: i32 = resolveLocal(current, &name);
    var get_op: OpCode = undefined;
    var set_op: OpCode = undefined;

    if (arg != -1) {
        if (arg < 256) {
            get_op = OpCode.GetLocal;
            set_op = OpCode.SetLocal;
        } else {
            get_op = OpCode.GetLocal_16;
            set_op = OpCode.SetLocal_16;
        }
    } else {
        arg = try identifierConstant(&name);
        if (arg < 256) {
            get_op = OpCode.GetGlobal;
            set_op = OpCode.SetGlobal;
        } else {
            get_op = OpCode.GetGlobal_16;
            set_op = OpCode.SetGlobal_16;
        }
    }

    if (can_assign and match(TokenType.equal)) {
        try expression();
        if (arg < 256) {
            const index: u8 = @intCast(@mod(arg, 256));
            emitBytes(@intFromEnum(set_op), index);
        } else {
            emitByte(@intFromEnum(set_op));
            const byte_1: u8 = @intCast(@mod(@divFloor(arg, 256), 256));
            const byte_2: u8 = @intCast(@mod(arg, 256));
            emitBytes(byte_1, byte_2);
        }
    } else {
        if (arg < 256) {
            const index: u8 = @intCast(@mod(arg, 256));
            emitBytes(@intFromEnum(get_op), index);
        } else {
            emitByte(@intFromEnum(get_op));
            const byte_1: u8 = @intCast(@mod(@divFloor(arg, 256), 256));
            const byte_2: u8 = @intCast(@mod(arg, 256));
            emitBytes(byte_1, byte_2);
        }
    }
}

fn parsePrecedence(precedence: Precedence) !void {
    const can_assign = @intFromEnum(precedence) <= @intFromEnum(Precedence.assignment);
    try advance();
    const prefixRule_option = getRule(parser.previous.type).prefix;
    if (prefixRule_option) |prefixRule| {
        try prefixRule(can_assign);
    } else {
        try error_("Expect expression.");
        return;
    }

    while (@intFromEnum(precedence) <= @intFromEnum(getRule(parser.current.type).precedence)) {
        try advance();
        const infixRule_option = getRule(parser.previous.type).infix;
        if (infixRule_option) |infixRule| {
            try infixRule(can_assign);
        }
    }

    if (can_assign and match(TokenType.equal)) {
        error_("Invalid assignment target.") catch {};
    }
}

fn identifierConstant(name: *const Token) !u16 {
    const obj_str: *object.ObjString = try object.copyString(name.start, name.length);
    const obj: *object.Obj = @ptrCast(obj_str);
    const index = try makeConstant(Value.makeObj(obj));
    return @intCast(@mod(index, 256));
}

fn identifiersEqual(a: *const Token, b: *const Token) bool {
    if (a.length != b.length) return false;
    return std.mem.eql(u8, a.start[0..a.length], b.start[0..a.length]);
}

fn resolveLocal(compiler: *Compiler, name: *const Token) i32 {
    var i: i32 = @as(i32, @mod(compiler.local_count, 65536)) - 1;
    while (i >= 0) : (i -= 1) {
        const local = &compiler.locals[@intCast(i)];
        if (identifiersEqual(name, &local.name)) {
            if (local.depth == -1) {
                error_("Can't read local variable in its own initializer.") catch {};
            }
            return @intCast(@mod(i, 65536));
        }
    }
    return -1;
}

fn addLocal(name: Token) void {
    if (current.local_count == 256) {
        error_("Too many local variables in scope.") catch {};
        return;
    }

    var local: *Local = &current.locals[@intCast(current.local_count)];
    current.local_count += 1;
    local.name = name;
    local.depth = -1;
}

fn declareVariable() void {
    if (current.scope_depth == 0) return;

    const name: *Token = &parser.previous;

    var i = current.local_count - 1;
    while (i >= 0) : (i -= 1) {
        const local = &current.locals[@intCast(i)];
        if (local.depth != -1 and local.depth < current.scope_depth) {
            break;
        }
        if (identifiersEqual(name, &local.name)) {
            error_("Already a variable with this name in this scope.") catch {};
        }
    }

    addLocal(name.*);
}

fn parseVariable(message: [*:0]const u8) !u16 {
    consume(TokenType.identifier, message) catch {};

    declareVariable();
    if (current.scope_depth > 0) return 0;

    return try identifierConstant(&parser.previous);
}

fn markInitialized() void {
    current.locals[@intCast(current.local_count - 1)].depth = current.scope_depth;
}

fn defineVariable(global: u16) void {
    if (current.scope_depth > 0) {
        markInitialized();
        return;
    }

    if (global < 256) {
        const byte: u8 = @intCast(@mod(global, 256));
        emitBytes(@intFromEnum(OpCode.DefineGlobal), byte);
    } else {
        const byte_1: u8 = @intCast(@mod(@divFloor(global, 256), 256));
        const byte_2: u8 = @intCast(@mod(global, 256));
        emitByte(@intFromEnum(OpCode.DefineGlobal_16));
        emitBytes(byte_1, byte_2);
    }
}

fn and_(can_assign: bool) !void {
    _ = can_assign;
    const end_jump = emitJump(OpCode.JumpIfFalse);

    emitByte(@intFromEnum(OpCode.Pop));
    parsePrecedence(Precedence.and_) catch {};

    patchJump(end_jump);
}

fn or_(can_assign: bool) !void {
    _ = can_assign;
    const else_jump = emitJump(OpCode.JumpIfFalse);
    const end_jump = emitJump(OpCode.Jump);

    patchJump(else_jump);
    emitByte(@intFromEnum(OpCode.Pop));

    parsePrecedence(Precedence.or_) catch {};
    patchJump(end_jump);
}

fn expression() !void {
    try parsePrecedence(Precedence.assignment);
}

fn block() void {
    while (!check(TokenType.right_brace) and !check(TokenType.eof)) {
        declaration();
    }

    consume(TokenType.right_brace, "Expect '}' after block.") catch {};
}

fn varDeclaration() !void {
    const global = try parseVariable("Expect variable name.");

    if (match(TokenType.equal)) {
        expression() catch {};
    } else {
        emitByte(@intFromEnum(OpCode.Null));
    }
    consume(TokenType.semicolon, "Expect ';' after variable declaration.") catch {};

    defineVariable(global);
}

fn expressionStatement() void {
    expression() catch {};
    consume(TokenType.semicolon, "Expect ';' after expression.") catch {};
    emitByte(@intFromEnum(OpCode.Pop));
}

fn ifStatement() void {
    consume(TokenType.left_paren, "Expect '(' after 'if'.") catch {};
    expression() catch {};
    consume(TokenType.right_paren, "Expect ')' after condition.") catch {};

    const then_jump = emitJump(OpCode.JumpIfFalse);
    emitByte(@intFromEnum(OpCode.Pop));
    statement();

    const else_jump = emitJump(OpCode.Jump);

    patchJump(then_jump);
    emitByte(@intFromEnum(OpCode.Pop));

    if (match(TokenType.else_keyword)) {
        statement();
    }
    patchJump(else_jump);
}

fn whileStatement() void {
    const loop_start = currentChunk().code.items.len;
    consume(TokenType.left_paren, "Expect '(' after 'while'.") catch {};
    expression() catch {};
    consume(TokenType.right_paren, "Expect ')' after condition.") catch {};

    const exit_jump = emitJump(OpCode.JumpIfFalse);
    emitByte(@intFromEnum(OpCode.Pop));
    statement();
    emitLoop(loop_start);

    patchJump(exit_jump);

    emitByte(@intFromEnum(OpCode.Pop));
}

fn forStatement() void {
    beginScope();
    consume(TokenType.left_paren, "Expect '(' after 'for'.") catch {};
    if (match(TokenType.semicolon)) {} else if (match(TokenType.var_keyword)) {
        varDeclaration() catch {};
    } else {
        expressionStatement();
    }

    var loop_start = currentChunk().code.items.len;
    var exit_jump: i32 = -1;
    if (!match(TokenType.semicolon)) {
        expression() catch {};
        consume(TokenType.semicolon, "Expect ';' after loop condition.") catch {};

        //Jump out of loop if condition is false.
        exit_jump = @intCast(emitJump(OpCode.JumpIfFalse));

        emitByte(@intFromEnum(OpCode.Pop));
    }
    if (!match(TokenType.right_paren)) {
        const body_jump = emitJump(OpCode.Jump);
        const increment_start = currentChunk().code.items.len;
        expression() catch {};
        emitByte(@intFromEnum(OpCode.Pop));
        consume(TokenType.right_paren, "Expect ')' after for clauses.") catch {};

        emitLoop(loop_start);

        loop_start = increment_start;
        patchJump(body_jump);
    }

    statement();
    emitLoop(loop_start);

    if (exit_jump != -1) {
        patchJump(@intCast(exit_jump));
        emitByte(@intFromEnum(OpCode.Pop));
    }
    endScope();
}

fn printStatement() void {
    expression() catch {};
    consume(TokenType.semicolon, "Expect ';' after value.") catch {};
    emitByte(@intFromEnum(OpCode.Print));
}

fn synchronize() void {
    parser.panicMode = false;

    while (parser.current.type != TokenType.eof) {
        if (parser.previous.type == TokenType.semicolon) return;
        switch (parser.current.type) {
            TokenType.class_keyword,
            TokenType.fn_keyword,
            TokenType.var_keyword,
            TokenType.for_keyword,
            TokenType.if_keyword,
            TokenType.while_keyword,
            TokenType.print_keyword,
            TokenType.return_keyword,
            => return,
            else => {},
        }

        advance() catch {};
    }
}

fn statement() void {
    if (match(TokenType.print_keyword)) {
        printStatement();
    } else if (match(TokenType.for_keyword)) {
        forStatement();
    } else if (match(TokenType.if_keyword)) {
        ifStatement();
    } else if (match(TokenType.while_keyword)) {
        whileStatement();
    } else if (match(TokenType.left_brace)) {
        beginScope();
        block();
        endScope();
    } else {
        expressionStatement();
    }
}

fn declaration() void {
    if (match(TokenType.var_keyword)) {
        varDeclaration() catch {};
    } else {
        statement();
    }

    if (parser.panicMode) synchronize();
}

fn errorAtCurrent(message: [*:0]const u8) !void {
    try errorAt(&parser.current, message);
}

fn error_(message: [*:0]const u8) !void {
    try errorAt(&parser.previous, message);
}

fn errorAt(token: *Token, message: [*:0]const u8) !void {
    if (parser.panicMode) return;
    parser.panicMode = true;
    try stderr.print("[line {d}] Error", .{token.line});

    if (token.type == TokenType.eof) {
        try stderr.print(" at end", .{});
    } else if (token.type == TokenType.error_) {} else {
        try stderr.print(" at '{s}'", .{token.start[0..token.length]});
    }

    try stderr.print(": {s}\n", .{message[0..]});
    parser.hadError = true;
}

fn getRule(token_type: TokenType) ParseRule {
    switch (token_type) {
        TokenType.left_paren => return ParseRule{ .prefix = grouping },
        TokenType.minus => return ParseRule{ .prefix = unary, .infix = binary, .precedence = Precedence.term },
        TokenType.plus => return ParseRule{ .infix = binary, .precedence = Precedence.term },
        TokenType.slash => return ParseRule{ .infix = binary, .precedence = Precedence.factor },
        TokenType.star => return ParseRule{ .infix = binary, .precedence = Precedence.factor },
        TokenType.bang => return ParseRule{ .prefix = unary },
        TokenType.bang_equal => return ParseRule{ .infix = binary, .precedence = Precedence.equality },
        TokenType.equal_equal => return ParseRule{ .infix = binary, .precedence = Precedence.equality },
        TokenType.greater => return ParseRule{ .infix = binary, .precedence = Precedence.comparison },
        TokenType.greater_equal => return ParseRule{ .infix = binary, .precedence = Precedence.comparison },
        TokenType.less => return ParseRule{ .infix = binary, .precedence = Precedence.comparison },
        TokenType.less_equal => return ParseRule{ .infix = binary, .precedence = Precedence.comparison },
        TokenType.identifier => return ParseRule{ .prefix = variable },
        TokenType.string => return ParseRule{ .prefix = string },
        TokenType.number => return ParseRule{ .prefix = number },
        TokenType.and_keyword => return ParseRule{ .infix = and_, .precedence = Precedence.and_ },
        TokenType.false_keyword => return ParseRule{ .prefix = literal },
        TokenType.null_keyword => return ParseRule{ .prefix = literal },
        TokenType.or_keyword => return ParseRule{ .infix = or_, .precedence = Precedence.or_ },
        TokenType.true_keyword => return ParseRule{ .prefix = literal },
        else => return ParseRule{},
    }
}
