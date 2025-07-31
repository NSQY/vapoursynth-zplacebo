const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;

    const lib = b.addSharedLibrary(.{
        .name = "zplacebo",
        .root_source_file = b.path("src/zplacebo.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vapoursynth_dep = b.dependency("vapoursynth", .{
        .target = target,
        .optimize = optimize,
    });

    lib.root_module.addImport("vapoursynth", vapoursynth_dep.module("vapoursynth"));

    if (lib.root_module.optimize == .ReleaseFast) {
        lib.root_module.strip = true;
    }

    lib.linkLibC();
    lib.linkLibCpp();

    if (os == .windows) {
        const lib_paths: std.ArrayList([]const u8) = try getLibPath(b);
        const include_paths: std.ArrayList([]const u8) = try getIncludePath(b);

        for (include_paths.items) |path| {
            lib.addIncludePath(.{ .cwd_relative = path });
        }

        for (lib_paths.items) |path| {
            lib.addLibraryPath(.{ .cwd_relative = path });
        }

        for (windows_libs) |lib_name| {
            lib.linkSystemLibrary2(lib_name, .{
                .preferred_link_mode = .dynamic,
                .needed = true,
            });
        }

        for (windows_libs2) |lib_name| {
            lib.linkSystemLibrary2(lib_name, .{
                .preferred_link_mode = .static,
                .needed = true,
            });
        }

        for (lib_paths.items[1..]) |path| b.allocator.free(path);
        for (include_paths.items) |path| b.allocator.free(path);
        lib_paths.deinit();
        include_paths.deinit();
    } else {
        lib.linkSystemLibrary("placebo");
    }

    b.installArtifact(lib);
}

const windows_libs = [_][]const u8{
    "vulkan-1",
    "msvcrt",
    "shlwapi",
    "Ntdll",
    "ws2_32",
    "userenv",
    "bcrypt",

    "shaderc_shared",
};

const windows_libs2 = [_][]const u8{
    "placebo",
    "libcmt",

    //   "shaderc_combined",
};

fn getIncludePath(b: *std.Build) !std.ArrayList([]const u8) {
    var paths = std.ArrayList([]const u8).init(b.allocator);
    const vk_sdk_path = std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch {
        @panic("VULKAN_SDK not set! Install Vulkan SDK");
    };

    defer b.allocator.free(vk_sdk_path);
    const vk_include_path = try std.fs.path.join(b.allocator, &[_][]const u8{ vk_sdk_path, "Include" });
    try paths.append(vk_include_path);
    try paths.append(b.path("deps_build/include").getPath(b));
    return paths;
}

fn getLibPath(b: *std.Build) !std.ArrayList([]const u8) {
    var paths = std.ArrayList([]const u8).init(b.allocator);
    try paths.append("C:/WINDOWS/system32");
    try paths.append(b.path("deps_build/lib").getPath(b));

    const vclib: []u8 = std.process.getEnvVarOwned(b.allocator, "LIB") catch {
        @panic("LIB not set! Use Developer Command Prompt or vcvars64.bat");
    };

    defer b.allocator.free(vclib);
    var it = std.mem.splitScalar(u8, vclib, ';');
    while (it.next()) |path| {
        const trimmed_path = std.mem.trim(u8, path, " \t");
        if (trimmed_path.len > 0) {
            const owned_path = try b.allocator.dupe(u8, trimmed_path);
            try paths.append(owned_path);
        }
    }

    const vk_sdk_path = std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch {
        @panic("VULKAN_SDK not set! Install Vulkan SDK");
    };

    defer b.allocator.free(vk_sdk_path);
    const vk_lib_path = try std.fs.path.join(b.allocator, &[_][]const u8{ vk_sdk_path, "Lib" });
    try paths.append(vk_lib_path);
    return paths;
}
