# Repository Guidelines

## Project Structure & Module Organization

MichiNavi (display name: つぼナビ) is an iOS 26+ navigation app using Apple frameworks, with no external package dependencies.

- `MichiNavi/App/`: app entry points and lifecycle.
- `MichiNavi/Core/`: routing, location, guidance, persistence, and shared state.
- `MichiNavi/Phone/`: SwiftUI screens; `MichiNavi/CarPlay/`: UIKit/CarPlay presentation.
- `MichiNavi/Assets.xcassets/`, `en.lproj/`, and `ja.lproj/`: assets and localization.
- `MichiNaviTests/`: tests and `SyntheticRoute` fixtures.
- `docs/`: support/privacy pages; `Materials/appstore/`: marketing assets.

Keep navigation state in `NavigationController.shared` and guidance logic out of UI layers. Core must not import SwiftUI or CarPlay. Source and test folders synchronize automatically; do not edit `project.pbxproj` to register files. Consult `CLAUDE.md` for detailed architecture and pitfalls.

## Build, Test, and Development Commands

Use Xcode with an iOS 26+ simulator runtime:

```bash
xed . # Open Xcode; select a simulator and Run.
xcodebuild -scheme MichiNavi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -scheme MichiNavi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
xcodebuild -scheme MichiNavi -showdestinations
```

`build` compiles the app; `test` runs the suite. Use `-showdestinations` to find an installed compatible simulator. Device builds require signing with the CarPlay maps entitlement.

## Coding Style & Naming Conventions

Use four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` members. Match surrounding Swift style; no formatter or linter is configured. Write Japanese comments explaining why.

Use `String(localized:)` with Japanese keys and update both localization files; App Intents use their native localization types. Prefer interpolation over concatenation. Route distance/time display through `Formatters`.

## Testing Guidelines

Use Swift Testing (`@Test`, `#expect`, `try #require`) in `<Feature>Tests.swift`. Add `@MainActor` when exercising actor-isolated app types. Use `SyntheticRoute` for deterministic routing tests; avoid force unwraps.

Test behavior and boundary conditions. Verify new regression tests fail when the relevant logic is deliberately broken, then restore it and rerun. No numeric coverage threshold is configured.

## Commit & Pull Request Guidelines

Follow history: one gitmoji plus a concise Japanese description, e.g. `🐛 周回ルートの出発時に即到着するのを直す`.

PRs should describe the problem and resulting behavior, link relevant issues, report build/test results, and include screenshots for UI changes. Identify iPhone/CarPlay verification performed.

## Configuration & Privacy

Keep signing credentials and secrets untracked. Preserve bundle ID `jp.hibiki.michinavi`; changing it affects provisioning and stored data. Update `docs/privacy.md` when location permissions, storage, or data sharing change.
