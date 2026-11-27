// swift-tools-version: 6.0
import PackageDescription

// The Workbench host: Workbench with no window, for a Linux box (and, built
// the same way, a Mac nobody is logged in to). It owns agent sessions and
// answers the Mac and iPhone apps over the connection they already speak.
//
// It links Ghostty's terminal engine (libghostty-vt) as a static library,
// which `scripts/build-host-terminal.sh` builds into `build/ghostty-vt/`.
// Set WORKBENCH_GHOSTTY_VT to use one from somewhere else.
#if os(macOS)
let flavor = "aarch64-macos"
#elseif arch(arm64)
let flavor = "aarch64-linux-musl"
#else
let flavor = "x86_64-linux-musl"
#endif
let terminalLibrary = Context.environment["WORKBENCH_GHOSTTY_VT"]
    ?? "\(Context.packageDirectory)/../build/ghostty-vt/\(flavor)"

let package = Package(
    name: "WorkbenchHost",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../BenchKit"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
    ],
    targets: [
        .target(
            name: "CHostTerminal",
            cSettings: [.define("GHOSTTY_STATIC"), .unsafeFlags(["-I\(terminalLibrary)/include"])],
            linkerSettings: [.unsafeFlags(["-L\(terminalLibrary)/lib"]), .linkedLibrary("ghostty-vt")]),
        .target(
            name: "HostKit",
            dependencies: [
                "CHostTerminal",
                .product(name: "BenchKit", package: "BenchKit"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "workbench-host",
            dependencies: ["HostKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "HostKitTests",
            dependencies: ["HostKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
