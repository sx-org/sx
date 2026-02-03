const std = @import("std");
const TargetConfig = @import("target.zig").TargetConfig;

test "optimization levels select matching LLVM and Clang pipelines" {
    try std.testing.expect(TargetConfig.OptLevel.none.toLLVMPassPipeline() == null);
    try std.testing.expectEqualStrings("default<O1>", TargetConfig.OptLevel.less.toLLVMPassPipeline().?);
    try std.testing.expectEqualStrings("default<O2>", TargetConfig.OptLevel.default.toLLVMPassPipeline().?);
    try std.testing.expectEqualStrings("default<O3>", TargetConfig.OptLevel.aggressive.toLLVMPassPipeline().?);

    try std.testing.expectEqualStrings("-O0", TargetConfig.OptLevel.none.toClangFlag());
    try std.testing.expectEqualStrings("-O1", TargetConfig.OptLevel.less.toClangFlag());
    try std.testing.expectEqualStrings("-O2", TargetConfig.OptLevel.default.toClangFlag());
    try std.testing.expectEqualStrings("-O3", TargetConfig.OptLevel.aggressive.toClangFlag());
}
