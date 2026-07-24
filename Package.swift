// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuickRecorderRecordingCore",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "RecordingCore", targets: ["RecordingCore"])
    ],
    targets: [
        .target(name: "RecordingCore", path: "QuickRecorder/RecordingCore"),
        .testTarget(name: "RecordingCoreTests", dependencies: ["RecordingCore"], path: "Tests/RecordingCoreTests")
    ]
)
