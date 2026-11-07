// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacGlass",
    platforms: [.macOS(.v13)],
    targets: [
        // Objective-C bridge to librashader (the Metal runtime of its C API is only visible to Objective-C).
        .target(
            name: "LibraBridge",
            path: "Sources/LibraBridge",
            cSettings: [
                .headerSearchPath("vendor"),
                .define("LIBRA_RUNTIME_METAL"),
                .unsafeFlags(["-fobjc-arc"]),
            ],
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "MacGlass",
            dependencies: ["LibraBridge"],
            path: "Sources/MacGlass",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ]
)
