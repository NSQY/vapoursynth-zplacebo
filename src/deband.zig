const std = @import("std");
const Semaphore = std.Thread.Semaphore;
const Mutex = std.Thread.Mutex;

const zp = @import("zplacebo.zig");
const vapoursynth = zp.vapoursynth;
const vs = vapoursynth.vapoursynth4;
const ZAPI = vapoursynth.ZAPI;
const ar = vs.ActivationReason;
const rp = vs.RequestPattern;
const fm = vs.FilterMode;
const st = vs.SampleType;
const cf = vs.ColorFamily;
const ma = vs.MapAppendMode;

const c = zp.c;
const priv = zp.priv;

const allocator = std.heap.c_allocator;
const filter_name = "Deband";

const Data = struct {
    node: *vs.Node = undefined,
    vi: *const vs.VideoInfo = undefined,

    dither: bool = false,
    render_params: *c.struct_pl_render_params = undefined,
    planes: [3]bool = @splat(true),

    vfs: [8]*priv = undefined,
    threads: u32 = 3,
    sem: Semaphore = .{},
    mutex: [8]Mutex = undefined,
};

fn runShader(d: *Data, p: *priv, src_img: *c.struct_pl_frame, frame_index: u8) !void {
    var i: u32 = 0;
    while (i < src_img.num_planes) : (i += 1) {
        var sh = c.pl_dispatch_begin(p.dp);
        var sh_p: c.struct_pl_shader_params = .{};
        sh_p.gpu = p.gpu;
        sh_p.index = frame_index;
        c.pl_shader_reset(sh, &sh_p);

        var src: c.struct_pl_sample_src = .{};
        src.tex = p.tex_in[i];

        const new_depth: c_int = p.tex_out[i].*.params.format.*.component_depth[i];
        c.pl_shader_deband(sh, &src, d.render_params.deband_params);

        if (d.dither) {
            c.pl_shader_dither(sh, new_depth, &p.dither_state, d.render_params.dither_params);
        }

        var d_p: c.struct_pl_dispatch_params = .{};
        d_p.target = p.tex_out[i];
        d_p.shader = &sh;

        if (!c.pl_dispatch_finish(p.dp, &d_p)) {
            return error.pl_dispatch_finish;
        }
    }
}

fn reconfig(p: *priv, dst: *const ZAPI.ZFrame(*vs.Frame), plane_idx: u32, src_data: *const c.struct_pl_plane_data) !void {
    const fmt = c.pl_plane_find_fmt(p.gpu, null, src_data);
    if (fmt == null) {
        return error.pl_plane_find_fmt;
    }

    var tex_p1: c.struct_pl_tex_params = .{};
    tex_p1.w = src_data.width;
    tex_p1.h = src_data.height;
    tex_p1.format = fmt;
    tex_p1.sampleable = true;
    tex_p1.host_writable = true;
    if (!c.pl_tex_recreate(p.gpu, &p.tex_in[plane_idx], &tex_p1)) {
        return error.pl_tex_recreate;
    }

    const vs_plane: u32 = @intCast(src_data.component_map[0]);
    var tex_p2: c.struct_pl_tex_params = .{};
    tex_p2.w = @intCast(dst.getWidth(vs_plane));
    tex_p2.h = @intCast(dst.getHeight(vs_plane));
    tex_p2.format = fmt;
    tex_p2.renderable = true;
    tex_p2.host_readable = true;
    if (!c.pl_tex_recreate(p.gpu, &p.tex_out[plane_idx], &tex_p2)) {
        return error.pl_tex_recreate;
    }
}

fn download(p: *priv, dst: *const ZAPI.ZFrame(*vs.Frame), src_data: []c.struct_pl_plane_data, dst_img: *c.struct_pl_frame) !void {
    var i: u32 = 0;
    while (i < dst_img.num_planes) : (i += 1) {
        const target_plane: *c.struct_pl_plane = &dst_img.planes[i];
        const vs_plane: u32 = @intCast(target_plane.component_mapping[0]);

        const out_fmt: c.pl_fmt = p.tex_out[i].*.params.format;
        const dst_ptr: [*]u8 = dst.getWriteSlice(vs_plane).ptr;
        const dst_row_pitch: usize = @divExact(dst.getStride(vs_plane), src_data[i].pixel_stride) * out_fmt.*.texel_size;

        var trans_p: c.struct_pl_tex_transfer_params = .{};
        trans_p.tex = p.tex_out[i];
        trans_p.row_pitch = dst_row_pitch;
        trans_p.ptr = dst_ptr;
        if (!c.pl_tex_download(p.gpu, &trans_p)) {
            return error.pl_tex_download;
        }
    }
}

fn processFrame(d: *Data, dst: *const ZAPI.ZFrame(*vs.Frame), src: *const ZAPI.ZFrame(*const vs.Frame), n: i32) !void {
    d.sem.wait(); // Acquire a permit

    var sem_idx: usize = 0;
    for (0..d.threads) |i| {
        if (d.mutex[i].tryLock()) {
            sem_idx = i;
            break;
        }
    }

    const p = d.vfs[sem_idx];

    var src_img: c.struct_pl_frame = .{
        .color = c.pl_color_space_unknown,
        .repr = .{
            .sys = c.PL_COLOR_SYSTEM_UNKNOWN,
            .bits = .{
                .sample_depth = d.vi.format.bitsPerSample,
                .color_depth = d.vi.format.bitsPerSample,
                .bit_shift = 0,
            },
        },
    };

    const frame_index: u8 = @intCast(@mod(n, 255));
    var dst_img: c.struct_pl_frame = src_img;

    var plane: u32 = 0;
    var plane_idx: u32 = 0;
    var src_data: [3]c.struct_pl_plane_data = .{ .{}, .{}, .{} };

    while (plane < d.vi.format.numPlanes) : (plane += 1) {
        if (!(d.planes[plane])) continue;

        src_img.num_planes += 1;

        src_data[plane_idx] = .{
            .type = if (d.vi.format.sampleType == .Integer) c.PL_FMT_UNORM else c.PL_FMT_FLOAT,
            .width = @intCast(src.getWidth(plane)),
            .height = @intCast(src.getHeight(plane)),
            .pixel_stride = @intCast(d.vi.format.bytesPerSample),
            .row_stride = src.getStride(plane),
            .pixels = src.getReadSlice(plane).ptr,
            .component_size = .{ d.vi.format.bitsPerSample, 0, 0, 0 },
            .component_map = .{ @intCast(plane), 0, 0, 0 },
        };

        try reconfig(p, dst, plane_idx, &src_data[plane_idx]);
        if (!c.pl_upload_plane(p.gpu, &src_img.planes[plane_idx], &p.tex_in[plane_idx], &src_data[plane_idx])) {
            return error.pl_upload_plane;
        }

        dst_img.planes[plane_idx] = .{
            .texture = p.tex_out[plane_idx],
            .components = p.tex_out[plane_idx].*.params.format.*.num_components,
            .component_mapping = .{ @intCast(plane), 0, 0, 0 },
        };

        plane_idx += 1;
    }

    dst_img.num_planes = src_img.num_planes;
    try runShader(d, p, &src_img, frame_index);
    try download(p, dst, &src_data, &dst_img);

    d.mutex[sem_idx].unlock();
    d.sem.post(); // Release the permit
}

fn getFrame(n: c_int, activation_reason: ar, instance_data: ?*anyopaque, _: ?*?*anyopaque, frame_ctx: ?*vs.FrameContext, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.c) ?*const vs.Frame {
    const d: *Data = @ptrCast(@alignCast(instance_data));
    const zapi = ZAPI.init(vsapi, core, frame_ctx);

    if (activation_reason == .Initial) {
        zapi.requestFrameFilter(n, d.node);
    } else if (activation_reason == .AllFramesReady) {
        const src = zapi.initZFrame(d.node, n);
        defer src.deinit();
        const dst = src.newVideoFrame2(d.planes);

        processFrame(d, &dst, &src, n) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{s}: {any}", .{ filter_name, err }) catch unreachable;
            defer allocator.free(msg);
            const err_msg = allocator.dupeZ(u8, msg) catch unreachable;
            zapi.setFilterError(err_msg);
            allocator.free(err_msg);
            dst.deinit();
            return null;
        };

        return dst.frame;
    }

    return null;
}

fn free(instance_data: ?*anyopaque, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.c) void {
    const zapi = ZAPI.init(vsapi, core, null);
    const d: *Data = @ptrCast(@alignCast(instance_data));
    zapi.freeNode(d.node);

    allocator.destroy(@as(*const c.struct_pl_deband_params, d.render_params.deband_params));
    allocator.destroy(@as(*const c.struct_pl_dither_params, d.render_params.dither_params));
    allocator.destroy(d.render_params);

    for (0..d.threads) |i| {
        zp.placeboUninit(d.vfs[i]);
    }

    allocator.destroy(d);
}

pub fn create(in: ?*const vs.Map, out: ?*vs.Map, _: ?*anyopaque, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.c) void {
    var d: Data = .{};
    const zapi = ZAPI.init(vsapi, core, null);
    const map_in = zapi.initZMap(in);
    const map_out = zapi.initZMap(out);

    d.node, d.vi = map_in.getNodeVi("clip").?;

    if ((d.vi.format.bitsPerSample != 8 and
        d.vi.format.bitsPerSample != 16 and
        d.vi.format.bitsPerSample != 32) or
        (d.vi.format.bitsPerSample == 16 and d.vi.format.sampleType != .Integer))
    {
        map_out.setError("Deband: Input bitdepth should be 8, 16 (Integer) or 32 (Float).");
        zapi.freeNode(d.node);
        return;
    }

    const is_8bits: bool = d.vi.format.bitsPerSample == 8;
    d.dither = map_in.getBool("dither") orelse is_8bits;
    if (d.dither and !is_8bits) {
        map_out.setError("Deband: 'dither' is only supported for 8-bit input.");
        zapi.freeNode(d.node);
        return;
    }

    var nodes = [_]?*vs.Node{d.node};
    getPlanes(map_in, map_out, &nodes, &d.planes, d.vi.format.numPlanes, filter_name, &zapi) catch return;

    const deband_params: *c.struct_pl_deband_params = allocator.create(c.struct_pl_deband_params) catch unreachable;
    deband_params.* = c.pl_deband_default_params;
    deband_params.iterations = map_in.getInt(c_int, "iterations") orelse 1;
    deband_params.threshold = map_in.getFloat(f32, "threshold") orelse 4;
    deband_params.radius = map_in.getFloat(f32, "radius") orelse 16;
    deband_params.grain = map_in.getFloat(f32, "grain") orelse 6;

    const dither_params: *c.struct_pl_dither_params = allocator.create(c.struct_pl_dither_params) catch unreachable;
    dither_params.* = c.pl_dither_default_params;
    dither_params.method = map_in.getInt(u32, "dither_algo") orelse c.PL_DITHER_BLUE_NOISE;

    const render_params: *c.struct_pl_render_params = allocator.create(c.struct_pl_render_params) catch unreachable;
    render_params.* = c.pl_render_fast_params;
    render_params.dither_params = dither_params;
    render_params.deband_params = deband_params;
    d.render_params = render_params;

    const threads: i32 = map_in.getInt(i32, "threads") orelse 2;
    if ((threads < 1) or (threads > 8)) {
        map_out.setError("Deband: 'threads' should be between 1 and 8.");
        zapi.freeNode(d.node);
        return;
    }

    d.threads = @intCast(threads);
    d.sem = .{ .permits = d.threads };

    const log_level: c.enum_pl_log_level = map_in.getInt(u32, "log_level") orelse c.PL_LOG_ERR;
    for (0..d.threads) |i| {
        d.mutex[i] = .{};

        d.vfs[i] = zp.placeboInit(log_level) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "Deband: Failed initializing libplacebo ({any}).", .{err}) catch unreachable;
            defer allocator.free(msg);
            const err_msg = allocator.dupeZ(u8, msg) catch unreachable;
            map_out.setError(err_msg);
            zapi.freeNode(d.node);
            allocator.free(err_msg);
            return;
        };
    }

    const data: *Data = allocator.create(Data) catch unreachable;
    data.* = d;

    var deps = [_]vs.FilterDependency{
        .{ .source = d.node, .requestPattern = .StrictSpatial },
    };

    zapi.createVideoFilter(out, filter_name, d.vi, getFrame, free, .Parallel, &deps, data);
}

pub fn getPlanes(in: ZAPI.ZMap(?*const vs.Map), out: ZAPI.ZMap(?*vs.Map), nodes: []const ?*vs.Node, process: []bool, num_planes: c_int, comptime name: []const u8, zapi: *const ZAPI) !void {
    const num_e = in.numElements("planes") orelse return; // use default planes
    @memset(process, false);

    var err_msg: ?[:0]const u8 = null;
    errdefer {
        out.setError(err_msg.?);
        for (nodes) |node| {
            if (node) |n| {
                zapi.freeNode(n);
            }
        }
    }

    var i: u32 = 0;
    while (i < num_e) : (i += 1) {
        const e = in.getInt2(i32, "planes", i).?;
        if ((e < 0) or (e >= num_planes)) {
            err_msg = name ++ ": plane index out of range";
            return error.ValidationError;
        }

        const ue: u32 = @intCast(e);
        if (process[ue]) {
            err_msg = name ++ ": plane specified twice.";
            return error.ValidationError;
        }

        process[ue] = true;
    }
}
