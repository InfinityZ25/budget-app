// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BudgetApp",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BudgetApp", targets: ["BudgetApp"])
    ],
    targets: [
        .executableTarget(name: "BudgetApp")
    ]
)
