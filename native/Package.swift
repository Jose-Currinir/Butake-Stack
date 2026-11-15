// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ButakeStack",
    defaultLocalization: "es",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "ButakeStack", targets: ["ButakeStack"])],
    // Themes and text size shared with Butake Git.
    dependencies: [
        .package(url: "https://github.com/Jose-Currinir/Butake-Design.git", from: "1.0.0"),
        // Embedded terminal of the SSH plugin (MIT). Pinned: updates are reviewed by hand; 1.12+
        // adds a Metal renderer whose shader needs the separate Metal Toolchain to build.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.11.2"),
    ],
    targets: [
        .executableTarget(name: "ButakeStack", dependencies: [.product(name: "ButakeDesign", package: "Butake-Design"), .product(name: "SwiftTerm", package: "SwiftTerm")], resources: [.process("Resources"), .copy("Logos"), .copy("FileIcons")]),
        .testTarget(name: "ButakeStackTests", dependencies: ["ButakeStack"])
    ],
    swiftLanguageModes: [.v6]
)
