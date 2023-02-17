const std = @import("std");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
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

pub const HoloMenuConfig = struct {
    height: u32 = 12,
};

pub fn main() !void {
    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.log.err("failed to init SDL: {s}", .{c.SDL_GetError()});
    }
    defer c.SDL_Quit();

    const display_dimensions = display_size().?;

    const window = c.SDL_CreateWindow("holomenu", 0, 0, display_dimensions.x, 26, c.SDL_WINDOW_SHOWN);
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, 0, c.SDL_RENDERER_ACCELERATED);
    defer c.SDL_DestroyRenderer(renderer);

    var running = true;
    while (running) {
        // events
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev) != 0) {
            switch (ev.type) {
                c.SDL_QUIT => {
                    running = false;
                },
                else => {},
            }
        }

        // render

        c.SDL_RenderPresent(renderer);
    }
}
