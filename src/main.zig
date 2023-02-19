const std = @import("std");

const FontConfig = @import("fontconfig.zig").FontConfig;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

pub fn Vec2(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}

fn display_size() ?Vec2(i32) {
    var display_mode: c.SDL_DisplayMode = undefined;
    if (c.SDL_GetCurrentDisplayMode(0, &display_mode) != 0) {
        std.log.err("failed to get current display mode: {s}", .{c.SDL_GetError()});
        return null;
    }

    return .{
        .x = display_mode.w,
        .y = display_mode.h,
    };
}

pub fn matches(pattern: []const u8, str: []const u8) bool {
    if (pattern.len > str.len) {
        return false;
    }

    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] != str[i]) {
            return false;
        }
        i += 1;
    }

    return true;
}

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

        const contents = try file.readToEndAlloc(allocator, 1024 * 16); // 16kb should be more than enough
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    var config = HoloMenuConfig{
        .height = 24,
        .font = "monospace:size=12",
    };

    const home = std.os.getenv("HOME").?;
    const config_path = try std.mem.join(allocator, "/", &[_][]const u8{ home, ".config/holomenu.json" });
    std.log.info("{s}", .{config_path});
    try config.merge_from_file(allocator, config_path);

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.log.err("failed to init SDL: {s}", .{c.SDL_GetError()});
        return;
    }
    defer c.SDL_Quit();

    if (c.TTF_Init() != 0) {
        std.log.err("failed to init SDL2_TTF {s}", .{c.TTF_GetError()});
        return;
    }
    defer c.TTF_Quit();

    const display_dimensions = display_size().?;

    const window = c.SDL_CreateWindow(
        "holomenu",
        0,
        0,
        display_dimensions.x,
        config.height.?,
        c.SDL_WINDOW_SHOWN,
    ).?;

    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, 0, c.SDL_RENDERER_ACCELERATED);
    defer c.SDL_DestroyRenderer(renderer);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const stdin = std.io.getStdIn().reader();

    if (stdin.context.isTty()) {
        std.log.err("don't run me from terminal silly!", .{});
        return;
    }
    var input = try stdin.readAllAlloc(alloc, 1024 * 1024);

    const fc = try FontConfig.parse_and_resolve(allocator, config.font.?.ptr);
    defer fc.deinit();

    std.log.info("font path: \"{s}\", font size: {}", .{ fc.filepath, fc.size });

    const font = c.TTF_OpenFont(fc.filepath.ptr, fc.size).?;
    defer c.TTF_CloseFont(font);

    var running = true;

    var textfield_content = std.ArrayList(u8).init(allocator);

    while (running) {
        // events
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev) != 0) {
            switch (ev.type) {
                c.SDL_QUIT => {
                    running = false;
                },
                c.SDL_KEYDOWN => {
                    switch (ev.key.keysym.sym) {
                        c.SDLK_ESCAPE => {
                            running = false;
                        },
                        c.SDLK_RETURN, c.SDLK_RETURN2 => {
                            running = false;

                            var lines = std.mem.tokenize(u8, input, "\n");
                            while (lines.next()) |line| {
                                if (matches(textfield_content.items, line)) {
                                    const stdout = std.io.getStdOut().writer();
                                    try stdout.print("{s}\n", .{line});
                                }
                            }
                        },
                        else => {
                            std.log.info("{}", .{ev.key.keysym});

                            if (ev.key.keysym.sym == c.SDLK_BACKSPACE) {
                                std.log.info("backspace!", .{});
                                _ = textfield_content.popOrNull();
                            } else {
                                const keyname = c.SDL_GetKeyName(ev.key.keysym.sym);
                                std.log.info("keyname: {s}", .{keyname});
                                if (keyname[0] != 0) {
                                    if (std.mem.len(keyname) == 1) {
                                        const sym = @intCast(u8, ev.key.keysym.sym);
                                        const char = if (ev.key.keysym.mod == 1 or ev.key.keysym.mod == 2)
                                            std.ascii.toUpper(sym)
                                        else
                                            sym;
                                        try textfield_content.append(char);
                                        std.log.info("{c}", .{char});
                                    } else {
                                        if (ev.key.keysym.sym == c.SDLK_SPACE) {
                                            try textfield_content.append(' ');
                                        }
                                    }
                                }
                            }

                            std.log.info("{s}", .{textfield_content.items});
                        },
                    }
                },
                else => {},
            }
        }

        // render
        // TODO: this is extremely terrible

        if (c.SDL_RenderClear(renderer) != 0) {
            std.log.err("failed to clear!", .{});
        }

        var lines = std.mem.tokenize(u8, input, "\n");
        const PADDING = 8;
        var x: i32 = PADDING;
        while (lines.next()) |line| {
            if (matches(textfield_content.items, line)) {
                const color = c.SDL_Color{ .r = 255, .g = 128, .b = 192, .a = 255 };

                var buf = try alloc.alloc(u8, line.len + 1);
                defer alloc.free(buf);

                std.mem.copy(u8, buf, line);
                buf[line.len] = 0;

                const surface = c.TTF_RenderText_Solid(font, buf.ptr, color).?;
                defer c.SDL_FreeSurface(surface);

                const texture = c.SDL_CreateTextureFromSurface(renderer, surface);
                defer c.SDL_DestroyTexture(texture);

                const dst = c.SDL_Rect{
                    .x = x,
                    .y = 2,
                    .w = @ptrCast(*c.SDL_Surface, surface).w,
                    .h = @ptrCast(*c.SDL_Surface, surface).h,
                };

                x += dst.w + PADDING;

                if (c.SDL_RenderCopy(renderer, texture, null, &dst) != 0) {
                    std.log.err("failed to render copy: {s}", .{c.SDL_GetError()});
                }
            }
        }

        c.SDL_RenderPresent(renderer);
    }
}
