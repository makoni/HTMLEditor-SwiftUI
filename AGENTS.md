# Agent Instructions

Guidance for AI coding agents working in this repository.

## Build and test

- The package root is a SwiftPM package for macOS 13+ defined in `Package.swift` (Swift tools 6.0).
- Build the library with `swift build`.
- Run the full package test suite with `swift test`.
- Run a single test with `swift test --filter 'testEmptyHTML'`. Replace the filter with any `@Test` function name from `Tests/HTMLEditor-SwiftUITests/`.
- Run the benchmark executable with `swift run HTMLEditorBenchmarks`. Point it at a real document with `HTML_EDITOR_BENCHMARK_HTML=/path/to/file.html swift run HTMLEditorBenchmarks`; without it a synthetic sample is generated.
- The demo app is a separate macOS Xcode project. Build it with `xcodebuild -project HTMLEditorDemoApp/HTMLEditor-Demo.xcodeproj -scheme HTMLEditor-Demo -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`.

## High-level architecture

### SwiftUI/AppKit bridge

- `Sources/HTMLEditor/HTMLEditor.swift` is the `NSViewRepresentable` that wraps an `NSScrollView` containing a custom `AppearanceAwareTextView` (an `NSTextView` subclass). The bound `html` string is the source of truth between SwiftUI and AppKit.
- `HTMLEditor.Coordinator` owns all runtime state: `previousText`, `documentVersion`, `lastVisibleRange`, plan caches, highlight coverage, and roughly eight cancellable `Task` handles. `textDidChange` is the busiest entry point — it classifies the edit, remaps coverage, invalidates caches, and schedules repaint work.
- The `Coordinator` implementation is split across three extension files; add new coordinator behavior to the matching one rather than back into `HTMLEditor.swift`:
  - `HTMLEditorCoordinatorLifecycle.swift` — full-document highlighting, binding sync, appearance/theme changes, layout policy.
  - `HTMLEditorCoordinatorViewport.swift` — visible-range highlighting, scroll debouncing, scroll-idle mode, viewport prewarm, range-plan cache.
  - `HTMLEditorCoordinatorEditing.swift` — two-phase repaint during typing (immediate local pass plus a coalesced catch-up pass).

### Highlighting engine

- `HTMLSyntaxHighlighterPlanBuilder.swift` holds the scanner: a UTF-16 state machine (`text`, `tagName`, `insideTag`, `quotedAttributeValue(quote)`, …) that walks the document in 512-unit chunks and emits `HighlightSpan` values tagged `tag`, `attributeName`, or `attributeValue`.
- `HTMLSyntaxHighlighterPlanner.swift` is an `actor` with a two-level LRU cache: range plans (cap 24) and chunk results (cap 192), both keyed by document ID, text length, range, and a sampled fingerprint. Chunks that both start and end in the `.text` state are marked context-independent and can be reused even when the incoming scanner state differs. Length-changing edits shift downstream cache entries instead of clearing everything.
- `HTMLSyntaxHighlighter.swift` applies plans. `highlight(html:theme:)` is the public synchronous full-document pass; `highlightRange(in:range:theme:expandedRange:)` is the public incremental path. Internally the coordinator uses the async planner-backed variants.
- Highlighting is applied as **temporary attributes on `NSLayoutManager`**, not as attributes on `NSTextStorage`. This keeps undo intact and avoids re-entrant `textDidChange`. Only the base font/foreground live in text storage. Do not "simplify" this into direct text-storage attribute writes.

### Policies and support types

- `HTMLEditorPolicies.swift` centralizes every threshold and delay. The size boundaries are `HTMLSyntaxHighlighter.maxHighlightLength` (50 000 UTF-16 units) and 150 000, which select three runtime modes: full semantic highlighting, viewport-first highlighting, and a conservative large-file mode that can drop to `tagsOnly` detail with delayed full-detail recovery. Tune behavior here rather than scattering magic numbers through the coordinator.
- `HTMLEditorHighlightCoverage.swift` tracks clean/dirty 256-unit blocks in `IndexSet`s so repeated scrolling does not re-highlight settled regions.
- `HTMLEditorVisibleHighlightState.swift` remaps the currently displayed plan across an edit, with explicit lower/upper-bound affinity at the edit boundaries, and tracks the accumulated dirty range.
- `HTMLEditorStructuralRanges.swift` expands a dirty range outward to hard HTML boundaries (`<`, `>`, quotes, whitespace) so a repaint never starts in the middle of a tag.
- `HTMLEditorTheme.swift` and `HTMLEditorColorScheme.swift` isolate styling. Appearance changes flow through `AppearanceAwareTextView.viewDidChangeEffectiveAppearance()` and `theme.current(for: NSApp.effectiveAppearance)`.
- `HTMLEditorBenchmarkSupport.swift` backs the `HTMLEditorBenchmarks` executable target and is part of the shipped library module.
- `HTMLEditorDemoApp/` is a separate demo app that imports the package as `import HTMLEditor` and is the quickest place to inspect UI behavior or theme changes interactively.

## Key conventions

- This repository is macOS-only. `Package.swift` sets `.macOS(.v13)`, and every library source file is wrapped in `#if os(macOS)`.
- The library product is named `HTMLEditor-SwiftUI`, but the module target imported from Swift code is `HTMLEditor`.
- Preserve the `isUpdatingFromHighlighting` guard. It prevents recursive `textDidChange` loops while attributed text is being reapplied.
- Preserve the `awaitingLocalBindingEcho` / `displayedTextIdentity` pair in `shouldApplyExternalUpdate(incomingHTML:)`. It stops a local edit from bouncing back through the SwiftUI binding and triggering a redundant full re-highlight.
- Prefer incremental or visible-range highlighting over full re-highlighting on every keystroke. Performance-sensitive changes usually belong in `Coordinator.highlightVisibleRange(...)`, `Coordinator.scheduleDirtyBlockHighlightAfterEdit(...)`, or `HTMLHighlightPlanner`.
- Every scheduled `Task` captures `documentVersion` and re-checks it after its `await` before touching the view. Keep that pattern when adding async work; stale results must be discarded, not applied.
- All ranges are UTF-16 (`NSRange`) based. Use `utf16.count` / `NSString.length`, never `String.count`.
- When changing theme behavior, keep light and dark support together through `HTMLEditorTheme` instead of patching colors directly in the editor view.
- Tests use the Swift Testing framework (`import Testing`, `@Test`) rather than XCTest, and are split by concern: policy thresholds, coverage bookkeeping, visible-highlight remapping, planner caching, scanner correctness, and coordinator editing behavior. Shared helpers live in `TestSupport.swift`. Existing tests are mostly regression tests for crashes, invalid `NSRange` handling, empty input, cache bounds, and large HTML payloads.
- AppKit objects used by the editor are not naturally Sendable. If you touch concurrency, keep UI mutation on the main actor and be deliberate about `Task` and `MainActor.run` handoffs.

## Known gaps

- The scanner recognizes only three roles: tags, attribute names, and attribute values. Comments, DOCTYPE, `<script>`/`<style>` bodies, and HTML entities are not distinguished.
