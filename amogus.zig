const c = @cImport({
    @cInclude("vapoursynth/VapourSynth4.h");
    @cInclude("vapoursynth/VSConstants4.h");
    @cInclude("vapoursynth/VSHelper4.h");
});

const std = @import("std");
const allocator = std.heap.page_allocator;
const assert = std.debug.assert;


const AmogusData = struct {
    node: *c.VSNode,
    vi: c.VSVideoInfo,
    src_depth: u6,  // Use u6 to make bitshifts less of a pain to write
    dst_depth: u6,  // Caution: max depth is 63
    force_range: bool,
    range: c.VSColorRange,
};


const amogus: [18][15]u32 = .{
    .{  81, 255, 254, 253,  18,  82, 199, 198, 197,  19,  83, 227, 226, 225,  20, },
    .{ 243, 252,   2,   3,  84, 187, 196,  10,  11,  21, 215, 224,   6,   7,  85, },
    .{ 242, 251, 250, 249,  22, 186, 195, 194, 193,  86, 214, 223, 222, 221,  23, },
    .{  87, 248, 247, 246,  24,  88, 192, 191, 190,  25,  89, 220, 219, 218,  26, },
    .{  90, 245,  27, 244,  91,  28, 189,  92, 188,  29,  93, 217,  30, 216,  94, },
    .{  31,  95,  32,  96,  33,  97,  34,  98,  35,  99,  36, 100,  37, 101,  38, },
    .{ 102, 171, 170, 169,  39, 103, 269, 268, 267,  40, 104, 157, 156, 155,  41, },
    .{ 159, 168,  14,  15, 105, 257, 266,   0,   1,  42, 145, 154,  16,  17, 106, },
    .{ 158, 167, 166, 165,  43, 256, 265, 264, 263, 107, 144, 153, 152, 151,  44, },
    .{ 108, 164, 163, 162,  45, 109, 262, 261, 260,  46, 110, 150, 149, 148,  47, },
    .{ 111, 161,  48, 160, 112,  49, 259, 113, 258,  50, 114, 147,  51, 146, 115, },
    .{  52, 116,  53, 117,  54, 118,  55, 119,  56, 120,  57, 121,  58, 122,  59, },
    .{ 123, 213, 212, 211,  60, 124, 185, 184, 183,  61, 125, 241, 240, 239,  62, },
    .{ 201, 210,   8,   9, 126, 173, 182,  12,  13,  63, 229, 238,   4,   5, 127, },
    .{ 200, 209, 208, 207,  64, 172, 181, 180, 179, 128, 228, 237, 236, 235,  65, },
    .{ 129, 206, 205, 204,  66, 130, 178, 177, 176,  67, 131, 234, 233, 232,  68, },
    .{ 132, 203,  69, 202, 133,  70, 175, 134, 174,  71, 135, 231,  72, 230, 136, },
    .{  73, 137,  74, 138,  75, 139,  76, 140,  77, 141,  78, 142,  79, 143,  80, },
};


// Unused non-vectorized function for reference
inline fn processFrame(comptime S: type, comptime T: type, comptime dither: bool, width: usize, height: usize, offset: f32, factor: f32, depth: u6, src_stride2: usize, dst_stride2: usize, srcp2: [*]const u8, dstp2: [*]u8) void
{
    @setFloatMode(.Optimized);  // Allows the compiler to add fused multiply-add instructions
    const amogus_f = comptime amogusNormalized();

    const src_stride = src_stride2 / @sizeOf(S);
    const dst_stride = dst_stride2 / @sizeOf(T);
    var srcp: [*]const S = @ptrCast([*]const S, @alignCast(@alignOf([*]const S), srcp2));
    var dstp: [*]T = @ptrCast([*]T, @alignCast(@alignOf([*]T), dstp2));

    var i: usize = 0;
    while (i < height) : (i += 1) {
        var j: usize = 0;
        while (j < width) : (j += 1) {
            const src = if (S != f32) @intToFloat(f32, srcp[j]) else srcp[j];
            var p = src * factor + offset;

            if (dither) {
                p += amogus_f[i % amogus_f.len][j % amogus_f[0].len];
            }

            if (T != f32) {
                p = @minimum(@maximum(p, 0.0), @intToFloat(f32, @as(u64, 1) << depth) - 1);
            }

            dstp[j] = if (T != f32) @floatToInt(T, @round(p)) else p;
        }
        srcp += src_stride;
        dstp += dst_stride;
    }
}


inline fn processFrameVec(comptime S: type, comptime T: type, comptime dither: bool, width: usize, height: usize, offset: f32, factor: f32, depth: u6, src_stride2: usize, dst_stride2: usize, srcp2: [*]const u8, dstp2: [*]u8) void
{
    const amogus_f = comptime amogusNormalized();
    // We extend the dither matrix to a width of 240 (lowest common multiple of 15 and 16)
    // to semi-efficiently vectorize it
    // Using a matrix with a width of 16 (like a common bayer matrix)
    // would be much better, but this is a meme anyway
    const amogus_padded = comptime padMatrix(amogus_f, 240);
    comptime assert(amogus_padded[0].len == 240);

    const src_stride = src_stride2 / @sizeOf(S);
    const dst_stride = dst_stride2 / @sizeOf(T);
    var srcp: [*]const S = @ptrCast([*]const S, @alignCast(@alignOf([*]const S), srcp2));
    var dstp: [*]T = @ptrCast([*]T, @alignCast(@alignOf([*]T), dstp2));

    const offset16 = @splat(16, offset);
    const factor16 = @splat(16, factor);
    const offset8 = @splat(8, offset);
    const factor8 = @splat(8, factor);

    var i: usize = 0;
    while (i < height) : (i += 1) {
        const dr = amogus_padded[i % amogus_padded.len];
        var j: usize = 0;
        // Caution: We assume that all pixel rows have an alignment of >= 32 bytes
        //          VapourSynth guarantees this
        while (j + 8 < ceilN(width, 8)) : (j += 16) {
            const dr16: @Vector(16, f32) = dr[(j % 240)..][0..16].*;
            processVecN(16, dither, offset16, factor16, depth, dr16, srcp[j..j+16], dstp[j..j+16]);
        }
        if (j < width) {
            const dr8: @Vector(8, f32) = dr[(j % 240)..][0..8].*;
            processVecN(8, dither, offset8, factor8, depth, dr8, srcp[j..j+8], dstp[j..j+8]);
        }
        srcp += src_stride;
        dstp += dst_stride;
    }
}


inline fn processVecN(comptime N: comptime_int, comptime dither: bool, offset: @Vector(N, f32), factor: @Vector(N, f32), depth: u6, dr: anytype, srcp: anytype, dstp: anytype) void
{
    @setFloatMode(.Optimized);  // Allows the compiler to add fused multiply-add instructions
    const S = @TypeOf(srcp[0]);
    const T = @TypeOf(dstp[0]);

    const src: @Vector(N, S) = srcp[0..N].*;
    var vec: @Vector(N, f32) = if (S != f32) undefined else src;
    // Zig's Vector type doesn't support casting of its elements, so we do it element-wise
    // in a loop and hope that the compiler vectorizes it away.
    if (S != f32) {
        var idx: usize = 0;
        while (idx < N) : (idx += 1) {
            vec[idx] = @intToFloat(f32, src[idx]);
        }
    }
    vec = vec * factor + offset;

    if (dither) {
        vec += dr;
    }

    if (T != f32) {
        // Round towards +inf
        // (May not be correct for negative values,
        //  but they get clamped anyway)
        vec = @trunc(vec + @splat(N, @as(f32, 0.49999997)));

        vec = @maximum(vec, @splat(N, @as(f32, 0.0)));
        vec = @minimum(vec, @splat(N, @intToFloat(f32, @as(u64, 1) << depth) - 1));
    }
    var dst: @Vector(N, T) = if (T != f32) undefined else vec;
    // Zig's Vector type doesn't support casting of its elements, so we do it element-wise
    // in a loop and hope that the compiler vectorizes it away.
    if (T != f32) {
        var idx: usize = 0;
        while (idx < N) : (idx += 1) {
            dst[idx] = @floatToInt(T, vec[idx]);
        }
    }

    dstp[0..N].* = dst;
}


inline fn setOffsetMax(depth: u6, fullrange: bool, plane: c_int, color_family: c.VSColorFamily, offset: *f64, max: *f64) void
{
    if (plane != 0 and color_family != c.cfRGB) {
        offset.* = @intToFloat(f64, @as(u64, 1) << (depth - 1));
    }
    max.* = @intToFloat(f64, (@as(u64, 1) << depth) - 1);
    if (!fullrange) {
        if (plane != 0 and color_family != c.cfRGB) {
            offset.* = @intToFloat(f64, @as(u64, 1) << (depth - 1));
            max.* = @intToFloat(f64, @as(u64, 224) << (depth - 8));
        } else {
            offset.* = @intToFloat(f64, @as(u64, 16) << (depth - 8));
            max.* = @intToFloat(f64, @as(u64, 219) << (depth - 8));
        }
    }
}


fn getFrame(n: c_int, activation_reason: c_int, instance_data: ?*anyopaque, frame_data: ?*?*anyopaque, frame_ctx: ?*c.VSFrameContext, core: ?*c.VSCore, vsapi: ?*const c.VSAPI) callconv(.C) ?*const c.VSFrame
{
    _ = frame_data;

    var d = @ptrCast(*AmogusData, @alignCast(@alignOf(*AmogusData), instance_data));

    if (activation_reason == c.arInitial) {
        vsapi.?.requestFrameFilter.?(n, d.node, frame_ctx);
        return null;

    } else if (activation_reason != c.arAllFramesReady) {
        return null;
    }

    const fmt = d.vi.format;
    const src = vsapi.?.getFrameFilter.?(n, d.node, frame_ctx);
    defer vsapi.?.freeFrame.?(src);
    var dst = vsapi.?.newVideoFrame.?(&fmt, d.vi.width, d.vi.height, src, core);

    var err: c_int = 0;
    const src_props = vsapi.?.getFramePropertiesRO.?(src);
    var src_fullrange = vsapi.?.mapGetInt.?(src_props, "_ColorRange", 0, &err) == c.VSC_RANGE_FULL;
    if (err != 0) {
        src_fullrange = false;
    }
    var dst_fullrange = src_fullrange;
    if (d.force_range) {
        var dst_props = vsapi.?.getFramePropertiesRW.?(dst);
        dst_fullrange = d.range == c.VSC_RANGE_FULL;
        _ = vsapi.?.mapSetInt.?(dst_props, "_ColorRange", d.range, c.maReplace);
    }

    var plane: c_int = 0;
    while (plane < fmt.numPlanes) : (plane += 1) {

        const color_family = @intCast(c.VSColorFamily, fmt.colorFamily);
        var src_offset: f64 = 0.0;
        var src_max: f64 = 1.0;
        if (d.src_depth != 32) {
            setOffsetMax(d.src_depth, src_fullrange, plane, color_family, &src_offset, &src_max);
        }

        var dst_offset: f64 = 0.0;
        var dst_max: f64 = 1.0;
        if (d.dst_depth != 32) {
            setOffsetMax(d.dst_depth, if (d.dst_depth < 8) true else dst_fullrange, plane, color_family, &dst_offset, &dst_max);
        }

        var offset = @floatCast(f32, -src_offset * dst_max / src_max + dst_offset);
        var factor = @floatCast(f32, dst_max / src_max);

        const width = @intCast(usize, d.vi.width >> if (plane != 0) @intCast(u5, fmt.subSamplingW) else 0);
        const height = @intCast(usize, d.vi.height >> if (plane != 0) @intCast(u5, fmt.subSamplingH) else 0);

        const src_stride = @intCast(usize, vsapi.?.getStride.?(src, plane));
        const dst_stride = @intCast(usize, vsapi.?.getStride.?(dst, plane));
        const srcp = vsapi.?.getReadPtr.?(src, plane);
        const dstp = vsapi.?.getWritePtr.?(dst, plane);

        if (d.src_depth <= 8 and fmt.bytesPerSample == 1) {
            processFrameVec(u8, u8, true, width, height, offset, factor, d.dst_depth, src_stride, dst_stride, srcp, dstp);
        } else if (d.src_depth <= 8 and fmt.bytesPerSample == 2) {
            processFrameVec(u8, u16, true, width, height, offset, factor, d.dst_depth, src_stride, dst_stride, srcp, dstp);
        } else if (d.src_depth <= 8 and fmt.bytesPerSample == 4) {
            processFrameVec(u8, f32, false, width, height, offset, factor, d.dst_depth, src_stride, dst_stride, srcp, dstp);
        } else if (d.src_depth <= 16 and fmt.bytesPerSample == 1) {
            processFrameVec(u16, u8, true, width, height, offset, factor, d.dst_depth, src_stride, dst_stride, srcp, dstp);
        } else if (d.src_depth <= 16 and fmt.bytesPerSample == 2) {
            processFrameVec(u16, u16, true, width, height, offset, factor, d.dst_depth, src_stride, dst_stride, srcp, dstp);
        } else if (d.src_depth <= 16 and fmt.bytesPerSample == 4) {
            processFrameVec(u16, f32, false, width, height, offset, factor, d.dst_depth, src_stride, dst_stride, srcp, dstp);
        } else if (d.src_depth <= 32 and fmt.bytesPerSample == 1) {
            processFrameVec(f32, u8, true, width, height, offset, factor, d.dst_depth, src_stride, dst_stride, srcp, dstp);
        } else if (d.src_depth <= 32 and fmt.bytesPerSample == 2) {
            processFrameVec(f32, u16, true, width, height, offset, factor, d.dst_depth, src_stride, dst_stride, srcp, dstp);
        } else if (d.src_depth <= 32 and fmt.bytesPerSample == 4) {  // Just for testing
            processFrameVec(f32, f32, false, width, height, offset, factor, d.dst_depth, src_stride, dst_stride, srcp, dstp);
        }

        // Upsample if depth is < 8 as only a depth of 8+ is supported by VapourSynth
        if (d.dst_depth < 8) {
            src_offset = dst_offset;
            src_max = dst_max;

            setOffsetMax(8, dst_fullrange, plane, color_family, &dst_offset, &dst_max);

            offset = @floatCast(f32, -src_offset * dst_max / src_max + dst_offset);
            factor = @floatCast(f32, dst_max / src_max);

            processFrameVec(u8, u8, false, width, height, offset, factor, 8, dst_stride, dst_stride, dstp, dstp);
        }
    }

    return dst;
}


fn free(instance_data: ?*anyopaque, core: ?*c.VSCore, vsapi: ?*const c.VSAPI) callconv(.C) void
{
    _ = core;
    var d = @ptrCast(*AmogusData, @alignCast(@alignOf(*AmogusData), instance_data));
    vsapi.?.freeNode.?(d.node);
    allocator.destroy(d);
}


fn create(in: ?*const c.VSMap, out: ?*c.VSMap, user_data: ?*anyopaque, core: ?*c.VSCore, vsapi: ?*const c.VSAPI) callconv(.C) void
{
    _ = user_data;

    var d: AmogusData = undefined;

    d.node = vsapi.?.mapGetNode.?(in, "clip", 0, null).?;
    d.dst_depth = saturateCast(u6, vsapi.?.mapGetInt.?(in, "depth", 0, null));
    d.vi = vsapi.?.getVideoInfo.?(d.node).*;
    d.src_depth = saturateCast(u6, d.vi.format.bitsPerSample);

    var err: c_int = 0;
    d.range = saturateCast(c.VSColorRange, vsapi.?.mapGetInt.?(in, "range", 0, &err));
    d.force_range = err == 0;

    validateInput(d.src_depth, d.dst_depth, d.vi, out.?, d.node, vsapi.?) catch return;

    d.vi.format.bitsPerSample = @maximum(d.dst_depth, 8);
    if (d.dst_depth > 16) {
        d.vi.format.bytesPerSample = 4;
        d.vi.format.sampleType = c.stFloat;
    } else if (d.dst_depth > 8) {
        d.vi.format.bytesPerSample = 2;
        d.vi.format.sampleType = c.stInteger;
    } else {
        d.vi.format.bytesPerSample = 1;
        d.vi.format.sampleType = c.stInteger;
    }

    var data: *AmogusData = allocator.create(AmogusData) catch unreachable;

    data.* = d;

    var deps = [_]c.VSFilterDependency{ c.VSFilterDependency{
        .source = data.node,
        .requestPattern = c.rpStrictSpatial
    }};
    vsapi.?.createVideoFilter.?(out, "Amogus", &data.vi, getFrame, free, c.fmParallel, &deps, 1, data, core);
}


fn validateInput(src_depth: u6, dst_depth: u6, vi: c.VSVideoInfo, out: *c.VSMap, node: *c.VSNode, vsapi: *const c.VSAPI) !void
{
    errdefer vsapi.freeNode.?(node);

    if (c.vsh_isConstantVideoFormat(&vi) == 0) {
        vsapi.mapSetError.?(out, "Amogus: Input clip must have a constant format.");
        return error.ValidationError;
    }

    if (dst_depth < 1 or dst_depth > 32) {
        vsapi.mapSetError.?(out, "Amogus: depth must be between 1 and 32.");
        return error.ValidationError;
    }

    if (vi.format.sampleType == c.stFloat and src_depth == 16) {
        vsapi.mapSetError.?(out, "Amogus: 16-bit float input is not supported.");
        return error.ValidationError;
    }

    if (vi.format.sampleType == c.stInteger and src_depth == 32) {
        vsapi.mapSetError.?(out, "Amogus: 32-bit integer input is not supported.");
        return error.ValidationError;
    }
}


inline fn saturateCast(comptime T: type, n: anytype) T
{
    const max = std.math.maxInt(T);
    if (n > max) {
        return max;
    }

    const min = std.math.minInt(T);
    if (n < min) {
        return min;
    }

    return @intCast(T, n);
}


fn amogusNormalized() [amogus.len][amogus[0].len]f32
{
    var amogus_f: [amogus.len][amogus[0].len]f32 = undefined;
    const n = @intToFloat(f32, amogus.len * amogus[0].len);

    var i: usize = 0;
    while (i < amogus.len) : (i += 1) {
        var j: usize = 0;
        while (j < amogus[0].len) : (j += 1) {
            const a = @intToFloat(f32, amogus[i][j]);

            amogus_f[i][j] = (a + 1.0) / (n + 1.0) - 0.5;
        }
    }

    return amogus_f;
}


fn padMatrix(matrix: anytype, n: usize) [matrix.len][n]@TypeOf(matrix[0][0])
{
    @setEvalBranchQuota(10000);
    assert(n > matrix[0].len);

    var matrix_padded: [matrix.len][n]@TypeOf(matrix[0][0]) = undefined;
    var i: usize = 0;
    while (i < matrix.len) : (i += 1) {
        var j: usize = 0;
        while (j < n) : (j += 1) {
            matrix_padded[i][j] = matrix[i][j % matrix[0].len];
        }
    }
    return matrix_padded;
}


inline fn ceilN(x: usize, n: usize) usize
{
    assert(n > 0);
    assert(n & (n - 1) == 0);  // Is power of 2

    return (x + (n - 1)) & ~(n - 1);
}


inline fn floorN(x: usize, n: usize) usize
{
    assert(n > 0);
    assert(n & (n - 1) == 0);  // Is power of 2

    return x & ~(n - 1);
}


export fn VapourSynthPluginInit2(plugin: *c.VSPlugin, vspapi: *const c.VSPLUGINAPI) void
{
    _ = vspapi.configPlugin.?("com.frechdachs.amogus", "amogus", "Amogus Dither", c.VS_MAKE_VERSION(1, 0), c.VAPOURSYNTH_API_VERSION, 0, plugin);

    _ = vspapi.registerFunction.?(
        "Amogus",
        "clip:vnode;depth:int;range:int:opt;",
        "clip:vnode;",
        create,
        null,
        plugin
    );
}
