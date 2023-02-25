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

    cursor_show: bool,
    cursor_interval: i32,

    arrows_show: bool,
    arrows_text_left: []const u8,
    arrows_text_right: []const u8,
    arrows_bg: hui.Color,
    arrows_fg: hui.Color,
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

    for (options, 0..) |option, i| {
        var lowercase = try allocator.alloc(u8, option.len);
        for (option, 0..) |char, char_index| {
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
            c.SDL_WINDOW_SHOWN,
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

    for (options, 0..) |option, i| {
        const text = try createText(
            allocator,
            renderer,
            font,
            config.fg,
            option,
        );
        options_cache.text[i] = text;
    }

    // padding

    const padding_v = @divFloor(config.height - options_cache.text[0].size[1], 2);
    const padding = hui.Padding.initVH(padding_v, 12);

    // prerender prompt_text

    const prompt_text = try createText(
        allocator,
        renderer,
        font,
        config.prompt_fg,
        config.prompt_text,
    );
    defer c.SDL_DestroyTexture(prompt_text.texture);

    // prerender arrows

    const left_arrow_text = try createText(
        allocator,
        renderer,
        font,
        config.arrows_fg,
        config.arrows_text_left,
    );
    defer c.SDL_DestroyTexture(left_arrow_text.texture);
    const left_arrow_box = hui.box(left_arrow_text.size, padding);

    const right_arrow_text = try createText(
        allocator,
        renderer,
        font,
        config.arrows_fg,
        config.arrows_text_right,
    );
    defer c.SDL_DestroyTexture(right_arrow_text.texture);
    const right_arrow_box = hui.box(right_arrow_text.size, padding);

    // PREP

    var running = true;
    var textfield_content = std.ArrayList(u8).init(allocator);
    var active: usize = 0;
    var delta_timer = try std.time.Timer.start();

    // TODO: this should be configurable
    var cursor_timer: f32 = 0;
    const cursor_interval = @intToFloat(f32, config.cursor_interval);

    // LOOP

    while (running) {
        _ = c.SDL_SetWindowInputFocus(window);
        // delta time is ms
        const dt: f32 = @intToFloat(f32, delta_timer.lap()) / (1000.0 * 1000.0);

        var textfield_content_lowercase = try textfield_content.clone();
        defer textfield_content_lowercase.deinit();
        for (textfield_content_lowercase.items, 0..) |_, i| {
            textfield_content_lowercase.items[i] = std.ascii.toLower(
                textfield_content_lowercase.items[i],
            );
        }

        // filter
        var filtered = std.ArrayList(usize).init(allocator);
        defer filtered.deinit();
        for (options, 0..) |_, i| {
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
                            cursor_timer = 0;
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
                                        cursor_timer = 0;
                                    } else {
                                        if (ev.key.keysym.sym == c.SDLK_SPACE) {
                                            try textfield_content.append(' ');
                                            active = 0;
                                            cursor_timer = 0;
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
                const box = hui.box(prompt_text.size, prompt_padding);

                try drawRect(renderer, config.prompt_bg, row_layout_x, 0, box.size);

                try renderText(
                    renderer,
                    prompt_text,
                    row_layout_x + box.content_offset[0],
                    box.content_offset[1],
                );

                row_layout_x += box.size[0];
            }

            // SEARCHBAR
            {
                const box = hui.box(.{ config.searchbar_width, config.height }, padding);

                try drawRect(renderer, config.searchbar_bg, row_layout_x, 0, box.size);

                var cursor_offset: i32 = 0;

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

                    cursor_offset = text.size[0];
                }

                if (config.cursor_show) {
                    cursor_timer += dt;
                    if (cursor_timer < cursor_interval) {
                        try drawRect(
                            renderer,
                            config.searchbar_fg,
                            row_layout_x + box.content_offset[0] + cursor_offset + 2,
                            box.content_offset[1] + 2,
                            .{ 2, config.font_size },
                        );
                    }
                    if (cursor_timer > cursor_interval * 2.0) {
                        cursor_timer -= cursor_interval * 2.0;
                    }
                }

                row_layout_x += box.size[0];
            }

            // OPTIONS

            var start: usize = 0;
            if (filtered.items.len > 0) {
                outer: while (true) {
                    var i: usize = start;
                    var x = row_layout_x;
                    inner: while (true) {
                        const option_index = filtered.items[i];
                        const text = options_cache.text[option_index];
                        const box = hui.box(text.size, padding);

                        const visible = x + box.size[0] < (display_dimensions[0] - if (config.arrows_show)
                            (left_arrow_box.size[0] + right_arrow_box.size[0])
                        else
                            0);

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
            }

            if (config.arrows_show and start > 0) {
                try drawRect(renderer, config.arrows_bg, row_layout_x, 0, left_arrow_box.size);
                try renderText(
                    renderer,
                    left_arrow_text,
                    row_layout_x + left_arrow_box.content_offset[0],
                    left_arrow_box.content_offset[1],
                );

                row_layout_x += left_arrow_box.size[0];
            }

            var show_right_arrow = false;

            var i: usize = start;
            while (i < filtered.items.len) : (i += 1) {
                if (show_right_arrow) {
                    break;
                }

                const option_index = filtered.items[i];
                const text = options_cache.text[option_index];
                const box = hui.box(text.size, padding);

                const visible = row_layout_x + box.size[0] < display_dimensions[0];
                if (!visible) {
                    show_right_arrow = true;
                }

                if (i == active) {
                    const text_active = try createText(
                        allocator,
                        renderer,
                        font,
                        config.active_fg,
                        options[filtered.items[i]],
                    );

                    try drawRect(renderer, config.active_bg, row_layout_x, 0, box.size);
                    try renderText(
                        renderer,
                        text_active,
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

            if (config.arrows_show and show_right_arrow) {
                const arrow_box_x = display_dimensions[0] - right_arrow_box.size[0];

                try drawRect(renderer, config.arrows_bg, arrow_box_x, 0, right_arrow_box.size);
                try renderText(
                    renderer,
                    right_arrow_text,
                    arrow_box_x + right_arrow_box.content_offset[0],
                    right_arrow_box.content_offset[1],
                );
            }

            // PRESENT
            c.SDL_RenderPresent(renderer);
        }
    }

    return null;
}
