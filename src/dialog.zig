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

pub fn open_dialog(
    allocator: std.mem.Allocator,
    options: []const []const u8,
    config: DialogConfig,
) !?[]const u8 {
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

                            for (options) |option| {
                                if (matches(textfield_content.items, option)) {
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
        // TODO: this is extremely terrible

        if (c.SDL_RenderClear(renderer) != 0) {
            std.log.err("failed to clear!", .{});
        }

        const TEXTFIELD_WIDTH = 300;

        if (textfield_content.items.len > 0) {
            const color = c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 };

            var buf = try allocator.alloc(u8, textfield_content.items.len + 1);
            defer allocator.free(buf);

            std.mem.copy(u8, buf, textfield_content.items);
            buf[textfield_content.items.len] = 0;

            const surface = c.TTF_RenderText_Solid(font, buf.ptr, color);
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

        const PADDING = 8;
        var x: i32 = TEXTFIELD_WIDTH;
        for (options) |option| {
            if (matches(textfield_content.items, option)) {
                const color = c.SDL_Color{ .r = 255, .g = 128, .b = 192, .a = 255 };

                var buf = try allocator.alloc(u8, option.len + 1);
                defer allocator.free(buf);

                std.mem.copy(u8, buf, option);
                buf[option.len] = 0;

                const surface = c.TTF_RenderText_Solid(font, buf.ptr, color) orelse {
                    std.log.err("failed to render a text surface: {s}", .{c.TTF_GetError()});
                    return DialogError.SDLError;
                };

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

    return null;
}
