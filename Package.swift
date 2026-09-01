// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "swp",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        // Everything that can be reasoned about without a terminal: the process
        // and socket scanners, the query language, formatting and the killer.
        // No dependency on the executable target, so it stays testable on its own.
        .target(
            name: "swpCore",
            path: "Sources/swpCore"
        ),
        .executableTarget(
            name: "swp",
            dependencies: [
                .target(name: "swpCore"),
            ],
            path: "Sources/swp"
        ),
        .testTarget(
            name: "swpCoreTests",
            dependencies: [
                .target(name: "swpCore"),
            ],
            path: "Tests/swpCoreTests"
        ),
        .testTarget(
            name: "swpTests",
            dependencies: [
                .target(name: "swp"),
                .target(name: "swpCore"),
            ],
            path: "Tests/swpTests"
        ),
    ]
)
