load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ImageCompression",
    module_name = "ImageCompression",
    srcs = glob([
        "Sources/**/*.swift",
    ]) + [
        # GHOST: outgoing photo size / quality / pixels (GGOutgoingImageHooks)
        "//Ghostgram/GGHooks:ImageCompressionHookSources",
    ],
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/MozjpegBinding:MozjpegBinding",
        # GHOST: hook points
        "//Ghostgram/GGCore:GGCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)
