const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/zplacebo.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vapoursynth_dep = b.dependency("vapoursynth", .{
        .target = target,
        .optimize = optimize,
    });

    mod.addImport("vapoursynth", vapoursynth_dep.module("vapoursynth"));

    const lib = b.addLibrary(.{
        .name = "zplacebo",
        .linkage = .dynamic,
        .root_module = mod,
    });

    if (lib.root_module.optimize == .ReleaseFast) {
        lib.root_module.strip = true;
    }

    lib.linkLibC();
    lib.linkLibCpp();

    if (os == .windows) {
        // Add Vulkan SDK include path
        const vk_sdk_path = std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch {
            @panic("VULKAN_SDK not set! Install Vulkan SDK");
        };
        defer b.allocator.free(vk_sdk_path);

        const vk_include_path = try std.fs.path.join(b.allocator, &[_][]const u8{ vk_sdk_path, "Include" });
        defer b.allocator.free(vk_include_path);
        lib.addIncludePath(.{ .cwd_relative = vk_include_path });

        lib.addIncludePath(.{ .cwd_relative = "deps_build/include" });

        // Add Windows library paths
        lib.addLibraryPath(.{ .cwd_relative = "C:/WINDOWS/system32" });
        lib.addLibraryPath(.{ .cwd_relative = "deps_build/lib" });

        // Add Vulkan SDK library path
        const vk_lib_path = try std.fs.path.join(b.allocator, &[_][]const u8{ vk_sdk_path, "Lib" });
        defer b.allocator.free(vk_lib_path);
        lib.addLibraryPath(.{ .cwd_relative = vk_lib_path });

        // Parse and add LIB environment variable paths
        const lib_env = std.process.getEnvVarOwned(b.allocator, "LIB") catch {
            @panic("LIB not set! Use Developer Command Prompt or vcvars64.bat");
        };
        defer b.allocator.free(lib_env);

        var it = std.mem.splitScalar(u8, lib_env, ';');
        while (it.next()) |path| {
            const trimmed_path = std.mem.trim(u8, path, " \t");
            if (trimmed_path.len > 0) {
                lib.addLibraryPath(.{ .cwd_relative = trimmed_path });
            }
        }

        // Link Windows libraries (dynamic)
        for (windows_libs) |lib_name| {
            lib.linkSystemLibrary2(lib_name, .{
                .preferred_link_mode = .dynamic,
                .needed = true,
            });
        }

        // Link Windows libraries (static)
        for (windows_libs2) |lib_name| {
            lib.linkSystemLibrary2(lib_name, .{
                .preferred_link_mode = .static,
                .needed = true,
            });
        }
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
