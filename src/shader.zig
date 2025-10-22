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
const filter_name = "Shader";

const Data = struct {
    node: *vs.Node = undefined,
    vi: *const vs.VideoInfo = undefined,

    hook: ?[*c]const c.struct_pl_hook = null,
    render_params: *c.struct_pl_render_params = undefined,
    planes: [3]bool = @splat(true),

    vfs: [8]*priv = undefined,
    threads: u32 = 3,
    sem: Semaphore = .{},
    mutex: [8]Mutex = undefined,
};

fn runShader(d: *Data, p: *priv, src_img: *c.struct_pl_frame) !void {
    var render_p: c.struct_pl_render_params = d.render_params.*;
    const hook_ptr: ?*const c.struct_pl_hook = if (d.hook) |h| @ptrCast(h) else null;
    render_p.hooks = &[_]?*const c.struct_pl_hook{hook_ptr};
    render_p.num_hooks = 1;

    var out_img: c.struct_pl_frame = src_img.*;
    var i: u32 = 0;
    while (i < src_img.*.num_planes) : (i += 1) {
        out_img.planes[i].texture = p.tex_out[i];
    }

    if (!c.pl_render_image(p.rr, src_img, &out_img, &render_p)) {
        return error.pl_render_image;
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

fn processFrame(d: *Data, dst: *const ZAPI.ZFrame(*vs.Frame), src: *const ZAPI.ZFrame(*const vs.Frame), _: i32) !void {
    d.sem.wait();

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

    var dst_img: c.struct_pl_frame = src_img;

    var plane: u32 = 0;
    var plane_idx: u32 = 0;
    var src_data: [3]c.struct_pl_plane_data = .{ .{}, .{}, .{} };

    while (plane < d.vi.format.numPlanes) : (plane += 1) {
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
    try runShader(d, p, &src_img);
    try download(p, dst, &src_data, &dst_img);

    d.mutex[sem_idx].unlock();
    d.sem.post();
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

    allocator.destroy(d.render_params);

    if (d.hook) |hook| {
        var hook_mut: [*c]const c.struct_pl_hook = hook;
        c.pl_mpv_user_shader_destroy(@constCast(&hook_mut));
    }

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
        map_out.setError("Shader: Input bitdepth should be 8, 16 (Integer) or 32 (Float).");
        zapi.freeNode(d.node);
        return;
    }

    const shader_path = map_in.getData("shader_path", 0);
    const shader_code = map_in.getData("shader_code", 0);

    if ((shader_path == null and shader_code == null) or
        (shader_path != null and shader_code != null))
    {
        map_out.setError("Shader: Provide either 'shader_path' (file) or 'shader_code' (inline), not both.");
        zapi.freeNode(d.node);
        return;
    }

    var shader_str: []const u8 = undefined;
    var shader_str_owned: bool = false;

    if (shader_path) |path| {
        var shader_file = std.fs.cwd().openFile(path, .{}) catch |file_err| {
            const msg = std.fmt.allocPrint(allocator, "Shader: Failed to open shader file ({any}).", .{file_err}) catch unreachable;
            defer allocator.free(msg);
            const err_msg = allocator.dupeZ(u8, msg) catch unreachable;
            map_out.setError(err_msg);
            zapi.freeNode(d.node);
            allocator.free(err_msg);
            return;
        };
        defer shader_file.close();

        shader_str = shader_file.readToEndAlloc(allocator, 1024 * 1024) catch |file_err| {
            const msg = std.fmt.allocPrint(allocator, "Shader: Failed to read shader file ({any}).", .{file_err}) catch unreachable;
            defer allocator.free(msg);
            const err_msg = allocator.dupeZ(u8, msg) catch unreachable;
            map_out.setError(err_msg);
            zapi.freeNode(d.node);
            allocator.free(err_msg);
            return;
        };
        shader_str_owned = true;
    } else {
        shader_str = shader_code.?;
        shader_str_owned = false;
    }
    defer if (shader_str_owned) allocator.free(shader_str);

    const log_level: c.enum_pl_log_level = map_in.getInt(u32, "log_level") orelse c.PL_LOG_ERR;
    const init_priv = zp.placeboInit(log_level) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Shader: Failed initializing libplacebo ({any}).", .{err}) catch unreachable;
        defer allocator.free(msg);
        const err_msg = allocator.dupeZ(u8, msg) catch unreachable;
        map_out.setError(err_msg);
        zapi.freeNode(d.node);
        allocator.free(err_msg);
        return;
    };

    const hook = c.pl_mpv_user_shader_parse(init_priv.*.gpu, shader_str.ptr, shader_str.len);
    if (hook == null) {
        map_out.setError("Shader: Failed parsing shader code.");
        zp.placeboUninit(init_priv);
        zapi.freeNode(d.node);
        return;
    }

    zp.placeboUninit(init_priv);

    d.hook = hook;

    const render_params: *c.struct_pl_render_params = allocator.create(c.struct_pl_render_params) catch unreachable;
    render_params.* = c.pl_render_fast_params;
    d.render_params = render_params;

    const threads: i32 = map_in.getInt(i32, "threads") orelse 2;
    if ((threads < 1) or (threads > 8)) {
        map_out.setError("Shader: 'threads' should be between 1 and 8.");
        zapi.freeNode(d.node);
        return;
    }

    d.threads = @intCast(threads);
    d.sem = .{ .permits = d.threads };

    for (0..d.threads) |i| {
        d.mutex[i] = .{};

        d.vfs[i] = zp.placeboInit(log_level) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "Shader: Failed initializing libplacebo ({any}).", .{err}) catch unreachable;
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
