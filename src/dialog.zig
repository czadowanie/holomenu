const std = @import("std");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

const FontConfig = @import("fontconfig.zig").FontConfig;

pub const DialogConfig = struct {
    height: i32,
    font: [:0]const u8,
};

pub const DialogError = error{
    SDLError,
};

fn matches(pattern: []const u8, str: []const u8) bool {
    // if (pattern.len > str.len) {
    //     return false;
    // }

    // var i: usize = 0;
    // while (i < pattern.len) {
    //     if (pattern[i] != str[i]) {
    //         return false;
    //     }
    //     i += 1;
    // }

    // return true;

    if (std.mem.indexOf(u8, str, pattern)) |_| {
        return true;
    } else {
        return false;
    }
}

fn display_size() DialogError![2]i32 {
    var display_mode: c.SDL_DisplayMode = undefined;
    if (c.SDL_GetCurrentDisplayMode(0, &display_mode) != 0) {
        std.log.err("failed to get current display mode: {s}", .{c.SDL_GetError()});
        return DialogError.SDLError;
    }

    return .{
        display_mode.w,
        display_mode.h,
    };
}

const OptionsCache = struct {
    const Text = struct {
        texture: *c.SDL_Texture,
        size: [2]i32,
    };

    text: []?Text,
    lowercase: []?[]u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, options_len: usize) !@This() {
        const text = try allocator.alloc(?Text, options_len);
        std.mem.set(?Text, text, null);

        const lowercase = try allocator.alloc(?[]u8, options_len);
        std.mem.set(?[]u8, lowercase, null);

        return .{
            .text = text,
            .lowercase = lowercase,
            .allocator = allocator,
        };
    }

    fn deinit(self: @This()) void {
        for (self.text) |text| {
            if (text) |cached| {
                c.SDL_DestroyTexture(cached.texture);
            }
        }
        self.allocator.free(self.text);
    }
};

pub fn open_dialog(
    allocator: std.mem.Allocator,
    options: []const []const u8,
    config: DialogConfig,
) !?[]const u8 {
    var options_cache = try OptionsCache.init(allocator, options.len);
    defer options_cache.deinit();

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.log.err("failed to init SDL: {s}", .{c.SDL_GetError()});
        return DialogError.SDLError;
    }
    defer c.SDL_Quit();

    if (c.TTF_Init() != 0) {
        std.log.err("failed to init SDL2_TTF {s}", .{c.TTF_GetError()});
        return DialogError.SDLError;
    }
    defer c.TTF_Quit();

    const display_dimensions = try display_size();

    const window = c.SDL_CreateWindow(
        "holomenu",
        0,
        0,
        display_dimensions[0],

        config.height,

        c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_KEYBOARD_GRABBED,
    ) orelse {
        std.log.err("failed to create a window: {s}", .{c.SDL_GetError()});
        return DialogError.SDLError;
    };

    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, 0, c.SDL_RENDERER_ACCELERATED) orelse {
        std.log.err("failed to create a renderer: {s}", .{c.SDL_GetError()});
        return DialogError.SDLError;
    };

    _ = c.SDL_RenderSetVSync(renderer, 1);

    defer c.SDL_DestroyRenderer(renderer);

    const fc = try FontConfig.parse_and_resolve(
        allocator,

        config.font.ptr,
    );
    defer fc.deinit();

    std.log.info("font path: \"{s}\", font size: {}", .{ fc.filepath, fc.size });

    const font = c.TTF_OpenFont(fc.filepath.ptr, fc.size) orelse {
        std.log.err("failed to open font: {s}", .{c.TTF_GetError()});
        return DialogError.SDLError;
    };
    defer c.TTF_CloseFont(font);

    var running = true;

    var textfield_content = std.ArrayList(u8).init(allocator);

    while (running) {
        var textfield_content_lowercase = try textfield_content.clone();
        for (textfield_content_lowercase.items) |_, i| {
            textfield_content_lowercase.items[i] = std.ascii.toLower(
                textfield_content_lowercase.items[i],
            );
        }

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

                            for (options) |option, i| {
                                const lowercase = if (options_cache.lowercase[i]) |value| value else blk: {
                                    var lowercase = try allocator.alloc(u8, option.len);
                                    for (option) |char, char_index| {
                                        lowercase[char_index] = std.ascii.toLower(char);
                                    }
                                    options_cache.lowercase[i] = lowercase;

                                    break :blk lowercase;
                                };

                                if (matches(textfield_content.items, lowercase)) {
                                    return option;
                                }
                            }
                        },
                        c.SDLK_BACKSPACE => {
                            _ = textfield_content.popOrNull();
                        },
                        else => {
                            const keyname = c.SDL_GetKeyName(ev.key.keysym.sym);
                            if (keyname[0] != 0) {
                                if (std.mem.len(keyname) == 1) {
                                    const sym = @intCast(u8, ev.key.keysym.sym);
                                    const char = if (ev.key.keysym.mod == 1 or ev.key.keysym.mod == 2)
                                        std.ascii.toUpper(sym)
                                    else
                                        sym;
                                    try textfield_content.append(char);
                                } else {
                                    if (ev.key.keysym.sym == c.SDLK_SPACE) {
                                        try textfield_content.append(' ');
                                    }
                                }
                            }
                        },
                    }
                },
                else => {},
            }
        }

        // render
        // TODO: refactor

        if (c.SDL_RenderClear(renderer) != 0) {
            std.log.err("failed to clear!", .{});
        }

        const TEXTFIELD_WIDTH = 300;

        const BG_COLOR = c.SDL_Color{
            .r = 0,
            .g = 0,
            .b = 0,
            .a = 255,
        };

        if (textfield_content.items.len > 0) {
            const color = c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 };

            var buf = try allocator.alloc(u8, textfield_content.items.len + 1);
            defer allocator.free(buf);

            std.mem.copy(u8, buf, textfield_content.items);
            buf[textfield_content.items.len] = 0;

            const surface = c.TTF_RenderText_Shaded(font, buf.ptr, color, BG_COLOR);
            defer c.SDL_FreeSurface(surface);

            const texture = c.SDL_CreateTextureFromSurface(renderer, surface);
            defer c.SDL_DestroyTexture(texture);

            const dst = c.SDL_Rect{
                .x = 0,
                .y = 2,
                .w = @ptrCast(*c.SDL_Surface, surface).w,
                .h = @ptrCast(*c.SDL_Surface, surface).h,
            };

            if (c.SDL_RenderCopy(renderer, texture, null, &dst) != 0) {
                std.log.err("failed to render copy: {s}", .{c.SDL_GetError()});
            }
        }

        const PADDING = 16;
        var x: i32 = TEXTFIELD_WIDTH;
        var i: usize = 0;
        while (i < options.len and x < display_dimensions[0]) : (i += 1) {
            const option = options[i];

            const lowercase = if (options_cache.lowercase[i]) |value| value else blk: {
                var lowercase = try allocator.alloc(u8, option.len);
                for (option) |char, char_index| {
                    lowercase[char_index] = std.ascii.toLower(char);
                }
                options_cache.lowercase[i] = lowercase;

                break :blk lowercase;
            };
            if (matches(textfield_content.items, lowercase)) {
                if (options_cache.text[i]) |cached| {
                    const dst = c.SDL_Rect{
                        .x = x,
                        .y = 2,
                        .w = cached.size[0],
                        .h = cached.size[1],
                    };

                    x += dst.w + PADDING;

                    if (c.SDL_RenderCopy(renderer, cached.texture, null, &dst) != 0) {
                        std.log.err("failed to render copy: {s}", .{c.SDL_GetError()});
                    }
                } else {
                    const color = c.SDL_Color{ .r = 255, .g = 128, .b = 192, .a = 255 };

                    var buf = try allocator.alloc(u8, option.len + 1);
                    defer allocator.free(buf);

                    std.mem.copy(u8, buf, option);
                    buf[option.len] = 0;

                    const surface = c.TTF_RenderText_Shaded(
                        font,
                        buf.ptr,
                        color,
                        BG_COLOR,
                    ) orelse {
                        std.log.err("failed to render a text surface: {s}", .{c.TTF_GetError()});
                        return DialogError.SDLError;
                    };

                    defer c.SDL_FreeSurface(surface);
                    const texture = c.SDL_CreateTextureFromSurface(
                        renderer,
                        surface,
                    ) orelse return DialogError.SDLError;

                    options_cache.text[i] = .{
                        .texture = texture,
                        .size = [2]i32{
                            @ptrCast(*c.SDL_Surface, surface).w,
                            @ptrCast(*c.SDL_Surface, surface).h,
                        },
                    };
                }
            }
        }

        c.SDL_RenderPresent(renderer);
    }

    return null;
}
