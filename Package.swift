// swift-tools-version: 6.2
import PackageDescription

// DropChat is a Droplet for Droppy.
//
// Targets:
//  - DropChatCore: Foundation-only engine (providers, agent loop, MCP, web,
//    skills, attachments, storage). No DroppyKit, no SwiftUI, unit-testable.
//  - DropChat: the droplet itself (DroppyKit surfaces, SwiftUI, AppKit).
//  - DropChatHarness: the DroppyKit harness entry (`droppykit run`).
//
// Only local targets may be added: `droppykit build` links the droplet from
// this package's own modules, so a third-party package would be missing from
// the shipped bundle.
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "DropChat",
    platforms: [.macOS(.v14)],
    products: [
        // A droplet is a loadable bundle, so its product is a dynamic library.
        // Never static: Droppy already carries DroppyKit.
        .library(name: "DropChat", type: .dynamic, targets: ["DropChat"])
    ],
    dependencies: [
        .package(url: "https://gitlab.com/droppyformac1/droppykit.git", from: "1.22.0")
    ],
    targets: [
        .target(
            name: "DropChatCore",
            swiftSettings: swift5
        ),
        .target(
            name: "DropChat",
            dependencies: [
                "DropChatCore",
                .product(name: "DroppyKit", package: "droppykit")
            ],
            swiftSettings: swift5
        ),
        .executableTarget(
            name: "DropChatHarness",
            dependencies: [
                "DropChat",
                .product(name: "DroppyKitHarness", package: "droppykit")
            ],
            swiftSettings: swift5
        ),
        .testTarget(
            name: "DropChatCoreTests",
            dependencies: ["DropChatCore"],
            swiftSettings: swift5
        )
    ]
)
