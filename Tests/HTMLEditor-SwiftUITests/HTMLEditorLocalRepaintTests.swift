import Testing
import AppKit
import SwiftUI
@testable import HTMLEditor

@MainActor
private func colour(
    _ textView: NSTextView,
    at location: Int
) -> NSColor? {
    textView.layoutManager?.temporaryAttribute(
        .foregroundColor,
        atCharacterIndex: location,
        effectiveRange: nil
    ) as? NSColor
}

/// Typing repaints only the region around the caret. Everything else in the
/// viewport keeps the temporary attributes it already had, which the layout
/// manager shifts across the edit — so the colours further away must survive
/// untouched. This is the property that a narrower repaint could break.
@MainActor
@Test func testLocalRepaintKeepsColoursAwayFromTheCaret() throws {
    _ = NSApplication.shared
    let theme = makeTestTheme()

    let prefix = "<div class=\"far\"><span id=\"marker\">stable</span></div>\n"
    let middle = String(repeating: "<p class=\"filler\">text</p>\n", count: 40)
    let html = prefix + middle + "<a href=\"https://example.com\">tail</a>\n"

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    textView.isRichText = false
    textView.string = html
    scrollView.documentView = textView

    let coordinator = HTMLEditor.Coordinator(
        HTMLEditor(html: .constant(html), theme: HTMLEditorTheme(light: theme, dark: theme))
    )
    textView.delegate = coordinator
    coordinator.previousText = html

    // Paint the whole document as the visible plan, the way a full pass would.
    let fullPlan = HTMLHighlightPlanBuilder.fullPlan(for: html)
    coordinator.visibleHighlightState.replace(with: fullPlan)
    if let layoutManager = textView.layoutManager {
        HTMLSyntaxHighlighter.applyTemporary(plan: fullPlan, to: layoutManager, theme: theme)
    }

    // A tag far from where the edit will land, and an attribute value near the end.
    let markerTag = (html as NSString).range(of: "span").location
    let tailValue = (html as NSString).range(of: "\"https://example.com\"").location
    #expect(colour(textView, at: markerTag) == theme.tag)
    #expect(colour(textView, at: tailValue) == theme.attributeValue)

    // Type an attribute in the middle of the document.
    let caret = (html as NSString).range(of: "<p class=\"filler\">text</p>", options: .backwards).location
    let inserted = "<a href=\"x\">"
    let edited = (html as NSString).replacingCharacters(
        in: NSRange(location: caret, length: 0), with: inserted
    )
    // Must go through the text storage, not `textView.string`: assigning the
    // string replaces the whole document and drops every temporary attribute,
    // which is not what typing does and would make this test vacuous.
    textView.textStorage?.replaceCharacters(
        in: NSRange(location: caret, length: 0), with: inserted
    )
    #expect(textView.string == edited)
    coordinator.pendingEdit = HTMLEditor.Coordinator.PendingEdit(
        affectedRange: NSRange(location: caret, length: 0),
        replacementUTF16Length: inserted.utf16.count
    )
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

    // The newly typed markup is coloured.
    let editedNS = edited as NSString
    let insertedTagName = caret + 1
    let insertedAttributeName = editedNS.range(of: "href").location
    #expect(colour(textView, at: insertedTagName) == theme.tag)
    #expect(colour(textView, at: insertedAttributeName) == theme.attributeName)

    // And the untouched parts of the document kept their colours.
    #expect(colour(textView, at: markerTag) == theme.tag)
    #expect(
        colour(textView, at: tailValue + inserted.utf16.count) == theme.attributeValue,
        "colour past the edit must survive, shifted by the insertion"
    )
}
