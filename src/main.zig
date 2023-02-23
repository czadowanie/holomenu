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
    } = .{ .show = true, .text = "holo ", .bg = default_accent, .fg = default_secondary },

    pub fn merge(holo: *HoloMenuConfig, conf: ini.Ini) void {
        inline for (@typeInfo(HoloMenuConfig).Struct.fields) |section_field| {
            const t = @typeInfo(section_field.field_type);
            if (t != .Struct) {
                @compileError("every field in HoloMenuConfig should be a struct of values convertible from ini.Value");
            }
            inline for (t.Struct.fields) |key_field| {
                if (conf.get(section_field.name, key_field.name)) |value| {
                    const cast = switch (@typeInfo(key_field.field_type)) {
                        @typeInfo(i32) => ini.Value.asInt,
                        @typeInfo(bool) => ini.Value.asBool,
                        @typeInfo([]const u8) => ini.Value.asStr,
                        @typeInfo(hui.Color) => ini.Value.asColor,
                        else => @compileError("no cast found for " ++ @typeName(key_field.field_type)),
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

    const cfg_file = try std.fs.openFileAbsolute("/home/nm/.config/holomenu.ini", .{});
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
