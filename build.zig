const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "chippy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addIncludePath(sdl_dep.path("include"));
    exe.linkLibrary(sdl_dep.artifact("SDL3"));
    exe.linkLibC();
    exe.linkLibCpp();

    exe.root_module.addIncludePath(b.path("deps/mdgui/include"));
    exe.root_module.addCSourceFiles(.{
        .files = &.{
            "deps/mdgui/src/mdgui_c.cpp",
            "deps/mdgui/src/mdgui_glue.cpp",
            "deps/mdgui/src/mdgui_backend_sdl.cpp",
        },
        .flags = &.{ "-std=c++17", "-fpermissive" },
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run chippy");
    run_step.dependOn(&run_cmd.step);
}
