const std = @import("std");

const hui = @import("hui.zig");

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

fn parseHeader(token: []const u8) ?[]const u8 {
    // smallest possible header is '[x]'
    if (token.len < 4) {
        // TODO: error on '[]'
        return null;
    }

    if (token[0] != '[' and token[token.len - 1] != ']') {
        // TODO: error on unclosed brackets
        return null;
    }

    return token[1 .. token.len - 1];
}

fn parseColor(rgba: []const u8) ParserError!hui.Color {
    // TODO: other rgba formats
    if (rgba.len == 8) {
        const r: u8 = try std.fmt.parseInt(u8, rgba[0..2], 16);
        const g: u8 = try std.fmt.parseInt(u8, rgba[2..4], 16);
        const b: u8 = try std.fmt.parseInt(u8, rgba[4..6], 16);
        const a: u8 = try std.fmt.parseInt(u8, rgba[6..8], 16);
        return hui.color(r, g, b, a);
    } else {
        return ParserError.UnsupportedRGBAFormat;
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

pub const ParserError = error{
    NoSectionDefined,
    ExpectedToken,
    FailedToParseLine,
    ExpectedEqualSign,
    UnclosedString,
    UnsupportedRGBAFormat,

    InvalidCharacter,
    Overflow,
    OutOfMemory,
};

pub const Ini = struct {
    map: std.StringHashMap(std.StringHashMap(Value)),

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParserError!Ini {
        // TODO: handle comments
        // TODO: proper tokenizer

        var sections = std.StringHashMap(std.StringHashMap(Value)).init(allocator);

        var tokens = std.mem.tokenize(u8, source, "\n\t ");

        var current_section: ?[]const u8 = null;
        while (tokens.next()) |token| {
            if (parseHeader(token)) |section| {
                current_section = section;
            } else {
                const line_tokens = [3][]const u8{
                    token,
                    tokens.next() orelse return ParserError.ExpectedToken,
                    tokens.next() orelse return ParserError.ExpectedToken,
                };

                const line = try parseLine(line_tokens);

                const section_res = try sections.getOrPut(
                    current_section orelse return ParserError.NoSectionDefined,
                );

                if (section_res.found_existing) {
                    const line_res = try section_res.value_ptr.getOrPut(line.key);
                    line_res.value_ptr.* = line.value;
                } else {
                    section_res.value_ptr.* = std.StringHashMap(Value).init(allocator);

                    const line_res = try section_res.value_ptr.getOrPut(line.key);
                    line_res.value_ptr.* = line.value;
                }
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
