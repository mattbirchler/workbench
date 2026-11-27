// swift-tools-version: 6.0
import PackageDescription

// Code shared by Bench on the Mac and the Bench companion on iPhone, and by
// the Workbench host on Linux (see `host/`).
//
// On Linux only the parts with no Apple frameworks are built: the messages,
// pairing, transcripts and the agents' terminal drivers. Everything that
// draws, and what leans on the keychain or Apple's certificate checks, is
// left out there. The list is here, not in each file, so the Mac and iPhone
// builds read exactly as they did.
#if os(Linux)
let appleOnly = [
    "UI",
    "Resources",
    "AppIconChoice.swift",
    "CertificatePin.swift",
    "ChatTiming.swift",
    "DashboardActivity.swift",
    "FeedbackScreenshot.swift",
    "LiveActivity.swift",
    "NotificationKeys.swift",
    "Perf.swift",
    "SecureConnection.swift",
    "TurnChanges.swift",
    "WidgetSnapshot.swift",
]
let resources: [Resource] = []
// CryptoKit's open source twin, with the same names.
let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
]
let kitDependencies: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
#else
let appleOnly: [String] = []
let resources: [Resource] = [.copy("Resources/IconPreviews")]
let dependencies: [Package.Dependency] = []
let kitDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "BenchKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "BenchKit", targets: ["BenchKit"]),
    ],
    dependencies: dependencies,
    targets: [
        .target(name: "BenchKit", dependencies: kitDependencies, exclude: appleOnly, resources: resources),
        // Recorded sessions and the results expected from them are read
        // from the source folder (see Golden.swift), not bundled.
        .testTarget(name: "BenchKitTests", dependencies: ["BenchKit"], exclude: ["Fixtures", "Goldens"]),
    ]
)
