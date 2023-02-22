const std = @import("std");

const hui = @import("hui.zig");
const dialog = @import("dialog.zig");

pub const HoloMenuConfig = struct {
    height: i32,
    font: [:0]const u8,
    bg: []const u8,
    fg: []const u8,
    bg_search: []const u8,
    fg_search: []const u8,

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

    const stdin = std.io.getStdIn().reader();

    var input = try stdin.readAllAlloc(allocator, 1025 * 1024);
    var options = std.ArrayList([]const u8).init(allocator);
    var iter = std.mem.tokenize(u8, input, "\n");
    while (iter.next()) |option| {
        try options.append(option);
    }

    const dialog_config = dialog.DialogConfig{
        .height = 24,
        .font_path = "/home/nm/.local/share/fonts/Iosevka Nerd Font Complete Mono Windows Compatible.ttf",
        .font_size = 16,
        .bg = hui.color(15, 15, 20, 255),
        .fg = hui.color(250, 230, 230, 255),
        .searchbar_bg = hui.color(15, 15, 20, 255),
        .searchbar_fg = hui.color(250, 230, 230, 255),
        .searchbar_width = 300,
        .active_bg = hui.color(160, 80, 220, 255),
        .active_fg = hui.color(250, 240, 250, 255),
        .prompt_show = true,
        .prompt_text = "holo =>  ",
        .prompt_bg = hui.color(192, 100, 240, 255),
        .prompt_fg = hui.color(250, 240, 250, 255),
    };

    // TODO: this shouldn't be hardcoded actually
    const option = (try dialog.open_dialog(
        allocator,
        options.items,
        dialog_config,
    )) orelse {
        std.log.info("exiting without any option selected", .{});
        return;
    };

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{option});
}
