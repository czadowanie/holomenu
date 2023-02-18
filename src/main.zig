const std = @import("std");

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

pub const HoloMenuConfig = struct {
    height: u32 = 12,
};

pub fn main() !void {
    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.log.err("failed to init SDL: {s}", .{c.SDL_GetError()});
    }
    defer c.SDL_Quit();

    if (c.TTF_Init() != 0) {
        std.log.err("failed to init SDL2_TTF {s}", .{c.TTF_GetError()});
    }
    defer c.TTF_Quit();

    const display_dimensions = display_size().?;

    const window = c.SDL_CreateWindow(
        "holomenu",
        0,
        0,
        display_dimensions.x,
        26,
        c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_POPUP_MENU,
    ).?;

    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, 0, c.SDL_RENDERER_ACCELERATED);
    defer c.SDL_DestroyRenderer(renderer);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const stdin = std.io.getStdIn().reader();

    var input = try stdin.readAllAlloc(alloc, 1024 * 1024);

    const font = c.TTF_OpenFont("/usr/share/fonts/TTF/DejaVuSansMono.ttf", 14).?;
    defer c.TTF_CloseFont(font);

    var running = true;
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
                        else => {},
                    }
                },
                else => {},
            }
        }

        // render
        // TODO: this is extremely terrible

        var lines = std.mem.tokenize(u8, input, "\n");
        const PADDING = 8;
        var x: i32 = PADDING;
        while (lines.next()) |line| {
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
                .y = 0,
                .w = @ptrCast(*c.SDL_Surface, surface).w,
                .h = @ptrCast(*c.SDL_Surface, surface).h,
            };

            x += dst.w + PADDING;

            if (c.SDL_RenderCopy(renderer, texture, null, &dst) != 0) {
                std.log.err("failed to render copy: {s}", .{c.SDL_GetError()});
            }
        }

        c.SDL_RenderPresent(renderer);
    }
}
