// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AIVideoAssistant",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AIVideoAssistant", targets: ["AIVideoAssistant"])
    ],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.9.0"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
    ],
    targets: [
        .executableTarget(
            name: "AIVideoAssistant",
            dependencies: [
                "Alamofire",
                "KeychainAccess",
            ],
            path: "Sources"
        )
    ]
)
