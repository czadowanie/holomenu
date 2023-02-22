const std = @import("std");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

const FontConfig = @import("fontconfig.zig").FontConfig;

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn init(r: u8, g: u8, b: u8, a: u8) @This() {
        return .{
            .r = r,
            .g = g,
            .b = b,
            .a = a,
        };
    }

    fn to_sdl(self: *const @This()) c.SDL_Color {
        return c.SDL_Color{
            .r = self.r,
            .g = self.g,
            .b = self.b,
            .a = self.a,
        };
    }
};

pub const color = Color.init;

pub const DialogConfig = struct {
    height: u32,
    font_path: []const u8,
    font_size: u32,
    bg: Color,
    fg: Color,
    searchbar_bg: Color,
    searchbar_fg: Color,
    searchbar_width: u32,
    active_fg: Color,
};

pub const DialogError = error{
    SDLError,
};

fn matches(pattern: []const u8, str: []const u8) bool {
    if (std.mem.indexOf(u8, str, pattern)) |_| {
        return true;
    } else {
        return false;
    }
}

fn createText(
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    font: *c.TTF_Font,
    fg: Color,
    text: []const u8,
) !Text {
    var buf = try allocator.alloc(u8, text.len + 1);
    defer allocator.free(buf);

    std.mem.copy(u8, buf, text);
    buf[text.len] = 0;

    const surface = c.TTF_RenderText_Blended(
        font,
        buf.ptr,
        fg.to_sdl(),
    ) orelse {
        std.log.err("failed to render a text surface: {s}", .{c.TTF_GetError()});
        return DialogError.SDLError;
    };

    defer c.SDL_FreeSurface(surface);
    const texture = c.SDL_CreateTextureFromSurface(
        renderer,
        surface,
    ) orelse return DialogError.SDLError;

    return .{
        .texture = texture,
        .size = [2]i32{
            @ptrCast(*c.SDL_Surface, surface).w,
            @ptrCast(*c.SDL_Surface, surface).h,
        },
    };
}

fn renderText(renderer: *c.SDL_Renderer, text: Text, x: i32, y: i32) !void {
    const dst = c.SDL_Rect{
        .x = x,
        .y = y,
        .w = text.size[0],
        .h = text.size[1],
    };

    if (c.SDL_RenderCopy(renderer, text.texture, null, &dst) != 0) {
        std.log.err("failed to render copy: {s}", .{c.SDL_GetError()});
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

const Text = struct {
    texture: *c.SDL_Texture,
    size: [2]i32,
};

const OptionsCache = struct {
    text: []Text,
    lowercase: [][]u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, options_len: usize) !@This() {
        const text = try allocator.alloc(Text, options_len);

        const lowercase = try allocator.alloc([]u8, options_len);

        return .{
            .text = text,
            .lowercase = lowercase,
            .allocator = allocator,
        };
    }

    fn deinit(self: @This()) void {
        for (self.text) |text| {
            c.SDL_DestroyTexture(text.texture);
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

    for (options) |option, i| {
        var lowercase = try allocator.alloc(u8, option.len);
        for (option) |char, char_index| {
            lowercase[char_index] = std.ascii.toLower(char);
        }
        options_cache.lowercase[i] = lowercase;
    }

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

        @intCast(i32, config.height),

        c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_KEYBOARD_GRABBED,
    ) orelse {
        std.log.err("failed to create a window: {s}", .{c.SDL_GetError()});
        return DialogError.SDLError;
    };

    defer c.SDL_DestroyWindow(window);

    var renderer = c.SDL_CreateRenderer(window, 0, c.SDL_RENDERER_ACCELERATED) orelse {
        std.log.err("failed to create a renderer: {s}", .{c.SDL_GetError()});
        return DialogError.SDLError;
    };

    if (c.SDL_RenderSetVSync(renderer, 1) != 0) {
        std.log.err("failed to set vsync!", .{});
    }
    if (c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND) != 0) {
        std.log.err("failed to set blend mode!", .{});
    }

    defer c.SDL_DestroyRenderer(renderer);

    const font = c.TTF_OpenFont(config.font_path.ptr, @intCast(c_int, config.font_size)) orelse {
        std.log.err("failed to open font: {s}", .{c.TTF_GetError()});
        return DialogError.SDLError;
    };
    defer c.TTF_CloseFont(font);

    for (options) |option, i| {
        const text = try createText(
            allocator,
            renderer,
            font,
            config.fg,
            option,
        );
        options_cache.text[i] = text;
    }

    // PREP

    var running = true;
    var textfield_content = std.ArrayList(u8).init(allocator);
    var active: usize = 0;

    // LOOP

    while (running) {
        var textfield_content_lowercase = try textfield_content.clone();
        defer textfield_content_lowercase.deinit();
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

                            var pos: usize = 0;
                            for (options) |option, i| {
                                const lowercase = options_cache.lowercase[i];

                                if (matches(textfield_content.items, lowercase)) {
                                    if (pos == active) {
                                        return option;
                                    } else {
                                        pos += 1;
                                    }
                                }
                            }
                        },
                        c.SDLK_BACKSPACE => {
                            _ = textfield_content.popOrNull();
                        },
                        c.SDLK_RIGHT => {
                            active += 1;
                        },
                        c.SDLK_LEFT => {
                            if (active != 0) {
                                active -= 1;
                            }
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
        {
            // CLEAR

            if (c.SDL_SetRenderDrawColor(
                renderer,
                config.bg.r,
                config.bg.g,
                config.bg.b,
                config.bg.a,
            ) != 0) {
                std.log.err("failed to set draw color!", .{});
            }
            if (c.SDL_RenderClear(renderer) != 0) {
                std.log.err("failed to clear!", .{});
            }

            // SEARCHBAR

            if (textfield_content.items.len > 0) {
                const text = try createText(
                    allocator,
                    renderer,
                    font,
                    config.searchbar_fg,
                    textfield_content.items,
                );
                defer c.SDL_DestroyTexture(text.texture);
                try renderText(renderer, text, 0, 2);
            }

            // OPTIONS

            const PADDING = 16;
            var x: i32 = @intCast(i32, config.searchbar_width);
            var i: usize = 0;
            var pos: usize = 0;

            while (i < options.len and x < display_dimensions[0]) : (i += 1) {
                const lowercase = options_cache.lowercase[i];

                if (matches(textfield_content.items, lowercase)) {
                    const increment = if (pos == active) blk: {
                        const text = try createText(
                            allocator,
                            renderer,
                            font,
                            config.active_fg,
                            options[i],
                        );
                        defer c.SDL_DestroyTexture(text.texture);
                        try renderText(renderer, text, x, 2);
                        break :blk text.size[0];
                    } else blk: {
                        const text = options_cache.text[i];
                        try renderText(renderer, text, x, 2);
                        break :blk text.size[0];
                    };

                    x += increment + PADDING;
                    pos += 1;
                }
            }

            // PRESENT

            c.SDL_RenderPresent(renderer);
        }
    }

    return null;
}
