const std = @import("std");
const allocator = std.heap.c_allocator;

pub const vapoursynth = @import("vapoursynth");
const vs = vapoursynth.vapoursynth4;

const deband = @import("deband.zig");
const shader = @import("shader.zig");
// const resample = @import("resample.zig");

pub const c = @cImport({
    @cInclude("libplacebo/dispatch.h");
    @cInclude("libplacebo/shaders/sampling.h");
    @cInclude("libplacebo/shaders/custom.h");
    @cInclude("libplacebo/utils/upload.h");
    @cInclude("libplacebo/vulkan.h");
});

pub const priv = struct {
    log: c.pl_log = null,
    vk: c.pl_vulkan = null,
    gpu: c.pl_gpu = null,
    dp: c.pl_dispatch = null,
    dither_state: c.pl_shader_obj = null,
    rr: c.pl_renderer = null,
    tex_in: [3]c.pl_tex = .{ null, null, null },
    tex_out: [3]c.pl_tex = .{ null, null, null },
};

pub fn placeboInit(log_level: c.enum_pl_log_level) !*priv {
    const p: *priv = try allocator.create(priv);
    p.* = .{};

    errdefer placeboUninit(p);

    var vp = c.pl_vulkan_default_params;
    var ip = c.pl_vk_inst_default_params;
    vp.allow_software = true;
    //  ip.debug = true;
    vp.max_api_version = c.VK_API_VERSION_1_2;
    ip.max_api_version = c.VK_API_VERSION_1_2;
    vp.instance_params = &ip;

    p.log = c.pl_log_create_351(c.PL_API_VER, &(c.struct_pl_log_params{
        .log_cb = &c.pl_log_color,
        .log_priv = null,
        .log_level = log_level,
    }));

    if (p.log == null) return error.pl_log_create_351;
    p.vk = c.pl_vulkan_create(p.log, &vp);
    if (p.vk == null) return error.pl_vulkan_create;
    p.gpu = p.vk.*.gpu;
    p.dp = c.pl_dispatch_create(p.log, p.gpu);
    if (p.dp == null) return error.pl_dispatch_create;
    p.rr = c.pl_renderer_create(p.log, p.gpu);
    if (p.rr == null) return error.pl_renderer_create;

    return p;
}

pub fn placeboUninit(p: *priv) void {
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        if (p.tex_in[i] != null) c.pl_tex_destroy(p.gpu, &p.tex_in[i]);
        if (p.tex_out[i] != null) c.pl_tex_destroy(p.gpu, &p.tex_out[i]);
    }

    if (p.rr != null) c.pl_renderer_destroy(&p.rr);
    if (p.dither_state != null) c.pl_shader_obj_destroy(&p.dither_state);
    if (p.dp != null) c.pl_dispatch_destroy(&p.dp);
    if (p.vk != null) c.pl_vulkan_destroy(&p.vk);
    if (p.log != null) c.pl_log_destroy(&p.log);
    allocator.destroy(p);
}

export fn VapourSynthPluginInit2(plugin: *vs.Plugin, vspapi: *const vs.PLUGINAPI) void {
    _ = vspapi.configPlugin.?("com.julek.zplacebo", "zplacebo", "Zig libplacebo plugin for VapourSynth", vs.makeVersion(1, 0), vs.VAPOURSYNTH_API_VERSION, 0, plugin);

    _ = vspapi.registerFunction.?("Deband", "clip:vnode;planes:int:opt;iterations:int:opt;threshold:float:opt;radius:float:opt;" ++
        "grain:float:opt;dither:int:opt;dither_algo:int:opt;threads:int:opt;log_level:int:opt;", "clip:vnode;", deband.create, null, plugin);

    _ = vspapi.registerFunction.?(
        "Shader",
        "clip:vnode;shader_code:data:opt;shader_path:data:opt;threads:int:opt;log_level:int:opt;",
        "clip:vnode;",
        shader.create,
        null,
        plugin,
    );
}
