const std = @import("std");

const dialog = @import("dialog.zig");

pub const HoloMenuConfig = struct {
    height: ?i32,
    font: ?[:0]const u8,

    fn merge(self: *@This(), rhs: *const @This()) void {
        self.* = @This(){
            .height = if (rhs.height) |value| value else self.height,
            .font = if (rhs.font) |value| value else self.font,
        };
    }

    fn merge_from_file(self: *@This(), allocator: std.mem.Allocator, path: []const u8) !void {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        // 16kb should be more than enough
        const contents = try file.readToEndAlloc(allocator, 1024 * 16);

        defer allocator.free(contents);

        var parser = std.json.Parser.init(allocator, false);
        defer parser.deinit();

        var tree = try parser.parse(contents);
        defer tree.deinit();

        switch (tree.root) {
            .Object => |obj| {
                const rhs = @This(){
                    .height = if (obj.getEntry("height")) |entry| switch (entry.value_ptr.*) {
                        std.json.Value.Integer => |value| @intCast(i32, value),
                        else => blk: {
                            std.log.err("{s}: \"height\" should be an integer", .{path});
                            break :blk null;
                        },
                    } else null,
                    .font = if (obj.getEntry("font")) |entry| switch (entry.value_ptr.*) {
                        .String => |value| blk: {
                            var string = @ptrCast([:0]u8, try allocator.alloc(u8, value.len + 1));
                            std.mem.copy(u8, string, value);
                            string[value.len] = 0;
                            break :blk string;
                        },
                        else => blk: {
                            std.log.err("{s}: \"font\" should be a string", .{path});
                            break :blk null;
                        },
                    } else null,
                };

                self.merge(&rhs);
            },
            else => {
                std.log.err("expected object at top level of config", .{});
            },
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var config = HoloMenuConfig{
        .height = 24,
        .font = "monospace:size=12",
    };

    const stdin = std.io.getStdIn().reader();
    if (stdin.context.isTty()) {
        // TODO: display a help message instead
        std.log.err("don't run me from terminal silly!", .{});
        return;
    }

    const home = std.os.getenv("HOME") orelse {
        std.log.err("$HOME is not set", .{});
        return;
    };

    const config_path = try std.mem.join(
        allocator,
        "/",
        &[_][]const u8{ home, ".config/holomenu.json" },
    );
    try config.merge_from_file(allocator, config_path);

    var input = try stdin.readAllAlloc(allocator, 1025 * 1024);

    var options = std.ArrayList([]const u8).init(allocator);
    var iter = std.mem.tokenize(u8, input, "\n");
    while (iter.next()) |option| {
        try options.append(option);
    }

    const option = (try dialog.open_dialog(allocator, options.items, .{
        // SAFETY: this should be fine since there's a default height that should always be set
        .height = config.height.?,
        // SAFETY: this should be fine since there's a default font that should always be set
        .font = config.font.?,
    })) orelse {
        std.log.info("exiting without any option selected", .{});
        return;
    };

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{option});
}
