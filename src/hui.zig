//! hui is short of 'Holo UI'

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
};

pub const Padding = struct {
    t: i32,
    r: i32,
    b: i32,
    l: i32,

    pub fn init(t: i32, l: i32, b: i32, r: i32) @This() {
        return .{
            .t = t,
            .r = r,
            .b = b,
            .l = l,
        };
    }

    pub fn initVH(vertical: i32, horizontal: i32) @This() {
        return .{
            .t = vertical,
            .b = vertical,
            .r = horizontal,
            .l = horizontal,
        };
    }
};

pub const Box = struct {
    content_offset: [2]i32,
    size: [2]i32,

    pub fn init(content_size: [2]i32, padding: Padding) @This() {
        return @This(){
            .content_offset = [2]i32{
                padding.r,
                padding.t,
            },
            .size = [2]i32{
                content_size[0] + padding.r + padding.l,
                content_size[1] + padding.t + padding.b,
            },
        };
    }
};

pub const color = Color.init;
pub const pad = Padding.init;
pub const padVH = Padding.initVH;
pub const box = Box.init;
