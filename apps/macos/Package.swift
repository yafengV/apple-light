// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "ShipiOS",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "ShipiOS", targets: ["ShipiOS"])],
  dependencies: [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
    .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
  ],
  targets: [
    .executableTarget(
      name: "ShipiOS",
      dependencies: ["SwiftTerm", .product(name: "Markdown", package: "swift-markdown")]),
    .testTarget(name: "ShipiOSTests", dependencies: ["ShipiOS"], resources: [.copy("Fixtures")]),
  ]
)
