const std = @import("std");

const hui = @import("hui.zig");
const fc = @import("fontconfig.zig");
const dialog = @import("dialog.zig");
const ini = @import("ini.zig");

const HoloMenuConfig = struct {
    const default_primary = hui.color(20, 20, 20, 255);
    const default_secondary = hui.color(250, 250, 250, 255);
    const default_accent = hui.color(250, 80, 250, 255);

    window: struct {
        height: i32,
        font: []const u8,
        bg: hui.Color,
        fg: hui.Color,
    } = .{ .height = 24, .font = "monospace:size=16", .bg = default_primary, .fg = default_secondary },

    searchbar: struct {
        width: i32,
        bg: hui.Color,
        fg: hui.Color,
    } = .{ .width = 200, .bg = default_primary, .fg = default_secondary },

    active: struct {
        bg: hui.Color,
        fg: hui.Color,
    } = .{ .bg = default_secondary, .fg = default_primary },

    prompt: struct {
        show: bool,
        text: []const u8,
        bg: hui.Color,
        fg: hui.Color,
    } = .{ .show = true, .text = "holo  ", .bg = default_accent, .fg = default_secondary },

    cursor: struct {
        show: bool,
        shape: []const u8,
        interval: i32,
    } = .{ .show = true, .shape = "bar", .interval = 500 },

    arrows: struct {
        show: bool,
        bg: hui.Color,
        fg: hui.Color,
        text_right: []const u8,
        text_left: []const u8,
    } = .{ .show = true, .bg = default_accent, .fg = default_secondary, .text_left = "<", .text_right = ">" },

    pub fn merge(holo: *HoloMenuConfig, conf: ini.Ini) void {
        inline for (@typeInfo(HoloMenuConfig).Struct.fields) |section_field| {
            const t = @typeInfo(section_field.type);
            if (t != .Struct) {
                @compileError("every field in HoloMenuConfig should be a struct of values convertible from ini.Value");
            }
            inline for (t.Struct.fields) |key_field| {
                if (conf.get(section_field.name, key_field.name)) |value| {
                    const cast = switch (@typeInfo(key_field.type)) {
                        @typeInfo(i32) => ini.Value.asInt,
                        @typeInfo(bool) => ini.Value.asBool,
                        @typeInfo([]const u8) => ini.Value.asStr,
                        @typeInfo(hui.Color) => ini.Value.asColor,
                        else => @compileError("no cast found for " ++ @typeName(key_field.type)),
                    };

                    @field(
                        @field(holo, section_field.name),
                        key_field.name,
                    ) = cast(value) orelse @field(
                        @field(holo, section_field.name),
                        key_field.name,
                    );
                }
            }
        }
    }
};

fn resolve_path(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    var pos: usize = 0;
    while (pos < path.len) {
        switch (path[pos]) {
            '$' => {
                pos += 2;

                const start = pos;

                if (std.mem.indexOfScalar(u8, path[pos..], ')')) |closing_pos| {
                    pos += closing_pos;
                } else {
                    return null;
                }

                pos += 1;

                const end = pos;

                std.log.err("{s}", .{path[start .. end - 1]});
                try output.appendSlice(std.os.getenv(path[start .. end - 1]) orelse return null);
            },
            '~' => {
                try output.appendSlice(std.os.getenv("HOME") orelse return null);
                pos += 1;
            },
            else => {
                try output.append(path[pos]);
                pos += 1;
            },
        }
    }

    return try output.toOwnedSlice();
}

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

    var config = HoloMenuConfig{};

    const config_path = (try resolve_path(allocator, "~/.config/holomenu.ini")).?;
    defer allocator.free(config_path);

    const cfg_file = try std.fs.openFileAbsolute(config_path, .{});
    defer cfg_file.close();

    const cfg_file_content = try cfg_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(cfg_file_content);

    var cfg = try ini.Ini.parse(allocator, cfg_file_content);
    defer cfg.deinit();

    config.merge(cfg);

    const font = try fc.FontConfig.parse_and_resolve(
        allocator,
        config.window.font,
    );
    defer font.deinit();

    const dialog_config = dialog.DialogConfig{
        .height = config.window.height,
        .font_path = font.filepath,
        .font_size = font.size,
        .bg = config.window.bg,
        .fg = config.window.fg,
        .searchbar_bg = config.searchbar.bg,
        .searchbar_fg = config.searchbar.fg,
        .searchbar_width = config.searchbar.width,
        .active_bg = config.active.bg,
        .active_fg = config.active.fg,
        .prompt_show = config.prompt.show,
        .prompt_text = config.prompt.text,
        .prompt_bg = config.prompt.bg,
        .prompt_fg = config.prompt.fg,
        .cursor_blink = config.cursor.interval != 0,
        .cursor_shape = blk: {
            if (std.mem.eql(u8, config.cursor.shape, "bar")) {
                break :blk dialog.CursorShape.Bar;
            } else if (std.mem.eql(u8, config.cursor.shape, "block")) {
                break :blk dialog.CursorShape.Block;
            } else if (std.mem.eql(u8, config.cursor.shape, "underline")) {
                break :blk dialog.CursorShape.Underline;
            } else {
                std.log.err("unrecognized cursor shape: '{s}', defaulting to \"bar\"", .{config.cursor.shape});
                break :blk dialog.CursorShape.Bar;
            }
        },
        .cursor_show = config.cursor.show,
        .cursor_interval = config.cursor.interval,
        .arrows_show = config.arrows.show,
        .arrows_text_left = config.arrows.text_left,
        .arrows_text_right = config.arrows.text_right,
        .arrows_bg = config.arrows.bg,
        .arrows_fg = config.arrows.fg,
    };

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
