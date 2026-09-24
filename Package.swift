// swift-tools-version:6.4

import PackageDescription

let package = Package(
	name: "SimpleTaskWarrior",
	platforms: [.macOS(.v27)],
	products: [
		.library(name: "App", targets: ["App"]),
	],
	dependencies: [
		.package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.2"),
		// Direct because the app host detects a test run through `TestContext`.
		.package(url: "https://github.com/pointfreeco/swift-issue-reporting", from: "2.1.1"),
		// Direct because MemberImportVisibility wants the declaring module imported
		// directly, not reached as TCA's re-export.
		.package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.10.1"),
	],
	targets: [
		// Assembled into `Engine/build/` by `just engine`, which also regenerates the
		// `Engine` target's sources: the UniFFI bindings, committed so a diff shows
		// any change to the engine's surface.
		.binaryTarget(name: "EngineFFI", path: "Engine/build/EngineFFI.xcframework"),
		.target(
			name: "Engine",
			dependencies: [
				"EngineFFI",
			],
			linkerSettings: [
				// The engine links the system SQLite rather than bundling its own.
				.linkedLibrary("sqlite3"),
			],
		),

		.target(name: "Taskrc"),
		.target(
			name: "Models",
			dependencies: [
				"Taskrc",
			],
		),

		.target(
			name: "BookmarkClient",
			dependencies: [
				.product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
			],
		),
		.target(
			name: "ReplicaClient",
			dependencies: [
				"Engine",
				"Models",
				.product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
			],
		),
		.target(
			name: "TaskrcClient",
			dependencies: [
				"Taskrc",
				.product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
			],
		),

		.target(
			name: "ReplicaFeature",
			dependencies: [
				"BookmarkClient",
				"Models",
				"ReplicaClient",
				"Taskrc",
				"TaskrcClient",
				.product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
				.product(name: "Sharing", package: "swift-sharing"),
			],
		),
		.target(
			name: "App",
			dependencies: [
				"BookmarkClient",
				"ReplicaFeature",
				.product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
			],
		),

		// A regular target, not a test target: a test target cannot depend on a
		// test target. Nothing in the app graph depends on it, so it is never
		// linked into the shipped binary.
		.target(
			name: "TestSupport",
			dependencies: [
				"Models",
				"Taskrc",
			],
		),

		// The thin clients get no test targets: they are verified by running the app.
		.testTarget(
			name: "ModelsTests",
			dependencies: [
				"Models",
				"TestSupport",
			],
		),
		.testTarget(
			name: "ReplicaFeatureTests",
			dependencies: [
				"ReplicaFeature",
				"TestSupport",
			],
		),
		.testTarget(
			name: "TaskrcTests",
			dependencies: [
				"Taskrc",
				"TestSupport",
			],
		),
	],
)

// Not the engine's generated bindings, which break under `InternalImportsByDefault`.
for target in package.targets where target.type != .binary && target.name != "Engine" {
	target.swiftSettings = target.swiftSettings ?? []
	target.swiftSettings?.append(contentsOf: [
		.enableUpcomingFeature("ExistentialAny"),
		.enableUpcomingFeature("ImmutableWeakCaptures"),
		.enableUpcomingFeature("InferIsolatedConformances"),
		.enableUpcomingFeature("InternalImportsByDefault"),
		.enableUpcomingFeature("MemberImportVisibility"),
		.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
		.treatAllWarnings(as: .error),
	])
}
