// swift-tools-version:6.1
import PackageDescription

let package = Package(
	name: "KeyboardShortcuts",
	defaultLocalization: "en",
	platforms: [
		.macOS(.v10_15)
	],
	products: [
		.library(
			name: "KeyboardShortcuts",
			targets: [
				"KeyboardShortcuts"
			]
		)
	],
	targets: [
		.target(
			name: "KeyboardShortcuts",
			swiftSettings: [
				.swiftLanguageMode(.v5)
			]
		)
		// Vendored patch (branch `spm`): the upstream test target was dropped
		// together with its Tests/ directory; it needed app-host machinery.
	]
)
