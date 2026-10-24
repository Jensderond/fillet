// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FilletKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "FilletKit", targets: ["FilletKernel", "FilletCore", "FilletViewport"]),
    ],
    targets: [
        // Built by scripts/build-occt.sh (static OpenCascade, macOS + iOS + iOS simulator).
        .binaryTarget(name: "OCCT", path: "vendor/OCCT.xcframework"),
        .target(
            name: "CFilletKernel",
            dependencies: ["OCCT"],
            exclude: ["occt"],
            cxxSettings: [
                // Symlink to vendor/occt-include (OCCT headers, created by the build script).
                .headerSearchPath("occt"),
            ]
        ),
        .target(name: "FilletKernel", dependencies: ["CFilletKernel"]),
        .target(name: "FilletCore", dependencies: ["FilletKernel"]),
        .target(name: "FilletViewport", dependencies: ["FilletKernel"]),
        .testTarget(name: "FilletKernelTests", dependencies: ["FilletKernel", "CFilletKernel"]),
        .testTarget(name: "FilletCoreTests", dependencies: ["FilletCore"]),
        .testTarget(name: "FilletViewportTests", dependencies: ["FilletViewport"]),
    ],
    cxxLanguageStandard: .cxx17
)
