import Testing
import AppKit
import SwiftUI
@testable import HTMLEditor

@MainActor
private func makeCoordinator(displaying html: String) -> HTMLEditor.Coordinator {
    _ = NSApplication.shared
    let theme = makeTestTheme()
    let editor = HTMLEditor(
        html: .constant(html),
        theme: HTMLEditorTheme(light: theme, dark: theme)
    )
    let coordinator = HTMLEditor.Coordinator(editor)
    // Mirror what makeNSView records once the text view is showing `html`.
    coordinator.previousText = html
    return coordinator
}

@MainActor
@Test func testExternalUpdateAppliesWhenOnlyInteriorCharactersDiffer() throws {
    // Same length, same first/last/middle code unit: the sampled fingerprint
    // that used to gate this collides, so a programmatic find-and-replace was
    // silently dropped and the binding and the editor diverged with no way back.
    let displayed = "<p class=\"a\">Hello</p>"
    let incoming = "<p class=\"b\">Hello</p>"
    #expect(displayed.utf16.count == incoming.utf16.count)

    let coordinator = makeCoordinator(displaying: displayed)
    #expect(coordinator.shouldApplyExternalUpdate(incomingHTML: incoming) == true)
}

@MainActor
@Test func testExternalUpdateAppliesForEqualLengthTagRename() throws {
    let coordinator = makeCoordinator(displaying: "<b>x</b>")
    #expect(coordinator.shouldApplyExternalUpdate(incomingHTML: "<i>x</i>") == true)
}

@MainActor
@Test func testIdenticalIncomingTextIsNotReapplied() throws {
    let html = "<p>unchanged</p>"
    let coordinator = makeCoordinator(displaying: html)
    #expect(coordinator.shouldApplyExternalUpdate(incomingHTML: html) == false)
}

@MainActor
@Test func testLocalEchoIsIgnoredButNormalisedEchoIsApplied() throws {
    // After a local edit the coordinator writes through the binding and expects
    // the same string back.  A parent that normalises in its setter returns a
    // *different* string; consuming the echo flag before comparing swallowed
    // that normalisation and desynced the model from the view permanently.
    let typed = "<p>\ttabbed</p>"
    let normalised = "<p>  tabbed</p>"

    let coordinator = makeCoordinator(displaying: typed)
    coordinator.lastBindingWriteHTML = typed
    #expect(coordinator.shouldApplyExternalUpdate(incomingHTML: normalised) == true)

    // The plain echo of an unmodified write is still ignored.
    let plain = makeCoordinator(displaying: typed)
    plain.lastBindingWriteHTML = typed
    #expect(plain.shouldApplyExternalUpdate(incomingHTML: typed) == false)
}

@MainActor
@Test func testEchoArrivingAfterMoreTypingDoesNotResetTheDocument() throws {
    // For large documents bindingSyncDelay holds the write back, so the binding
    // is routinely behind what is on screen.  A keystroke landing between the
    // write and SwiftUI's update turn means the echo carries older text than the
    // text view holds; applying it reassigns textView.string, which reflows the
    // whole document and drops the caret.
    let sentToBinding = "<p>ab</p>"
    let typedSince = "<p>abc</p>"

    let coordinator = makeCoordinator(displaying: typedSince)
    coordinator.lastBindingWriteHTML = sentToBinding

    #expect(coordinator.shouldApplyExternalUpdate(incomingHTML: sentToBinding) == false)

    // A genuinely new value from the parent is still applied.
    #expect(coordinator.shouldApplyExternalUpdate(incomingHTML: "<p>zzz</p>") == true)
}

@MainActor
@Test func testEchoGuardIsReleasedOnceTheBindingCatchesUp() throws {
    // Once the echo of the latest write arrives with the text view in step, the
    // guard must be dropped — otherwise a parent that later sets that same value
    // again (an undo, say) would be ignored forever.
    let html = "<p>ab</p>"
    let coordinator = makeCoordinator(displaying: html)
    coordinator.lastBindingWriteHTML = html

    #expect(coordinator.shouldApplyExternalUpdate(incomingHTML: html) == false)
    #expect(coordinator.lastBindingWriteHTML == nil)

    coordinator.previousText = "<p>edited</p>"
    #expect(coordinator.shouldApplyExternalUpdate(incomingHTML: html) == true)
}

@MainActor
@Test func testSwappingTheThemeReappliesColours() throws {
    _ = NSApplication.shared

    let html = "<p class=\"a\">text</p>"
    let first = makeTestTheme()
    let second = HTMLEditorColorScheme(
        foreground: .systemPink,
        background: .systemBrown,
        tag: .systemTeal,
        attributeName: .systemIndigo,
        attributeValue: .systemMint,
        font: .monospacedSystemFont(ofSize: 18, weight: .bold)
    )

    let coordinator = makeCoordinator(displaying: html)
    coordinator.appliedColorScheme = first

    let scrollView = NSScrollView()
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    textView.string = html
    scrollView.documentView = textView

    // A caller swapping the theme while the system appearance is unchanged.
    coordinator.parent = HTMLEditor(
        html: .constant(html),
        theme: HTMLEditorTheme(light: second, dark: second)
    )
    coordinator.applyColorSchemeChangeIfNeeded(textView: textView)

    #expect(coordinator.appliedColorScheme == second)
    #expect(textView.backgroundColor == second.background)
    #expect(textView.font == second.font)

    // Re-running with nothing changed is a no-op.
    coordinator.applyColorSchemeChangeIfNeeded(textView: textView)
    #expect(coordinator.appliedColorScheme == second)
}

@MainActor
@Test func testLargeDocumentAppearanceChangeQueuesRehighlighting() throws {
    _ = NSApplication.shared

    // Above maxHighlightLength there is never a cached full plan, so an
    // appearance change always lands in the plain-text path.  That path clears
    // every temporary attribute; it must leave a highlight pass queued or the
    // document stays plain until the user scrolls or types.
    let row = "<p class=\"a\">text</p>\n"
    let html = String(repeating: row, count: 4_000)
    #expect(html.utf16.count > HTMLSyntaxHighlighter.maxHighlightLength)

    let coordinator = makeCoordinator(displaying: html)
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    textView.string = html
    scrollView.documentView = textView

    coordinator.visibleHighlightDebounceTask?.cancel()
    coordinator.visibleHighlightDebounceTask = nil

    coordinator.performFullHighlighting(
        html: html,
        theme: makeTestTheme(),
        textView: textView
    )

    #expect(coordinator.visibleHighlightDebounceTask != nil)
}
