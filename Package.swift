// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SongSort",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "SongSort", targets: ["SongSort"]),
    ],
    targets: [
        .executableTarget(
            name: "SongSort",
            path: "Sources/SongSort",
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "SongSortTests",
            dependencies: ["SongSort"],
            path: "Tests/SongSortTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")]
        ),
    ]
)
