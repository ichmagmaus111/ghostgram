load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "Display",
    module_name = "Display",
    srcs = glob([
        "Source/**/*.swift",
    ]) + [
        # GHOST: font substitution point (GGFontHooks)
        "//Ghostgram/GGHooks:DisplayHookSources",
    ],
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
    	"//submodules/ObjCRuntimeUtils:ObjCRuntimeUtils",
    	"//submodules/UIKitRuntimeUtils:UIKitRuntimeUtils",
        "//submodules/AppBundle:AppBundle",
    	"//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Markdown:Markdown",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        # GHOST: hook points
        "//Ghostgram/GGCore:GGCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)
