// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhonePhotoBackup",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PhonePhotoBackup", targets: ["PhonePhotoBackup"]),
        .library(name: "BackupCore", targets: ["BackupCore"]),
    ],
    targets: [
        .target(name: "BackupCore"),
        .executableTarget(name: "PhonePhotoBackup", dependencies: ["BackupCore"]),
        .testTarget(name: "BackupCoreTests", dependencies: ["BackupCore"]),
    ]
)
