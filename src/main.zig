const std = @import("std");

const fs = std.fs;
const mem = std.mem;
const math = std.math;
const Thread = std.Thread;
const Wyhash = std.hash.Wyhash;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const DynamicBitSet = std.DynamicBitSet;

test "check that it matches an in-game sprite" {
    var output = ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    const spinda = generateSpinda(0x88FE9800);
    try writeSpindaBitmap(output.writer(), &spinda);

    try std.testing.expectEqualStrings(@embedFile("asset/example.bmp"), output.items);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const total_spindas = math.maxInt(u32) + 1;
    var unique_spindas = try DynamicBitSet.initEmpty(allocator, total_spindas);
    var threads = ArrayList(Thread).init(allocator);

    const spindas_per_thread = 10_000_000;
    const num_threads = try math.divCeil(usize, total_spindas, spindas_per_thread);
    std.debug.print(
        "starting search: spawning {d} threads with {d} spt (spindas per thread)...\n",
        .{ num_threads, spindas_per_thread },
    );
    const hash_seed = 0;
    for (0..num_threads) |i| {
        const start = i * spindas_per_thread;
        const end = @min((i + 1) * spindas_per_thread, total_spindas);
        const thread = try Thread.spawn(.{}, searchSpindas, .{ start, end, &unique_spindas, hash_seed });
        try threads.append(thread);
    }
    for (threads.items) |thread| thread.join();
    std.debug.print("unique spinda count: {d} out of {d}\n", .{ unique_spindas.count(), total_spindas });
}

fn searchSpindas(start: usize, end: usize, unique_spindas: *DynamicBitSet, hash_seed: u64) void {
    for (start..end) |personality| {
        const spinda = generateSpinda(@intCast(personality));
        const hash: u32 = @truncate(Wyhash.hash(hash_seed, &spinda));
        setBitAtomic(unique_spindas, hash);
    }
}

fn setBitAtomic(bitset: *DynamicBitSet, index: usize) void {
    const mask_index = index >> @bitSizeOf(DynamicBitSet.ShiftInt);
    const mask_bit = @as(DynamicBitSet.MaskInt, 1) << @as(DynamicBitSet.ShiftInt, @truncate(index));
    _ = @atomicRmw(usize, &bitset.unmanaged.masks[mask_index], .Or, mask_bit, .Monotonic);
}

const first_spot: u8 = 1;
const last_spot: u8 = 3;
const spot_adjustment: u8 = 4;

fn generateSpinda(personality: u32) [spinda_size]u8 {
    var spinda = spinda_bytes;
    drawSpots(personality, &spinda);
    return spinda;
}

fn drawSpots(personality: u32, pixels: *[spinda_size]u8) void {
    var p = personality;
    for (spots) |spot| {
        defer p >>= 8;
        const x: u8 = spot.x +% (@as(u8, @truncate(p & 0x0f)) -% 8);
        var y: u8 = spot.y +% ((@as(u8, @truncate(p & 0xf0)) >> 4) -% 8) +% 3; // ? not sure why i need to offset by 3
        for (0..Spot.height) |row| {
            defer y +%= 1;
            var spot_row = spot.image[row];
            for (x..x + Spot.width) |col| {
                defer spot_row >>= 1;
                const pixel = &pixels[@as(usize, y) * spinda_row_size + col / 2];
                if (spot_row & 1 == 0) switch (col & 1) {
                    0 => if ((pixel.* & 0xf) -% first_spot <= last_spot - first_spot) {
                        pixel.* +%= spot_adjustment;
                    },
                    1 => if (((pixel.* & 0xf0) -% (first_spot << 4)) <= (last_spot - first_spot) << 4) {
                        pixel.* +%= spot_adjustment << 4;
                    },
                    else => unreachable,
                };
            }
        }
    }
}

const spots = [4]Spot{
    Spot.read("asset/spot0.bmp", .{ .x = 16, .y = 7 }),
    Spot.read("asset/spot1.bmp", .{ .x = 40, .y = 8 }),
    Spot.read("asset/spot2.bmp", .{ .x = 22, .y = 25 }),
    Spot.read("asset/spot3.bmp", .{ .x = 34, .y = 26 }),
};

const Spot = struct {
    x: u8,
    y: u8,
    image: [height]u16,

    pub const width = 16;
    pub const height = 16;

    pub fn read(comptime path: []const u8, coord: struct { x: u8, y: u8 }) Spot {
        const sprite = readBitmap(@embedFile(path), width, height);
        var image = [_]u16{0} ** height;
        for (&image, 0..) |*dest, row| {
            for (sprite[row * width ..][0..width], 0..) |src, col| {
                if (src.r > 0) dest.* |= @as(u16, 1) << @intCast(15 - col);
            }
        }
        return .{ .x = coord.x, .y = coord.y, .image = image };
    }
};

const Bgr32 = packed struct(u32) {
    b: u8 = 0,
    g: u8 = 0,
    r: u8 = 0,
    _: u8 = 0,
};

fn readBitmap(
    bytes: []const u8,
    comptime width: comptime_int,
    comptime height: comptime_int,
) [width * height]Bgr32 {
    const data_offset = mem.readIntLittle(u32, bytes[10..14]);
    const channels = 4;
    const line_len = channels * width;
    const data_size = line_len * height;
    const data = bytes[data_offset..][0..data_size];
    @setEvalBranchQuota(1_000_000);
    var pixels = [_]Bgr32{.{}} ** (width * height);
    for (0..height) |line| {
        for (0..line_len) |i| {
            const x = i / channels;
            const data_i = i + line * line_len;
            const pixel_i = x + (height - line - 1) * width;
            switch (i % channels) {
                inline 0, 1, 2, 3 => |n| {
                    @field(pixels[pixel_i], .{ "b", "g", "r", "_" }[n]) = data[data_i];
                },
                else => unreachable,
            }
        }
    }
    return pixels;
}

const spinda_width = 64;
const spinda_height = 64;
const spinda_row_size = spinda_width / 2;
const spinda_size = spinda_row_size * spinda_height;
const spinda_bytes = spindaBytes();

// commented values match the in-game indices
// uncommented values are at arbitrary indices
const palette = [_]u32{
    0xffffffff, // transparent
    0xffffe7ad, // head 0
    0xffe7ce9c, // head 1
    0xffceb57b, // head 2
    0xffae9667,
    0xffe0824b, // spot 0
    0xffe06735, // spot 1
    0xffb1501e, // spot 2
    0xff7d644b,
    0xff503832,
    0xff060606,
    0xffae3850,
    0xffe3cd9b,
    0xffc8b17f,
};

fn spindaBytes() [spinda_size]u8 {
    const sprite = readBitmap(@embedFile("asset/spinda.bmp"), 64, 64);
    var bytes = [_]u8{0} ** spinda_size;
    for (&bytes, 0..) |*byte, i| {
        const x = (i % spinda_row_size) * 2;
        const y = i / spinda_row_size;
        for (sprite[y * spinda_width + x ..][0..2], 0..) |pixel, n| {
            const color: u32 = @bitCast(pixel);
            const value: u4 = inline for (palette, 0..) |pal_color, p| {
                if (color == pal_color) break @intCast(p);
            } else @compileError(std.fmt.comptimePrint("invalid color: {x}", .{color}));
            switch (n) {
                0 => byte.* |= value,
                1 => byte.* |= @as(u8, value) << 4,
                else => unreachable,
            }
        }
    }
    return bytes;
}

// not used, but nice to have
fn writeSpindaBitmap(writer: anytype, spinda: *const [spinda_size]u8) !void {
    var pixels = [_]Bgr32{.{}} ** (spinda_width * spinda_height);
    for (spinda, 0..) |byte, i| {
        for (0..2) |n| {
            const value: u4 = switch (n) {
                0 => @truncate(byte),
                1 => @truncate((byte & 0xf0) >> 4),
                else => unreachable,
            };
            const color: u32 = switch (value) {
                0...13 => palette[value],
                else => return error.InvalidColorValue,
            };
            const x = (i % spinda_row_size) * 2 + n;
            const y = i / spinda_row_size;
            pixels[x + y * 64] = @bitCast(color);
        }
    }
    _ = try writer.write("\x42\x4d\x46\x40\x00\x00\x00\x00\x00\x00\x46\x00\x00\x00\x38\x00" ++ //
        "\x00\x00\x40\x00\x00\x00\x40\x00\x00\x00\x01\x00\x20\x00\x03\x00" ++ //
        "\x00\x00\x00\x40\x00\x00\x12\x0b\x00\x00\x12\x0b\x00\x00\x00\x00" ++ //
        "\x00\x00\x00\x00\x00\x00\x00\x00\xff\x00\x00\xff\x00\x00\xff\x00" ++ //
        "\x00\x00\x00\x00\x00\xff");
    for (0..spinda_height) |line| {
        const y = spinda_height - line - 1;
        for (0..spinda_width) |x| {
            const bits: u32 = @bitCast(pixels[x + y * spinda_width]);
            _ = try writer.writeInt(u32, bits, .Little);
        }
    }
}
