import Testing
import AppKit
@testable import HTMLEditor

func makeTestTheme() -> HTMLEditorColorScheme {
    HTMLEditorColorScheme(
        foreground: .black,
        background: .white,
        tag: .red,
        attributeName: .blue,
        attributeValue: .green,
        font: .systemFont(ofSize: 14)
    )
}

/// Reads back the highlight colour at a location, whichever TextKit the view is
/// using: temporary attributes under TextKit 1, rendering attributes under
/// TextKit 2. Must not touch `layoutManager` unless the view is already
/// TextKit 1, or the read itself would change what is being tested.
@MainActor
func appliedHighlightColour(_ textView: NSTextView, at location: Int) -> NSColor? {
    if textView.textLayoutManager != nil, let contentStorage = textView.textContentStorage {
        // TextKit 2 colours are display attributes on the paragraphs the
        // content storage vends through its delegate, so read them from the
        // vended element rather than from rendering attributes.
        guard let target = contentStorage.location(
            contentStorage.documentRange.location,
            offsetBy: location
        ), let next = contentStorage.location(target, offsetBy: 1),
           let probe = NSTextRange(location: target, end: next) else { return nil }

        var colour: NSColor?
        contentStorage.enumerateTextElements(from: probe.location) { element in
            guard let paragraph = element as? NSTextParagraph,
                  let elementRange = paragraph.elementRange,
                  let attributed = paragraph.attributedString as NSAttributedString? else { return false }
            let offset = contentStorage.offset(from: elementRange.location, to: target)
            if offset >= 0, offset < attributed.length {
                colour = attributed.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
            }
            return false
        }
        return colour
    }

    return textView.layoutManager?.temporaryAttribute(
        .foregroundColor,
        atCharacterIndex: location,
        effectiveRange: nil
    ) as? NSColor
}

/// A text view pinned to a specific TextKit generation, so a test says which one
/// it means instead of depending on the platform default.
@MainActor
func makeTextView(textKit2: Bool) -> NSTextView {
    let textView = NSTextView(usingTextLayoutManager: textKit2)
    textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    textView.isRichText = false
    return textView
}

/// Under TextKit 2 the coordinator supplies highlighting through the content
/// storage delegate, so a test that never sets it would read plain text and
/// pass or fail for the wrong reason.
@MainActor
func makeTextView(
    textKit2: Bool,
    highlightedBy coordinator: HTMLEditor.Coordinator
) -> NSTextView {
    let textView = makeTextView(textKit2: textKit2)
    textView.textContentStorage?.delegate = coordinator
    textView.delegate = coordinator
    return textView
}
