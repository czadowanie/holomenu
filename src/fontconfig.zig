const std = @import("std");

const c = @cImport({
    @cInclude("fontconfig/fontconfig.h");
});

pub const FontConfig = struct {
    filepath: [:0]u8,
    size: i32,
    allocator: std.mem.Allocator,

    /// cleanup with `deinit`
    pub fn parse_and_resolve(allocator: std.mem.Allocator, fc_pattern: [*c]const u8) !@This() {
        const conf = c.FcInitLoadConfigAndFonts().?;

        const pattern = c.FcNameParse(fc_pattern).?;
        defer c.FcPatternDestroy(pattern);

        if (c.FcConfigSubstitute(conf, pattern, c.FcMatchPattern) != c.FcTrue) {
            std.log.err("failed to config substitute", .{});
        }
        c.FcDefaultSubstitute(pattern);

        const font_set = c.FcFontSetCreate().?;
        defer c.FcFontSetDestroy(font_set);

        const object_set = c.FcObjectSetBuild(
            c.FC_FAMILY,
            c.FC_STYLE,
            c.FC_FILE,
            c.FC_SIZE,
            @intToPtr([*c]const u8, 0),
        ).?;
        defer c.FcObjectSetDestroy(object_set);

        var result: c.FcResult = undefined;
        const font_patterns = c.FcFontSort(conf, pattern, c.FcTrue, null, &result).?;
        if (@ptrCast(*const c.FcFontSet, font_patterns).nfont == 0) {
            std.log.err("could not find any fonts", .{});
        }
        defer c.FcFontSetSortDestroy(font_patterns);

        const font_pattern = c.FcFontRenderPrepare(
            conf,
            pattern,
            @ptrCast(*const c.FcFontSet, font_patterns).fonts[0],
        ).?;
        _ = c.FcFontSetAdd(font_set, font_pattern);

        const font = c.FcPatternFilter(
            @ptrCast(*const c.FcFontSet, font_set).fonts[0],
            object_set,
        );
        defer c.FcPatternDestroy(font);

        var value: c.FcValue = undefined;

        _ = c.FcPatternGet(font, c.FC_FILE, 0, &value);
        const value_filepath = std.mem.sliceTo(@ptrCast([*c]const u8, value.u.f), 0);
        var filepath = try allocator.allocSentinel(u8, value_filepath.len, 0);
        std.mem.copy(u8, filepath, value_filepath);

        _ = c.FcPatternGet(font, c.FC_SIZE, 0, &value);

        return .{
            .filepath = filepath,
            .size = @floatToInt(i32, value.u.d),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: @This()) void {
        self.allocator.free(self.filepath);
    }
};
