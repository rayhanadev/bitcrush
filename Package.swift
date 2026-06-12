// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "plunk",
  platforms: [.macOS(.v14)],
  targets: [
    // Pure, testable logic: models, the ffmpeg filtergraph builder, cache keys.
    .target(
      name: "PlunkKit",
      path: "Sources/PlunkKit",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // The SwiftUI app: services that shell out to yt-dlp/ffmpeg, the audio engine, views.
    .executableTarget(
      name: "Plunk",
      dependencies: ["PlunkKit"],
      path: "Sources/Plunk",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "PlunkKitTests",
      dependencies: ["PlunkKit"],
      path: "Tests/PlunkKitTests",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
