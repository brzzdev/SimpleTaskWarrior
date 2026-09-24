// swiftformat:disable acronyms
import ProjectDescription

// Signing team is read from the environment so it stays out of source control
// (set `TUIST_DEVELOPMENT_TEAM` in your shell profile before `tuist generate`).
// Forks/CI just supply their own; nothing personal is committed.
let developmentTeam = Environment.developmentTeam.getString(default: "")

let baseSettings: SettingsDictionary = [
	"ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
	"ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS": "YES",
	"ENABLE_HARDENED_RUNTIME": "YES",
	// Off so the SwiftLint build phase can read the whole source tree. This is a
	// build-time setting only — it does not affect the shipped app's hardened
	// runtime, signing, or runtime App Sandbox.
	"ENABLE_USER_SCRIPT_SANDBOXING": "NO",
	"SWIFT_VERSION": "6.0",
]

// Sign the app with Developer ID (manual): it needs no Xcode-registered account
// or provisioning profile and gives a stable code identity, which is what
// notarization requires. Ad-hoc signing — what Tuist defaults the app target to
// via CODE_SIGN_IDENTITY[sdk=macosx*]="-" — has no stable identity. These live
// at the target level (overriding that default), and the sdk-specific key must
// be set too or it wins on macOS.
var signingSettings: SettingsDictionary = [
	// Tuist defaults this to "AccentColor" at the target level, which makes
	// actool warn about a missing AccentColor asset (we ship no asset catalog).
	"ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
	"AD_HOC_CODE_SIGNING_ALLOWED": "NO",
	"CODE_SIGN_IDENTITY": "Developer ID Application",
	"CODE_SIGN_IDENTITY[sdk=macosx*]": "Developer ID Application",
	"CODE_SIGN_STYLE": "Manual",
]
if !developmentTeam.isEmpty {
	signingSettings["DEVELOPMENT_TEAM"] = .string(developmentTeam)
}

let project = Project(
	name: "SimpleTaskWarrior",
	packages: [
		.package(path: "."),
	],
	settings: .settings(base: baseSettings),
	targets: [
		.target(
			name: "SimpleTaskWarrior",
			destinations: .macOS,
			product: .app,
			bundleId: "dev.brzz.SimpleTaskWarrior",
			deploymentTargets: .macOS("27.0"),
			infoPlist: .extendingDefault(
				with: [
					"CFBundleDisplayName": "SimpleTaskWarrior",
					"CFBundleName": "SimpleTaskWarrior",
					"LSApplicationCategoryType": "public.app-category.productivity",
				],
			),
			sources: ["AppHost/**"],
			// Globbed, not bare: Tuist keeps a bare directory resource only if
			// its extension is a known folder type or LaunchServices knows the
			// UTI. `.icon` is not a known folder type, so a bare path rides on
			// the machine's UTI database alone — and a runner without it drops
			// the icon, failing actool. Globbing collapses the contents back
			// into the opaque bundle, consulting no UTI database (needs
			// Tuist >= 4.58).
			resources: ["AppHost/AppIcon.icon/**"],
			entitlements: "AppHost/SimpleTaskWarrior.entitlements",
			scripts: [
				.pre(
					script: """
						export PATH="$PATH:/opt/homebrew/bin"
						# Missing Mint fails the build, so a green build has always linted.
						if ! which mint >/dev/null; then
							echo "error: mint not installed — run 'just tools'"
							exit 1
						fi
						# `--config` makes a failed `parent_config` fetch fatal; see `just lint`.
						mint run swiftlint --quiet --strict --config .swiftlint.yml
						""",
					name: "SwiftLint",
					basedOnDependencyAnalysis: false,
				),
			],
			dependencies: [
				.package(product: "App"),
				.package(product: "IssueReporting"),
			],
			settings: .settings(base: signingSettings),
		),
	],
	schemes: [
		.scheme(
			name: "SimpleTaskWarrior",
			shared: true,
			buildAction: .buildAction(targets: ["SimpleTaskWarrior"]),
			testAction: .testPlans(["SimpleTaskWarrior.xctestplan"]),
			runAction: .runAction(executable: "SimpleTaskWarrior"),
		),
	],
)
