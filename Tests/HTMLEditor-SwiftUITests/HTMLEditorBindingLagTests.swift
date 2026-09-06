import Testing
import AppKit
import SwiftUI
@testable import HTMLEditor

/// Reference box so the test can observe what the coordinator writes through the
/// binding, which `.constant` cannot do.
@MainActor
private final class HTMLBox {
    var value: String
    init(_ value: String) { self.value = value }
}

@MainActor
private func makeLargeDocument() -> String {
    // Past the conservative threshold, which is what defers the binding write.
    let row = "<p class=\"row\" data-id=\"1\"><a href=\"https://example.com\">text</a></p>\n"
    let html = String(repeating: row, count: 3_000)
    #expect(html.utf16.count > HTMLEditorDocumentSize.conservative)
    return html
}

@MainActor
@Test func testTypingWhileTheBindingLagsDoesNotResetTheTextView() throws {
    _ = NSApplication.shared

    let original = makeLargeDocument()
    let box = HTMLBox(original)
    let theme = makeTestTheme()

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    textView.string = original
    scrollView.documentView = textView

    let coordinator = HTMLEditor.Coordinator(
        HTMLEditor(
            html: Binding(get: { box.value }, set: { box.value = $0 }),
            theme: HTMLEditorTheme(light: theme, dark: theme)
        )
    )
    textView.delegate = coordinator
    coordinator.previousText = original

    // Type one character. Above the threshold the write to the binding is
    // deferred, so the binding still holds the pre-edit text afterwards.
    let caret = original.utf16.count / 2
    let afterFirst = (original as NSString)
        .replacingCharacters(in: NSRange(location: caret, length: 0), with: "a")
    textView.string = afterFirst
    coordinator.pendingEdit = HTMLEditor.Coordinator.PendingEdit(
        affectedRange: NSRange(location: caret, length: 0),
        replacementUTF16Length: 1
    )
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    #expect(box.value == original, "the write should be deferred for a large document")

    // The deferred write lands...
    coordinator.flushPendingBindingSync()
    #expect(box.value == afterFirst)

    // ...and the user types again before SwiftUI delivers the update, so the
    // binding is now one character behind the text view.
    let afterSecond = (textView.string as NSString)
        .replacingCharacters(in: NSRange(location: caret + 1, length: 0), with: "b")
    textView.string = afterSecond
    coordinator.pendingEdit = HTMLEditor.Coordinator.PendingEdit(
        affectedRange: NSRange(location: caret + 1, length: 0),
        replacementUTF16Length: 1
    )
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

    // SwiftUI now delivers the lagging value. Treating it as an external update
    // reassigns textView.string, which reflows the document and drops the caret.
    let selectionBefore = textView.selectedRange()
    #expect(coordinator.shouldApplyExternalUpdate(incomingHTML: box.value) == false)
    #expect(textView.string == afterSecond)
    #expect(textView.selectedRange() == selectionBefore)
}
