import PackageDescription

let package = Package(
    name: "WebSocket",
    dependencies: [
        .Package(url: "https://github.com/slimane-swift/HTTPCore.git", majorVersion: 0, minor: 1),
        .Package(url: "https://github.com/Zewo/POSIX.git", majorVersion: 0, minor: 14),
    ]
)
