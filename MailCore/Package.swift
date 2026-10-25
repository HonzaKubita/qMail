// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MailCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MailCore", targets: ["MailCore"]),
    ],
    targets: [
        .target(name: "MailCore"),
        // Small command-line tool for checking connectivity to real servers (greeting/capabilities only).
        .executableTarget(name: "MailProbe", dependencies: ["MailCore"]),
        .testTarget(name: "MailCoreTests", dependencies: ["MailCore"]),
    ]
)
