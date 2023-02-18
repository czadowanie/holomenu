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

pub const HoloMenuConfig = struct {
    height: u32 = 12,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

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
        26,
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

    const fc = try FontConfig.parse_and_resolve(allocator, "Iosevka:bold:italic:size=14");
    defer fc.deinit();

    std.log.info("font path: \"{s}\", font size: {}", .{ fc.filepath, fc.size });

    const font = c.TTF_OpenFont(fc.filepath.ptr, fc.size).?;
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
                .y = 2,
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
