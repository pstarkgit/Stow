// swift-tools-version:6.3
import PackageDescription

// Swift 6.3.3 (released 2026-06-30). Both siblings are still pinned at 5.9, so
// this is a deliberate family divergence taken on a NEW package rather than a
// migration paid three times later.
//
// tools-version 6.x means Swift 6 language mode is the DEFAULT for every target
// here: strict data-race checking is on. That is the point, not a side effect.
// RevealCoordinator mutates @MainActor spacer state from a background
// DispatchSourceTimer, and Swift 5 mode would have shipped that as a race.
let package = Package(
    name: "Stow",
    platforms: [
        // .v14 held deliberately. Nothing in the design needs a newer API and
        // raising it would cut off Sonoma for no gain.
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Stow",
            path: "Sources/Stow"
        ),
        .testTarget(
            name: "StowTests",
            dependencies: ["Stow"],
            path: "Tests/StowTests"
        ),
    ]
)
