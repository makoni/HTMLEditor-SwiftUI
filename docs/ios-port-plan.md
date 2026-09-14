# iOS / iPadOS support — plan

Working document. `[ ]` todo, `[x]` done, `[~]` in progress, `[-]` deliberately
skipped (say why inline).

Goal: `HTMLEditor` on iOS and iPadOS, with the TextKit 2 performance work
intact — not re-derived, not forked.

> **Revision note.** This plan was reviewed twice, and the first draft was
> wrong in several places that changed the size of the job. Everything below
> is either read out of the source, read out of the iOS 26.5 SDK headers, or
> measured with a probe on a simulator; claims that are still assumptions say
> so. Corrections from that review are marked **[R]** where they overturn
> something the first draft asserted.

---

## Status — implemented, measured, green

All phases done. Both platforms build; the package's tests pass on macOS (69)
and on an iOS simulator (31 + 4 performance tests); the consuming app builds on
macOS and iOS and its 22 UI tests still pass.

### What the numbers say

Measured on an iPhone 17 Pro simulator (iOS 26.5) against a **100 000-line,
25.6 MB** document of GitHub-shaped markup, inserting **in the middle**:

| | 200 lines | 100 000 lines |
|---|---|---|
| keystroke | 0.188 ms | **0.240 ms** |
| open | 2.47 ms | 5.19 ms |
| one-paragraph scan | — | 0.019 ms |
| paragraphs TextKit asked for | — | **57 of 100 000** |

The keystroke is the answer to the question this port had to answer: it is
**flat**, and 66× inside one 60 Hz frame. macOS is the same shape
(0.341 → 0.354 ms).

### The measurement that was wrong first

The first run said 450 ms per keystroke and 100 008 paragraphs. That was the
harness, not the editor: a text view with no window has unbounded height, so
its "viewport" is the whole document. The same view in a 600 pt window asks for
164 paragraphs and costs 0.42 ms. `HTMLEditorLargeDocumentTests` now builds a
real window, and says so in a comment — it is an easy trap to fall into twice.

### What running it in the app exposed

The package was fast from the first build; the **host layout** was not. The
editor was given `contentMinHeight = 100` on iOS — a leftover from when iOS got
a stub `TextEditor` with no highlighting, where 100 pt was a reasonable size for
a plain text box. With a real source editor it is four visible lines, and the
view is barely tappable. Now 420 pt on iPhone and 600 on iPad.

Keeping `isScrollEnabled = true` is what makes a tall frame free: the editor
scrolls itself, so TextKit 2 still lays out only the visible part. Turning
scrolling off and growing to fit — the usual remedy for a text view inside a
`Form` — is what would have made open time proportional to document size again.

---

## 0. How the package is built today

18 files, 4 264 lines in `Sources/HTMLEditor`, **every one wrapped in
`#if os(macOS)`**. No UIKit anywhere, no iOS conditional anywhere: the platform
split does not exist yet, so nothing has to be un-picked.

Four layers — **[R]** this taxonomy is the corrected one; the first draft
omitted two files outright and misfiled two more:

| Layer | Files | Lines | On iOS |
|---|---|---|---|
| **Scan core** | `HTMLSyntaxHighlighterPlanBuilder`, `…Planner` | 845 | portable; Foundation only |
| **Plan types + theme application** | `HTMLSyntaxHighlighter` | 250 | **must be split** — see 0.1 |
| **TextKit 2 path** | `HTMLEditorTextKitSurface`, `HTMLEditorParagraphHighlighting` | 333 | ports nearly verbatim |
| **Push / TextKit 1 machinery** | `HTMLEditorCoordinatorViewport`, `HTMLEditorCoordinatorEditing`, `HTMLEditorVisibleHighlightState`, `HTMLEditorHighlightCoverage`, `HTMLEditorStructuralRanges`, most of `HTMLEditorPolicies` | ~1 280 | **excluded** — §2 |
| **Shell** | `HTMLEditor`, `…Theme`, `…ColorScheme`, `…Lifecycle`, `…Signposts`, `…AutoTypeDiagnostic`, `…BenchmarkSupport` | ~1 470 | rewritten / excluded per file |

Rough budget: ~1 000 lines port for free, ~1 280 are excluded, ~260 are the
TextKit 2 path that carries the performance, and the shell is new code.

### 0.1 The scan core is portable — but it does not stand alone **[R]**

`HTMLSyntaxHighlighterPlanBuilder` and `…Planner` use only `NSRange`,
`NSMaxRange`, `NSNotFound`, `NSString`, `NSIntersectionRange`. `import AppKit`
in them is gratuitous.

But the first draft's claim — *"those five files compile for iOS with no other
change"* — **is false, and was falsified by actually trying it**:

- `HighlightPlan`, `HighlightSpan` and `HighlightRole` are declared in
  `HTMLSyntaxHighlighter.swift:8-22`, a file the first draft left out of the
  taxonomy entirely. Every scan file depends on those types, and that file is
  genuinely AppKit-bound: `applyThemeBase(to: NSTextView, …)` (`:199`),
  `colour(…) -> NSColor` (`:237`), `highlight(html:theme:) -> NSAttributedString`
  (`:25`).
- `HTMLEditorHighlightCoverage.swift:109` pulls in
  `HTMLEditorVisibleHighlightState` (184 lines) — also absent from the first
  draft.
- `HTMLEditorPolicies.swift:80` and `HTMLEditorStructuralRanges.swift:4` are
  `extension HTMLEditor { … }` — extensions of the `NSViewRepresentable`
  itself. They cannot compile on iOS until `HTMLEditor` exists there, which is
  Phase 1. **The first draft's phase order was physically impossible.**

So Phase 0 is a small refactor, not an import swap. That refactor is worth
doing on its own terms: document-size policy and HTML structural boundaries
have no business hanging off a view type.

### 0.2 TextKit 2 is the same framework on both platforms — verified

Against the iOS 26.5 SDK, and then at runtime on an iPhone 17 simulator:

- `NSTextLayoutManager.h:43`, `NSTextContentManager.h:60` — available from
  **iOS 15**, and `NSTextContentStorageDelegate` with
  `textContentStorage:textParagraphWithRange:` at `NSTextContentManager.h:115-118`
  is **iOS 15.0** too. **[R]** The first draft said 16.
- `UITextView.h:259` — TextKit 2 is the **default** for `UITextView` from
  iOS 16. That is what sets the deployment floor, not the delegate.
- **Runtime probe:** the delegate is called (108 times on a 400-paragraph
  document), TextKit **re-asks** for an edited paragraph on keystroke, and a
  colour change reaches the element. The pull-based design works on iOS.

**[R] The one-way trapdoor has two triggers, not one.** `UITextView.h:273`
names `.layoutManager` **and `.textContainer`'s `.layoutManager`**. Reading
`tv.textContainer` itself is safe; reading `tv.textContainer.layoutManager` is
not.

**[R] `UITextView(usingTextLayoutManager:)`, not `textViewUsingTextLayoutManager(_:)`.**
The class method is `NS_SWIFT_UNAVAILABLE`; in Swift the initializer is the
symmetric counterpart of `NSTextView(usingTextLayoutManager:)`.

### 0.3 The one real API gap

`NSTextView.textContentStorage` exists (`AppKit/NSTextView.h:119`);
**`UITextView` has no such property** — confirmed by compiler error. On iOS:

```swift
textView.textLayoutManager?.textContentManager as? NSTextContentStorage
```

Both accesses already funnel through `HTMLEditorTextKitSurface.resolve(for:)`
and `.textStorage(for:)`, so this is a two-line platform difference.

**[R] But `UITextView.textStorage` is safe to read.** The first draft warned
that it might spring the trapdoor. A probe says otherwise:
`tv.textStorage === contentStorage.textStorage` is `true` and the view stays on
TextKit 2. Going through the content storage is still fine; justifying it by
fallback risk was wrong.

---

## 1. Phase 0 — make the portable parts actually portable

### [ ] 0.1 Unblock the manifest **[R]**

`Sources/HTMLEditorBenchmarks/HTMLEditorBenchmarksMain.swift:1` is
`import AppKit` with **no `#if`**, and it is an `.executableTarget` with a
product in `Package.swift:14`. Adding `.iOS` to `platforms` breaks the package
build before anything else is attempted. Guard or exclude it **first**; the
first draft filed this under Phase 2.

Then: `platforms: [.macOS(.v13), .iOS(.v16)]`.

### [ ] 0.2 Split `HTMLSyntaxHighlighter.swift`

- **stays / moves to the core:** the three plan types, `clippedPlan` (`:51`),
  `filteredPlan` (`:154`), `mergedPlan` (`:166`)
- **moves to the shell:** `applyThemeBase(to:theme:)` (`:199`),
  `colour(for:theme:)` (`:237`), `highlight(html:theme:)` (`:25`), the
  deprecated `highlightRange(in:…)` (`:74`)

### [ ] 0.3 Lift the policy layer out of `extension HTMLEditor`

`HTMLEditorPolicies.swift:80` and `HTMLEditorStructuralRanges.swift:4`. The
enums at `HTMLEditorPolicies.swift:11-67` are already free-standing; the
methods in the extension should join them. Note most of those knobs
(`highlightBudget`, `semanticHighlightDelay`, `shouldUseTwoPhaseEditing`,
`shouldUseScrollIdleMode`, `shouldUseNonContiguousLayout`, …) feed the push
path only; iOS needs `bindingSyncDelay`, `highlightedParagraphLimit` and part
of `editMagnitude`.

### [ ] 0.4 Widen the scan core

Drop `#if os(macOS)`, `import AppKit` → `import Foundation`, in
`HTMLSyntaxHighlighterPlanBuilder`, `…Planner`, and the extracted core of
`HTMLSyntaxHighlighter` + the policy enums. `HTMLEditorSignposts.swift` too —
`import os` is fine on iOS, and `HTMLEditor.swift:115/258` and
`ParagraphHighlighting:29` reference it.

### [ ] 0.5 Run the portable subset of the tests on iOS **[R]**

The first draft said "353 lines against the highlighter plus 75 of support".
The suite is **1 642 lines across 10 files, 6-7 of which import AppKit** —
including `HTMLSyntaxHighlighterTests.swift`, which the draft named as the
proof, and which compares `NSColor` at `:115/160/180`.

Foundation-only today: `HTMLEditorPolicyTests` (280),
`HTMLEditorHighlightCoverageTests` (168),
`HTMLEditorVisibleHighlightStateTests` (102). Those are what can run on a
simulator after 0.4 — ~550 lines, and the first of them needs 0.3 to have
landed. Say that honestly rather than claiming the scan is "proven portable".

`TestSupport.swift:20-51` (`appliedHighlightColour`) is nearly UIFoundation
already on the TK2 branch — reusable for an iOS harness.

---

## 2. iOS is TextKit 2 only

`HTMLEditorCoordinatorViewport` (536), `HTMLEditorCoordinatorEditing` (120),
`HTMLEditorVisibleHighlightState` (184), `HTMLEditorHighlightCoverage` (132)
and `HTMLEditorStructuralRanges` (88) exist to do by hand what TextKit 2 does
itself. Four sites gate on `usesPulledHighlighting`
(`HTMLEditor.swift:286, 325, 352`, `Viewport.swift:8`); `Editing.swift` is
reachable **only** from behind one of them, so it is excluded whole.

macOS must keep all of it: `HTMLEDITOR_TEXTKIT=1` is a documented escape hatch
for TextKit 2's known long-line bugs (`HTMLEditorTextKitSurface.swift:14-16`).

iOS should not carry it: `UITextView` is TextKit 2 by default from iOS 16;
UIKit has no `NSClipView` and `UITextView` *is* its own scroll view, so it
would be a rewrite; and it is the slow path.

### 2.1 **[R]** The layer is not dead under TextKit 2 — it is live and wasted

The first draft said "dead weight". That is wrong, and it matters.
`performFullHighlighting` is called **unconditionally** from
`HTMLEditor.swift:97`, and again from `Lifecycle.swift:40` (external update)
and `:308` (theme change). Under TextKit 2 that path runs
`planner.fullPlan(for: html)` over the whole document (`Lifecycle:152`), then
hands the result to `clearHighlights` and `applyHighlights`, **both of which
are `break` on the `textKit2` case** (`TextKitSurface.swift:73-78`, `:119-126`),
then does coverage bookkeeping nobody reads, then schedules a viewport prewarm
(`:194-204`) whose painting is also a no-op.

So there is a full-document scan per open, per external update and per theme
change on the TK2 path, thrown away.

### [ ] 2.2 Extract a TextKit 2 lifecycle

**[R] This is the work item the first draft was missing**, and without it
Phase 1.3 has nothing to call: `makeUIView` cannot invoke
`performFullHighlighting`, because that function is push-shaped.

What iOS actually needs from `HTMLEditorCoordinatorLifecycle`:
`shouldApplyExternalUpdate`, `scheduleBindingSync`, `flushPendingBindingSync`,
setting the text, restoring selection, `invalidateParagraphHighlighting`. What
it must not drag in: `NSScrollView` viewport restoration (`setBoundsOrigin`,
`reflectScrolledClipView`), the prewarm, the coverage bookkeeping.

Under TK2, opening a document should be: set the text, set the delegate,
invalidate. Nothing else.

This also removes the wasted full scan on macOS. Do it there first, where the
existing tests can catch a regression.

### 2.3 Losing the escape hatch, and making the loss visible

Nothing a user can see is lost — everything `usesPulledHighlighting` disables
is already inert on macOS-TK2, and `highlightedParagraphLimit` lives on the
pull path (`ParagraphHighlighting.swift:51`).

What is lost is the fallback. Rather than keep a push path nobody should take,
make the failure **observable**: `resolve(for:)` currently returns `nil` for
two different reasons ("no layout manager" and "fell back to TextKit 1"). Give
it a third case or a diagnostic so a TK1 fallback on iOS degrades to *plain,
unhighlighted text with a signpost*, not to silence.

### [ ] 2.4 **[R]** `scrollViewDidScroll` must never compile for iOS

`HTMLEditorCoordinatorViewport.swift:6` declares
`@objc func scrollViewDidScroll(_ notification: Notification)`. Its ObjC
selector is byte-identical to `UIScrollViewDelegate.scrollViewDidScroll(_:)`,
which `UITextViewDelegate` inherits. If that file ever reaches an iOS build,
UIKit will call it on every scroll passing a `UIScrollView *` where Swift
expects a bridged `NSNotification` — type confusion, then a crash.

§2 excludes the file, so today this is safe **by coincidence**. Rename the
method and write the constraint down.

---

## 3. Phase 1 — the platform shell

### [ ] 1.1 A typealias layer, not a protocol

Two text-view protocols with different method names, appearance arriving
through different channels, and different scroll ownership: a protocol would be
half no-ops on each platform.

**[R] The first draft's snippet does not compile.** `HTMLEditorColorScheme.swift:21-26`
declares `public let foreground: NSColor` and a `public init`; a public
property cannot have an internal type. The aliases must be public — and that
makes them part of the package's API surface, which is a decision, not a
detail:

```swift
public enum HTMLEditorPlatform {
    #if os(macOS)
    public typealias Colour = NSColor
    public typealias Font = NSFont
    public typealias TextView = NSTextView
    #else
    public typealias Colour = UIColor
    public typealias Font = UIFont
    public typealias TextView = UITextView
    #endif
}
```

Namespaced rather than top-level, so the package does not export
`PlatformColor` into every consumer.

`NSRect` is already `CGRect`. **[R]** `textContainer` is `NSTextContainer?` on
`NSTextView` and non-optional on `UITextView` — `HTMLEditor.swift:59` and `:93`
need the difference.

**Also worth considering:** a small internal adapter enum (not a protocol) over
the five or six genuinely divergent accessors — `text`, `selectedRange`,
`font`/`textColor`/`backgroundColor`, `textContentStorage`. Those are where
`#if` would otherwise spread; one file keeps them together.

### [ ] 1.2 `HTMLEditorTextKitSurface` for iOS

```swift
static func resolve(for textView: HTMLEditorPlatform.TextView) -> HTMLEditorTextKitSurface? {
    #if os(macOS)
    …existing two-case logic…
    #else
    guard let layoutManager = textView.textLayoutManager,
          let contentStorage = layoutManager.textContentManager as? NSTextContentStorage
    else { return nil }   // and see 2.3: distinguish "fell back" from "absent"
    return .textKit2(layoutManager, contentStorage)
    #endif
}
```

`clearHighlights`, `applyHighlights` and `visibleCharacterRange` need no change
on the `textKit2` branch — every type in them is UIFoundation.

### [ ] 1.3 `UIViewRepresentable`

Shorter than `makeNSView`: no `NSScrollView` to configure, and no bounds
observer, because §2 removed the reason for one.

The input-behaviour flags are the most performance-sensitive part of this
phase. The macOS code disables **ten** (`HTMLEditor.swift:48-57`) plus
`isRichText` (`:24`) — **[R]** the first draft said nine and swapped two rows:

| macOS | iOS |
|---|---|
| `isAutomaticLinkDetectionEnabled`, `isAutomaticDataDetectionEnabled` | `dataDetectorTypes = []` |
| `isContinuousSpellCheckingEnabled` | `spellCheckingType = .no` |
| `isAutomaticSpellingCorrectionEnabled`, `isAutomaticTextReplacementEnabled` | `autocorrectionType = .no` |
| `isAutomaticQuoteSubstitutionEnabled` | `smartQuotesType = .no` |
| `isAutomaticDashSubstitutionEnabled` | `smartDashesType = .no` |
| `smartInsertDeleteEnabled` | `smartInsertDeleteType = .no` |
| `isGrammarCheckingEnabled` | *(no iOS trait)* |
| `isIncrementalSearchingEnabled` | `isFindInteractionEnabled` — already `NO` |
| `isRichText = false` | `allowsEditingTextAttributes = false` |

**[R] Three iOS-only traits are missing from the first draft, and they are
exactly the kind the macOS comment warns about — work proportional to *what*
you type:**

| Trait | Header | Why it matters for markup |
|---|---|---|
| `inlinePredictionType = .no` | `UITextInputTraits.h:249`, iOS 17+ | runs a language model over what you type; `<div class="…">` is pure waste |
| `writingToolsBehavior = .none` | `UITextInputTraits.h:269`, iOS 18+ | attaches a `UIWritingToolsCoordinator` to the view |
| `mathExpressionCompletionType = .no` | `UITextInputTraits.h:251`, iOS 18+ | scans input for maths |

Plus `autocapitalizationType = .none`, which has no macOS counterpart and is
simply wrong for markup. **[R]** Drop `textContentType = nil` — it is already
the default (`UITextInputTraits.h:260`).

**[R] Assign `.text`, never `.attributedText`** — right rule, wrong reason in
the first draft. It does *not* break the pull-based design (probed: the view
stays on TK2 and the delegate keeps working). The reasons are:

1. **Cost.** On a 1.7 MB document: `tv.text =` is 1.49 ms,
   `tv.attributedText =` is 8.01 ms — 5.4×.
2. **Correctness.** Handing over a *highlighted* attributed string writes the
   colours into the storage as real attributes instead of vending them as
   display attributes per paragraph — which breaks undo and can re-enter
   `textDidChange`. That is exactly what
   `HTMLSyntaxHighlighter.swift:73`'s deprecation warns about.

The `.text` **getter** is lazy and cheap (0.21 µs), like `NSTextView.string`.
⚠️ `text.count` counts graphemes and took **139 ms** on that document; the code
already uses `.utf16.count` everywhere — keep it that way.

### [ ] 1.4 Appearance — and the theme-invalidation bug **[R]**

The first draft framed this as "swap `NSAppearance` for `UIUserInterfaceStyle`"
and justified hoisting the theme read out of `styledParagraph` on performance
grounds. Both are wrong.

**The performance argument does not hold.** `ParagraphHighlighting.swift:71`
sits *after* the cache hit (`:63-65`) and after `guard !plan.spans.isEmpty`
(`:69`), so it runs on cache misses only, and
`NSApp.effectiveAppearance.name == .darkAqua` measures 68.6 ns against 36.3 ns
cached — 32 ns, against ~3.9 ms per keystroke.

**The two real reasons:**

1. `NSApp.effectiveAppearance` is the **application's** appearance, while
   `viewDidChangeEffectiveAppearance` (`HTMLEditor.swift:140-143`) fires for the
   **view's**. Inside a container with its own appearance
   (`.preferredColorScheme`, a dark-only sheet) they disagree. It should read
   `textView.effectiveAppearance`. This is a macOS bug, found by this review.
2. On iOS there is no equivalent, and `UITraitCollection.current` **must not**
   be read inside the content-storage delegate: it is only valid inside a
   trait-propagating context, and a delegate callback is not one. Hoisting is a
   correctness requirement there, not an optimisation.

**And the blocking find: `invalidateParagraphHighlighting` does not do what its
doc comment says.** `ParagraphHighlighting.swift:128-138` claims
`invalidateLayout` makes TextKit re-ask for paragraphs. Probed on **both**
platforms with a delegate call counter:

```
[iOS]   after invalidateLayout(documentRange):  +0 calls, colour unchanged
[iOS]   after re-setting contentStorage.attributedString: +75 calls, colour changed
[macOS] after invalidateLayout(documentRange):  +0 calls, colour unchanged
[macOS] after re-setting contentStorage.attributedString: +179 calls, colour changed
```

`invalidateLayout` invalidates *layout*, not content-storage *elements*. Theme
switching works on macOS only as a **side effect**: `systemAppearanceChanged`
(`Lifecycle.swift:287-309`) continues into `applyThemeBase`
(`HTMLSyntaxHighlighter.swift:199-210`), which writes into `NSTextStorage`
inside `beginEditing`/`endEditing` — and *that* edit is what re-asks the
delegate.

Port the mechanism only after fixing the comment and deciding the mechanism
deliberately. On iOS there is a better option that macOS lacks: dynamic
`UIColor { traits in … }` in the display attributes resolve against the view's
trait collection at render time, so a theme change needs no invalidation at all.

**[R] Trait API needs both paths at an iOS 16 floor**, not either/or:
`traitCollectionDidChange` is `API_DEPRECATED(…, ios(8.0, 17.0))`
(`UITraitCollection.h:198`); `registerForTraitChanges` is iOS 17+
(`UITraitCollection.h:221`).

### 1.5 Concurrency — cleaner on iOS than on macOS **[R]**

`UITextViewDelegate` is annotated `NS_SWIFT_UI_ACTOR` at the **protocol** level
(`UITextView.h:31`); `NSTextViewDelegate` is not. So the comment at
`HTMLEditor.swift:146-151` explaining why `@MainActor` had to be put on the
class by hand does not apply on iOS — isolation arrives from the protocol.
Keeping `@MainActor` on the class stays correct.

`NSTextContentStorageDelegate` is un-annotated in UIKit as in AppKit
(`NSTextContentManager.h:117-118`), so the isolated conformance
`extension … : @MainActor NSTextContentStorageDelegate` is needed identically.
Compiles clean under `-swift-version 6 -strict-concurrency=complete`.

---

## 4. Phase 2 — the gates that are actually open

**[R] The first draft's gate is closed.** It asked whether `UITextView` stays
on TextKit 2 through a realistic setup. Probed, every path:

```
inputAccessoryView + reloadInputViews : TK2      isEditable toggle      : TK2
becomeFirstResponder                  : TK2      isFindInteractionEnabled: TK2
selectedTextRange                     : TK2      writingToolsBehavior   : TK2
contentSize / contentOffset           : TK2      attributedText =       : TK2
.text = (1.7 MB)                      : TK2      tv.textStorage         : TK2
.layoutManager                        : TK1  ← the only trigger
```

Two gates the first draft missed are open, and both are decisive.

### [ ] 2.1 ⚠️ Nested scrolling inside `Form`

The consumer puts the editor inside a `Form`
(`arm1-admin/Views/PostEditView.swift:51`, `:316`, `:324`;
`JobEditView.swift:49`). On macOS the package brings its own `NSScrollView`.
On iOS `UITextView` *is* a scroll view, inside a collection view.

The usual remedy — `isScrollEnabled = false` plus intrinsic content size —
makes `UITextView` lay out the **whole document** to report its height. That is
precisely what TextKit 2's viewport layout exists to avoid, and it would make
open time a function of document size again.

**This is the single thing that can silently nullify the point of the port, and
it is a layout decision, not a TextKit one.** Options: keep
`isScrollEnabled = true` and give the editor a fixed frame (scroll within
scroll — a product call), or move the editor out of `Form` onto its own screen
on iOS. Decide before writing `makeUIView`.

### [ ] 2.2 ⚠️ Focus

`PostEditView.swift:320/328` uses `.focused($isAnnounceFocused)` /
`$isContentFocused`. SwiftUI's `TextEditor` supports that natively; a
`UIViewRepresentable` does not — `@FocusState` alone will not make a
`UITextView` first responder. §5 collapses the branch and breaks both bindings
unless the package plumbs first-responder state through `updateUIView`.

### [ ] 2.3 A probe worth more than an assert

`textLayoutManager != nil` right after `makeUIView` proves little: the trapdoor
springs on a *late* access, and the likely culprits are outside the package —
`UIViewRepresentable` plumbing, `.focused()`, `Form`'s sizing pass, an
accessibility walk during a UI test.

Assert after first layout, after the first keystroke, after a focus change, and
after an accessibility read. And assert the **second** thing: a counter in
`textContentStorage(_:textParagraphWithRange:)`. Falling back to TK1 is not the
only way to lose the pull path — if the delegate is attached to a content
storage the view later replaces, `textLayoutManager` stays non-nil and
everything "works", just without colour. That is the failure that looks like
success.

### [ ] 2.4 Marked text / IME

Every iOS keystroke goes through `UITextInput`; dictation, emoji and
multi-stage input use marked text. Vending a substituted `NSTextParagraph` for
a paragraph that currently holds marked text has no macOS analogue. The traits
in 1.3 reduce the exposure but do not remove it.

---

## 5. Phase 3 — measurement

### [ ] 3.1 An iOS harness

`HTMLEditorBenchmarks` is a macOS CLI target and cannot run on iOS.
`HTMLEditorBenchmarkSupport.swift` lives **inside the shipping library target**,
so splitting it is a `Package.swift` change.

Prefer XCTest performance tests in the existing test target, driving a
`UITextView` built the way `makeUIView` builds it.

**[R] But that does not exercise the real input path.** `HTMLEditorAutoTypeDiagnostic`
drives macOS through real typing; the XCTest route pokes the view directly,
bypassing `UITextInput`. Since 4.4 makes IME a risk, at least one UI test with
`typeText` is needed, or the per-keystroke gate below has no instrument.

### [ ] 3.2 The shape to reproduce

macOS, markup-dense 42 000-unit lines: insert a character 8.5 ms → 0.4 ms,
~280 spans 1.8 → 0.7 ms, load 1.7 MB 14.8 → 0.5 ms, caret 0.4 → ~3 ms.

iOS will not match the absolutes. The **shape** must hold: per-keystroke cost
flat in document size, and a high paragraph-cache hit rate while scrolling. If
typing cost grows with length, the pull path is not engaged and 4.3's counter
will say so.

### [ ] 3.3 Re-tune the long-line limit

`highlightedParagraphLimit` (`ParagraphHighlighting.swift:51`) was tuned on
macOS, where colouring a very long paragraph cost 27.5 ms against 3.9 ms.
Expect the iOS limit to be **lower**: slower CPU, and a narrower screen wraps
a "long line" into far more layout fragments.

---

## 6. Phase 4 — the consumer

`HTMLCompatibleEditor` currently falls back to a plain `TextEditor` on iOS
solely because this package is macOS-only. Once Phase 1 lands the branch
collapses and iOS/iPadOS get syntax highlighting.

**[R] Two things to check when it does:**

- `UIKitTextViewResolver` (`HTMLCompatibleEditor.swift:76`) finds a
  `UITextView` by walking the view tree and takes the first one. With the
  package supplying its own, it may bind `TextUndoCoordinator` to the wrong
  view.
- The keyboard. `UITextView` does not move the caret out from under the
  keyboard by itself — `keyboardLayoutGuide` (`UIView.h:305`, iOS 15+) or
  `contentInset` from `keyboardWillShowNotification`. There was no such problem
  on macOS. On iPad it is the first thing a user will hit.
- An `inputAccessoryView` is close to mandatory for markup (`<`, `>`, `/`, `"`
  are two taps deep on the software keyboard). Probed: it does not disturb
  TextKit 2.

---

## 7. Order

```
0.1 manifest → 0.2 split highlighter → 0.3 lift policies → 0.4 widen core → 0.5 partial tests
      ↓
2.1 nested scroll decision  +  2.2 focus decision      ← product calls, before any code
      ↓
2.2 extract TK2 lifecycle (on macOS first, where tests exist)
      ↓
1.1 → 1.2 → 1.3 → 1.4  (fix the theme mechanism before porting it)
      ↓
4.3 probe (fallback + delegate counter + marked text)
      ↓
3.x measurement → 6 consumer
```

Phase 0 is worth doing alone: it removes a gratuitous `import AppKit`, unhooks
policy from a view type, and fixes a manifest that would break an iOS build.

§2.2 (extract the TK2 lifecycle) removes a wasted full-document scan on macOS
too, so it pays for itself before iOS exists.

---

## 8. Rejected

**Porting the TextKit 1 path to iOS.** §2 — a rewrite, not a port, for the
branch nobody should take.

**A representable built on SwiftUI's `TextEditor`.** No access to the
content-storage delegate, which is the whole design.

**`WKWebView` with `contenteditable`.** A different product, and it discards
every measurement in this repository.

**One representable with `#if` inside the methods.** `makeNSView` is 80 lines,
`makeUIView` will be ~40; interleaving makes both harder to read.

**Keeping a TextKit 1 fallback on iOS as insurance.** §2.3 — degrade to plain
text with a signpost instead. Cheaper, and the failure stays visible.
