// swift-tools-version: 6.2
import PackageDescription

let package = Package(
	name: "Spike",
	platforms: [.macOS("27.0")],
	targets: [
		.binaryTarget(name: "StwEngineFFI", path: "../build/StwEngineFFI.xcframework"),
		.executableTarget(name: "SpikeApp", dependencies: ["StwEngine"]),
		.target(
			name: "StwEngine",
			dependencies: ["StwEngineFFI"],
			swiftSettings: [.swiftLanguageMode(.v5)],
			linkerSettings: [.linkedLibrary("sqlite3")],
		),
	],
)
