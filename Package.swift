// swift-tools-version:5.9
import PackageDescription

// All dependencies live in Vendor/ at a fixed version, so the app builds offline and never
// changes underneath you. See docs/ARCHITECTURE.md.
let package = Package(
    name: "xTool",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "xTool", targets: ["XTool"]),
    ],
    dependencies: [
        .package(path: "Vendor/swift-sodium"),     // Argon2id
        .package(path: "Vendor/ZIPFoundation"),    // .xvault backups, Office files
    ],
    targets: [
        // Vault, encryption, files, password rules. No UI.
        .target(
            name: "XToolCore",
            dependencies: [
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/XToolCore"
        ),
        // The app.
        .executableTarget(
            name: "XTool",
            dependencies: [
                "XToolCore",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/XTool"
        ),
        // Core tests: a plain executable, see Tests/XToolCoreTests/main.swift. Run with Scripts/run_tests.sh.
        .executableTarget(
            name: "XToolCoreTests",
            dependencies: ["XToolCore", .product(name: "ZIPFoundation", package: "ZIPFoundation")],
            path: "Tests/XToolCoreTests"
        ),
    ]
)
