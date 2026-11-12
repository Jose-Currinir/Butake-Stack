// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ButakeStack",
    defaultLocalization: "es",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "ButakeStack", targets: ["ButakeStack"])],
    // Themes and text size shared with Butake Git.
    dependencies: [.package(url: "https://github.com/Jose-Currinir/Butake-Design.git", from: "1.0.0")],
    targets: [
        .executableTarget(name: "ButakeStack", dependencies: [.product(name: "ButakeDesign", package: "Butake-Design")], resources: [.process("Resources"), .copy("Logos")]),
        .testTarget(name: "ButakeStackTests", dependencies: ["ButakeStack"])
    ],
    swiftLanguageModes: [.v6]
)
