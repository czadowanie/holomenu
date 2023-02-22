const std = @import("std");

const hui = @import("hui.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

const FontConfig = @import("fontconfig.zig").FontConfig;

pub const DialogConfig = struct {
    height: i32,
    font_path: []const u8,
    font_size: i32,
    bg: hui.Color,
    fg: hui.Color,
    searchbar_bg: hui.Color,
    searchbar_fg: hui.Color,
    searchbar_width: i32,
    active_bg: hui.Color,
    active_fg: hui.Color,
    prompt_show: bool,
    prompt_text: []const u8,
    prompt_bg: hui.Color,
    prompt_fg: hui.Color,
};

fn next_active(filtered_len: usize, current: usize) usize {
    if (current < filtered_len - 1) {
        return current + 1;
    } else {
        return 0;
    }
}

fn prev_active(filtered_len: usize, current: usize) usize {
    if (current > 0) {
        return current - 1;
    } else {
        return filtered_len - 1;
    }
}

fn drawRect(renderer: *c.SDL_Renderer, color: hui.Color, x: i32, y: i32, size: [2]i32) !void {
    if (c.SDL_SetRenderDrawColor(
        renderer,
        color.r,
        color.g,
        color.b,
        color.a,
    ) != 0) {
        std.log.err("failed to set render draw color: {s}", .{c.SDL_GetError()});
        return DialogError.SDLError;
    }

    if (c.SDL_RenderFillRect(
        renderer,
        &c.SDL_Rect{
            .x = x,
            .y = y,
            .w = size[0],
            .h = size[1],
        },
    ) != 0) {
        std.log.err("failed to render fill rect: {s}", .{c.SDL_GetError()});
        return DialogError.SDLError;
    }
}

fn color_to_sdl(self: hui.Color) c.SDL_Color {
    return c.SDL_Color{
        .r = self.r,
        .g = self.g,
        .b = self.b,
        .a = self.a,
    };
}

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
    fg: hui.Color,
    text: []const u8,
) !Text {
    var buf = try allocator.alloc(u8, text.len + 1);
    defer allocator.free(buf);

    std.mem.copy(u8, buf, text);
    buf[text.len] = 0;

    const surface = c.TTF_RenderText_Blended(
        font,
        buf.ptr,
        color_to_sdl(fg),
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

    // SETUP
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
        config.height,
        c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_KEYBOARD_GRABBED | c.SDL_WINDOW_POPUP_MENU,
    ) orelse {
        std.log.err("failed to create a window: {s}", .{c.SDL_GetError()});
        return DialogError.SDLError;
    };
    defer {
        c.SDL_DestroyWindow(window);

        // idk, on my xmonad setup closing a window with `SDL_WINDOW_POPUP_MENU`
        // causes the window manager to ignore keyboard input until a new window
        // is shown.
        const fixup_window = c.SDL_CreateWindow(
            "holomenu",
            0,
            0,
            display_dimensions[0],
            config.height,
            c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_KEYBOARD_GRABBED,
        );
        c.SDL_DestroyWindow(fixup_window);
    }

    var w: c_int = undefined;
    var h: c_int = undefined;
    c.SDL_GetWindowSizeInPixels(window, &w, &h);

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

    const font = c.TTF_OpenFont(config.font_path.ptr, config.font_size) orelse {
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

    const padding_v = @divFloor(config.height - options_cache.text[0].size[1], 2);
    const padding = hui.Padding.initVH(padding_v, 12);

    // LOOP

    while (running) {
        var textfield_content_lowercase = try textfield_content.clone();
        defer textfield_content_lowercase.deinit();
        for (textfield_content_lowercase.items) |_, i| {
            textfield_content_lowercase.items[i] = std.ascii.toLower(
                textfield_content_lowercase.items[i],
            );
        }

        // filter
        var filtered = std.ArrayList(usize).init(allocator);
        defer filtered.deinit();
        for (options) |_, i| {
            const lowercase = options_cache.lowercase[i];
            if (matches(textfield_content.items, lowercase)) {
                try filtered.append(i);
            }
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
                            return null;
                        },
                        c.SDLK_RETURN, c.SDLK_RETURN2 => {
                            return options[filtered.items[active]];
                        },
                        c.SDLK_BACKSPACE => {
                            _ = textfield_content.popOrNull();
                        },
                        c.SDLK_RIGHT => {
                            active = next_active(filtered.items.len, active);
                        },
                        c.SDLK_LEFT => {
                            active = prev_active(filtered.items.len, active);
                        },
                        else => {
                            if (ev.key.keysym.mod & c.KMOD_CTRL != 0) {
                                switch (ev.key.keysym.sym) {
                                    c.SDLK_j, c.SDLK_n => {
                                        active = next_active(filtered.items.len, active);
                                    },
                                    c.SDLK_k, c.SDLK_p => {
                                        active = prev_active(filtered.items.len, active);
                                    },
                                    else => {},
                                }
                            } else {
                                const keyname = c.SDL_GetKeyName(ev.key.keysym.sym);
                                if (keyname[0] != 0) {
                                    if (std.mem.len(keyname) == 1) {
                                        const sym = @intCast(u8, ev.key.keysym.sym);
                                        const char = if (ev.key.keysym.mod == 1 or ev.key.keysym.mod == 2)
                                            std.ascii.toUpper(sym)
                                        else
                                            sym;
                                        try textfield_content.append(char);
                                        active = 0;
                                    } else {
                                        if (ev.key.keysym.sym == c.SDLK_SPACE) {
                                            try textfield_content.append(' ');
                                            active = 0;
                                        }
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
            var row_layout_x: i32 = 0;

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

            // PROMPT
            if (config.prompt_show) {
                const prompt_padding = hui.pad(padding_v, 0, padding_v, 12);

                const text = try createText(
                    allocator,
                    renderer,
                    font,
                    config.prompt_fg,
                    config.prompt_text,
                );
                defer c.SDL_DestroyTexture(text.texture);

                const box = hui.box(text.size, prompt_padding);

                try drawRect(renderer, config.prompt_bg, row_layout_x, 0, box.size);

                try renderText(
                    renderer,
                    text,
                    row_layout_x + box.content_offset[0],
                    box.content_offset[1],
                );

                row_layout_x += box.size[0];
            }

            // SEARCHBAR
            {
                const box = hui.box(.{ config.searchbar_width, config.height }, padding);

                try drawRect(renderer, config.searchbar_bg, row_layout_x, 0, box.size);

                if (textfield_content.items.len > 0) {
                    const text = try createText(
                        allocator,
                        renderer,
                        font,
                        config.searchbar_fg,
                        textfield_content.items,
                    );
                    defer c.SDL_DestroyTexture(text.texture);

                    try renderText(
                        renderer,
                        text,
                        row_layout_x + box.content_offset[0],
                        box.content_offset[1],
                    );
                }

                row_layout_x += box.size[0];
            }

            // OPTIONS

            var start: usize = 0;
            outer: while (true) {
                var i: usize = start;
                var x = row_layout_x;
                inner: while (true) {
                    const option_index = filtered.items[i];
                    const text = options_cache.text[option_index];
                    const box = hui.box(text.size, padding);
                    const visible = x + box.size[0] < display_dimensions[0];
                    if (!visible) {
                        break :inner;
                    }
                    if (i == active) {
                        break :outer;
                    }
                    x += box.size[0];
                    i += 1;
                }
                start += 1;
            }

            var i: usize = start;
            while (i < filtered.items.len) : (i += 1) {
                const option_index = filtered.items[i];
                const text = options_cache.text[option_index];
                const box = hui.box(text.size, padding);

                const visible = row_layout_x + box.size[0] < display_dimensions[0];
                if (!visible) {
                    break;
                }

                if (i == active) {
                    try drawRect(renderer, config.active_bg, row_layout_x, 0, box.size);
                    try renderText(
                        renderer,
                        text,
                        row_layout_x + box.content_offset[0],
                        box.content_offset[1],
                    );
                } else {
                    try renderText(
                        renderer,
                        text,
                        row_layout_x + box.content_offset[0],
                        box.content_offset[1],
                    );
                }

                row_layout_x += box.size[0];
            }

            // PRESENT
            c.SDL_RenderPresent(renderer);
        }
    }

    return null;
}
