# Contributing

Install macOS 13 or later and the Command Line Tools (`xcode-select --install`), then clone the repository. Build and test with:

```sh
swift build
swift test
scripts/build-app.sh
```

When working in parallel, use a separate scratch directory to avoid build locks, for example `swift build --scratch-path .build-yourname` and `swift test --scratch-path .build-yourname` (`KEYSHIFT_SCRATCH_PATH=.build-yourname scripts/build-app.sh` for the app bundle).

Code layout: `Sources/Core` is pure logic (key and rule model, remapping engine; no AppKit or CoreGraphics event APIs), `Sources/Config` the YAML format, presets, Karabiner importer and conflict detection, `Sources/System` the macOS integration (event tap, context providers, actions, permissions) and `Sources/App` the menu bar app, settings UI and CLI. Keep logic testable in `Core`/`Config`; see [docs/TESTING.md](docs/TESTING.md).

The config format is specified in [docs/CONFIG.md](docs/CONFIG.md); change the document together with the parser. Presets live in `Sources/Config/Presets/` (also reachable through the `Presets/` symlink) and must stay valid against it.

Write clear, idiomatic Swift. Mark UI code `@MainActor`.

Open an issue to discuss substantial changes, then submit a pull request describing the change and its tests. Keep changes focused and address review feedback. Contributions are accepted under GPL-3.0-only: inbound licensing matches the project's outbound license.
