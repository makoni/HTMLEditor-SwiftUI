# Copilot Instructions

## Build and test

- The package root is a SwiftPM package for macOS 13+ defined in `Package.swift`.
- Build the library with `swift build`.
- Run the full package test suite with `swift test`.
- Run a single test with `swift test --filter 'testEmptyHTML'`. Replace the filter with any `@Test` name from `Tests/HTMLEditor-SwiftUITests/HTMLEditor_SwiftUITests.swift`.
- The demo app is a separate macOS Xcode project. Build it with `xcodebuild -project HTMLEditorDemoApp/HTMLEditor-Demo.xcodeproj -scheme HTMLEditor-Demo -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`.
- At the current baseline, `swift build` and `swift test` fail under Swift 6 concurrency checking because `Sources/HTMLEditor/HTMLEditor.swift` captures non-Sendable AppKit state in `Task { @MainActor ... }` closures. Treat that as existing debt unless your change is specifically addressing it.

## High-level architecture

- `Sources/HTMLEditor/HTMLEditor.swift` is the SwiftUI/AppKit bridge. `HTMLEditor` is an `NSViewRepresentable` that wraps an `NSScrollView` containing a custom `NSTextView`, and the bound `html` string is the source of truth between SwiftUI and AppKit.
- `HTMLEditor.Coordinator` owns edit handling, scroll observation, and syntax refresh scheduling. It tracks `previousText`, `lastVisibleRange`, and `highlightedRanges`, debounces scroll-driven work with a short timer, and clears cached highlight coverage after major edits.
- `Sources/HTMLEditor/HTMLSyntaxHighlighter.swift` contains the highlighting engine. `highlight(html:theme:)` does the full-document pass used for initial load and theme changes. `highlightRange(in:range:theme:expandedRange:)` is the incremental path used for visible text updates.
- Highlighting is intentionally performance-biased. Very large HTML documents fall back to basic styling, and normal editing/scrolling only re-highlights the visible range plus a small buffer instead of the whole document.
- `Sources/HTMLEditor/HTMLEditorTheme.swift` and `Sources/HTMLEditor/HTMLEditorColorScheme.swift` isolate styling. Appearance changes flow through `AppearanceAwareTextView.viewDidChangeEffectiveAppearance()` and `theme.current(for: NSApp.effectiveAppearance)`.
- `HTMLEditorDemoApp/` is a separate demo app that imports the package as `import HTMLEditor` and is the quickest place to inspect UI behavior or theme changes interactively.

## Key conventions

- This repository is macOS-only. `Package.swift` sets `.macOS(.v13)`, and the library source files are wrapped in `#if os(macOS)`.
- The library product is named `HTMLEditor-SwiftUI`, but the module target imported from Swift code is `HTMLEditor`.
- Preserve the `isUpdatingFromHighlighting` guard when changing editor or highlighting logic. It prevents recursive `textDidChange` loops while attributed text is being reapplied.
- Prefer incremental or visible-range highlighting changes over full re-highlighting on every keystroke. Performance-sensitive changes usually belong in `Coordinator.highlightVisibleRange(...)` or `HTMLSyntaxHighlighter.highlightRange(...)`.
- When changing theme behavior, keep light and dark mode support together through `HTMLEditorTheme` instead of patching colors directly in the editor view.
- Tests use the Swift Testing framework (`import Testing`, `@Test`) rather than XCTest. Existing tests are mostly regression tests for crashes, invalid `NSRange` handling, empty input, and large HTML payloads.
- AppKit objects used by the editor are not naturally Sendable. If you touch concurrency in `HTMLEditor.swift`, keep UI mutation on the main actor and be deliberate about `DispatchQueue` and `Task` handoffs.
