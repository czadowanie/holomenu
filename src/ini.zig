const std = @import("std");

const hui = @import("hui.zig");

const TokenType = enum {
    OpenBracket,
    CloseBracket,
    EqualSign,
    DolarSign,
    Ident,
    StringLiteral,
    ColorLiteral,
    IntLiteral,
};

const Token = struct {
    tt: TokenType,
    span: []const u8,
    line: usize,
    line_pos: usize,

    pub fn format(
        self: Token,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.writeAll("Tok(");
        try writer.print("{}, {}:{}, {s}", .{ self.tt, self.line, self.line_pos, self.span });
        try writer.writeAll(")");
    }
};

pub const ValueType = enum {
    int,
    boolean,
    str,
    color,
};

pub const Value = union(ValueType) {
    int: i32,
    boolean: bool,
    str: []const u8,
    color: hui.Color,

    pub fn format(
        self: Value,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.writeAll("Value(");

        switch (self) {
            .int => |int| try writer.print("{d}", .{int}),
            .boolean => |boolean| try writer.print("{}", .{boolean}),
            .str => |str| try writer.print("\"{s}\"", .{str}),
            .color => |color| try writer.print("{}", .{color}),
        }

        try writer.writeAll(")");
    }

    pub fn asInt(self: @This()) ?i32 {
        return switch (self) {
            .int => |value| value,
            else => null,
        };
    }

    pub fn asBool(self: @This()) ?bool {
        return switch (self) {
            .boolean => |value| value,
            else => null,
        };
    }

    pub fn asStr(self: @This()) ?[]const u8 {
        return switch (self) {
            .str => |value| value,
            else => null,
        };
    }

    pub fn asColor(self: @This()) ?hui.Color {
        return switch (self) {
            .color => |value| value,
            else => null,
        };
    }
};

fn parseHeader(token: []const u8) ParserError!?[]const u8 {
    if (token.len > 0 and token[0] == '[') {
        if (token.len == 2 and token[1] == ']') {
            return ParserError.EmptySectionHeader;
        } else if (token[token.len - 1] != ']') {
            return ParserError.ExpectedClosingSquareBracket;
        } else return token[1 .. token.len - 1];
    } else return null;
}

fn parseColor(rgba: []const u8) ParserError!hui.Color {
    switch (rgba.len) {
        8 => {
            const r: u8 = try std.fmt.parseInt(u8, rgba[0..2], 16);
            const g: u8 = try std.fmt.parseInt(u8, rgba[2..4], 16);
            const b: u8 = try std.fmt.parseInt(u8, rgba[4..6], 16);
            const a: u8 = try std.fmt.parseInt(u8, rgba[6..8], 16);
            return hui.color(r, g, b, a);
        },
        4 => {
            const r_component: u8 = try std.fmt.parseInt(u8, rgba[0..1], 16);
            const r = r_component + (r_component * 16);

            const g_component: u8 = try std.fmt.parseInt(u8, rgba[1..2], 16);
            const g = g_component + (g_component * 16);

            const b_component: u8 = try std.fmt.parseInt(u8, rgba[2..3], 16);
            const b = b_component + (b_component * 16);

            const a_component: u8 = try std.fmt.parseInt(u8, rgba[3..4], 16);
            const a = a_component + (a_component * 16);

            return hui.color(r, g, b, a);
        },
        6 => {
            const r: u8 = try std.fmt.parseInt(u8, rgba[0..2], 16);
            const g: u8 = try std.fmt.parseInt(u8, rgba[2..4], 16);
            const b: u8 = try std.fmt.parseInt(u8, rgba[4..6], 16);
            return hui.color(r, g, b, 255);
        },
        3 => {
            const r_component: u8 = try std.fmt.parseInt(u8, rgba[0..1], 16);
            const r = r_component + (r_component * 16);

            const g_component: u8 = try std.fmt.parseInt(u8, rgba[1..2], 16);
            const g = g_component + (g_component * 16);

            const b_component: u8 = try std.fmt.parseInt(u8, rgba[2..3], 16);
            const b = b_component + (b_component * 16);

            return hui.color(r, g, b, 255);
        },
        else => return ParserError.UnsupportedRGBAFormat,
    }
}

fn parseValue(token: []const u8) ParserError!Value {
    if (token[0] == '"') {
        if (token[token.len - 1] != '"') {
            return ParserError.UnclosedString;
        } else {
            return Value{ .str = token[1 .. token.len - 1] };
        }
    } else if (std.mem.eql(u8, token, "true")) {
        return Value{ .boolean = true };
    } else if (std.mem.eql(u8, token, "false")) {
        return Value{ .boolean = false };
    } else if (token[0] == '#') {
        return Value{ .color = try parseColor(token[1..]) };
    } else {
        const int = try std.fmt.parseInt(i32, token, 10);
        return Value{ .int = int };
    }
}

const Line = struct {
    key: []const u8,
    value: Value,
};

fn parseLine(tokens: [3][]const u8) ParserError!Line {
    if (tokens[1].len != 1 or tokens[1][0] != '=') {
        return ParserError.ExpectedEqualSign;
    }

    return Line{
        .key = tokens[0],
        .value = try parseValue(tokens[2]),
    };
}

const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: usize,
    line_pos: usize,

    pub fn init(source: []const u8) @This() {
        return @This(){
            .source = source,
            .pos = 0,
            .line = 0,
            .line_pos = 0,
        };
    }

    fn nextLine(self: *@This()) void {
        self.line_pos = 0;
        self.line += 1;
    }

    pub fn next(self: *@This()) ?Token {
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                ';' => {
                    if (std.mem.indexOfScalar(u8, self.source[self.pos..], '\n')) |offset| {
                        self.pos += offset + 1;
                        self.nextLine();
                    } else {
                        return null;
                    }
                },
                ' ', '\t' => {
                    self.line_pos += 1;
                    self.pos += 1;
                },
                '\n' => {
                    self.nextLine();
                    self.pos += 1;
                },
                '[' => {
                    const token = Token{
                        .tt = TokenType.OpenBracket,
                        .span = self.source[self.pos .. self.pos + 1],
                        .line = self.line,
                        .line_pos = self.line_pos,
                    };

                    self.line_pos += 1;
                    self.pos += 1;

                    return token;
                },
                ']' => {
                    const token = Token{
                        .tt = TokenType.CloseBracket,
                        .span = self.source[self.pos .. self.pos + 1],
                        .line = self.line,
                        .line_pos = self.line_pos,
                    };

                    self.line_pos += 1;
                    self.pos += 1;

                    return token;
                },
                '"' => {
                    const start = self.pos;
                    self.pos += 1;

                    while (true) : (self.pos += 1) {
                        if (self.pos >= self.source.len) {
                            return null;
                        }

                        if (self.source[self.pos] == '"' and self.source[self.pos - 1] != '\\') {
                            self.pos += 1;

                            const token =
                                Token{
                                .tt = TokenType.StringLiteral,
                                .span = self.source[start..self.pos],
                                .line = self.line,
                                .line_pos = self.line_pos,
                            };

                            self.line_pos += self.pos - start;

                            return token;
                        }
                    }
                },
                '=' => {
                    const token = Token{
                        .tt = TokenType.EqualSign,
                        .span = self.source[self.pos .. self.pos + 1],
                        .line = self.line,
                        .line_pos = self.line_pos,
                    };

                    self.pos += 1;
                    self.line_pos += 1;

                    return token;
                },
                '#' => {
                    const start = self.pos;
                    const end = while (self.pos < self.source.len) {
                        switch (self.source[self.pos]) {
                            '\t', '\n', ' ' => break self.pos,
                            else => {
                                self.pos += 1;
                            },
                        }
                    } else {
                        break self.source.len;
                    };

                    const token = Token{
                        .tt = TokenType.ColorLiteral,
                        .span = self.source[start..end],
                        .line = self.line,
                        .line_pos = self.line_pos,
                    };

                    self.line_pos += end - start;

                    return token;
                },
                '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                    const start = self.pos;
                    const end = while (self.pos < self.source.len) {
                        switch (self.source[self.pos]) {
                            '\t', '\n', ' ' => break self.pos,
                            else => {
                                self.pos += 1;
                            },
                        }
                    } else {
                        break self.source.len;
                    };

                    const token = Token{
                        .tt = TokenType.IntLiteral,
                        .span = self.source[start..end],
                        .line = self.line,
                        .line_pos = self.line_pos,
                    };

                    self.line_pos += end - start;

                    return token;
                },
                else => {
                    const start = self.pos;
                    const end = while (self.pos < self.source.len) {
                        switch (self.source[self.pos]) {
                            '\t', '\n', ' ', '=', ']' => break self.pos,
                            else => {
                                self.pos += 1;
                            },
                        }
                    } else {
                        break self.source.len;
                    };

                    const token = Token{
                        .tt = TokenType.Ident,
                        .span = self.source[start..end],
                        .line = self.line,
                        .line_pos = self.line_pos,
                    };

                    self.line_pos += end - start;

                    return token;
                },
            }
        }

        return null;
    }
};

pub const ParserError = error{
    NoSectionDefined,
    ExpectedToken,
    FailedToParseLine,
    ExpectedEqualSign,
    ExpectedIdent,
    ExpectedClosingSquareBracket,
    EmptySectionHeader,
    UnclosedString,
    UnsupportedRGBAFormat,
    InvalidCharacter,
    UnexpectedToken,
    ConstantNotDefined,
    Overflow,
    OutOfMemory,
};

pub const Ini = struct {
    map: std.StringHashMap(std.StringHashMap(Value)),

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParserError!Ini {
        var sections = std.StringHashMap(std.StringHashMap(Value)).init(allocator);
        var constants = std.StringHashMap(Value).init(allocator);

        var tokens = Lexer.init(source);
        var current_section: ?[]const u8 = null;

        while (tokens.next()) |token| {
            switch (token.tt) {
                .OpenBracket => {
                    const name_token = tokens.next() orelse return ParserError.ExpectedToken;
                    if (name_token.tt != TokenType.Ident) return ParserError.ExpectedIdent;
                    const closing_token = tokens.next() orelse return ParserError.ExpectedToken;
                    if (closing_token.tt != TokenType.CloseBracket) return ParserError.ExpectedClosingSquareBracket;

                    current_section = name_token.span;
                },
                .Ident => {
                    const key = token.span;
                    const eql_token = tokens.next() orelse return ParserError.ExpectedToken;
                    if (eql_token.tt != TokenType.EqualSign) return ParserError.ExpectedEqualSign;

                    const value_token = tokens.next() orelse return ParserError.ExpectedToken;

                    if (current_section == null) {
                        try constants.put(key, try parseValue(value_token.span));
                    } else {
                        const is_bool = std.mem.eql(u8, value_token.span, "true") or
                            std.mem.eql(u8, value_token.span, "false");

                        const value = if (value_token.tt == TokenType.Ident and !is_bool) blk: {
                            break :blk constants.get(value_token.span) orelse
                                return ParserError.ConstantNotDefined;
                        } else blk: {
                            break :blk try parseValue(value_token.span);
                        };

                        const section_res = try sections.getOrPut(current_section.?);
                        if (section_res.found_existing) {
                            const line_res = try section_res.value_ptr.getOrPut(key);
                            line_res.value_ptr.* = value;
                        } else {
                            section_res.value_ptr.* = std.StringHashMap(Value).init(allocator);

                            const line_res = try section_res.value_ptr.getOrPut(key);
                            line_res.value_ptr.* = value;
                        }
                    }
                },
                else => return ParserError.UnexpectedToken,
            }
        }

        return Ini{
            .map = sections,
        };
    }

    pub fn deinit(self: *@This()) void {
        var lines = self.map.valueIterator();
        while (lines.next()) |line| {
            line.deinit();
        }

        self.map.deinit();
    }

    pub fn get(self: @This(), section: []const u8, key: []const u8) ?Value {
        return (self.map.getPtr(section) orelse return null).get(key);
    }
};
