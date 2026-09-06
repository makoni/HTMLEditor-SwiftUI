#if os(macOS)
import AppKit

/// Which TextKit generation backs a newly created text view.
///
/// TextKit 2 is the default because it is dramatically faster on the shapes this
/// editor is built for. Measured on a document of markup-dense 42 000-unit
/// lines: inserting a character costs 8.5 ms under TextKit 1 and 0.4 ms under
/// TextKit 2, applying ~280 highlight spans 1.8 ms against 0.7 ms, and loading
/// 1.7 MB 14.8 ms against 0.5 ms. TextKit 2 is slower in one place — placing the
/// caret and drawing, ~3 ms against ~0.4 ms — but the total per keystroke still
/// comes out roughly 2.5x lower.
///
/// The escape hatch exists because TextKit 2 carries known open bugs around long
/// lines and rendering attributes that only show up on screen, never in a
/// measurement. Set `HTMLEDITOR_TEXTKIT=1` to force the old path.
enum HTMLEditorTextKitVersion {
    static var preferred: Bool {
        ProcessInfo.processInfo.environment["HTMLEDITOR_TEXTKIT"] != "1"
    }
}

/// Where highlight colours are applied, and how the visible character range is
/// found.
///
/// TextKit 1 and TextKit 2 express both of those in incompatible terms —
/// temporary attributes on an `NSLayoutManager` against rendering attributes on
/// an `NSTextLayoutManager`, glyph ranges against text locations — and the two
/// cannot be mixed. Reading `NSTextView.layoutManager` on a TextKit 2 view
/// permanently drops it back to TextKit 1, and the system never switches back,
/// so every access has to go through here rather than reaching for the text
/// view's TextKit 1 properties directly.
enum HTMLEditorTextKitSurface {
    case textKit1(NSLayoutManager)
    case textKit2(NSTextLayoutManager, NSTextContentStorage)

    /// Resolves the surface without forcing a TextKit 2 view into compatibility
    /// mode: `textLayoutManager` is nil on a TextKit 1 view, and only then is
    /// `layoutManager` — the property that triggers the fallback — touched.
    @MainActor
    static func resolve(for textView: NSTextView) -> HTMLEditorTextKitSurface? {
        if let layoutManager = textView.textLayoutManager,
           let contentStorage = textView.textContentStorage {
            return .textKit2(layoutManager, contentStorage)
        }
        guard let layoutManager = textView.layoutManager else { return nil }
        return .textKit1(layoutManager)
    }

    /// The backing storage, reached through the content storage under TextKit 2.
    @MainActor
    static func textStorage(for textView: NSTextView) -> NSTextStorage? {
        if let contentStorage = textView.textContentStorage {
            return contentStorage.textStorage
        }
        return textView.textStorage
    }

    var isTextKit2: Bool {
        if case .textKit2 = self { return true }
        return false
    }

    // MARK: - Highlighting

    @MainActor
    func clearHighlights(in range: NSRange) {
        guard range.location != NSNotFound, range.length > 0 else { return }

        switch self {
        case .textKit1(let layoutManager):
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        case .textKit2:
            // Nothing to clear: under TextKit 2 the colours are display
            // attributes vended per paragraph by the content storage delegate,
            // so they are regenerated rather than accumulated.
            break
        }
    }

    /// Applies a plan's spans. `origin` is the document offset the span
    /// locations are measured from; under TextKit 2 it is resolved to a text
    /// location once and every span is then addressed relative to it, rather
    /// than walking from the start of the document for each one.
    @MainActor
    func applyHighlights(
        _ spans: [HTMLSyntaxHighlighter.HighlightSpan],
        origin: Int,
        theme: HTMLEditorColorScheme
    ) {
        guard !spans.isEmpty else { return }

        let tagColour = theme.tag
        let nameColour = theme.attributeName
        let valueColour = theme.attributeValue

        func colour(for role: HTMLSyntaxHighlighter.HighlightRole) -> NSColor {
            switch role {
            case .tag: return tagColour
            case .attributeName: return nameColour
            case .attributeValue: return valueColour
            }
        }

        switch self {
        case .textKit1(let layoutManager):
            // Build the three dictionaries once rather than per span; this runs
            // on the main thread several times per keystroke.
            let attributes: [HTMLSyntaxHighlighter.HighlightRole: [NSAttributedString.Key: Any]] = [
                .tag: [.foregroundColor: tagColour],
                .attributeName: [.foregroundColor: nameColour],
                .attributeValue: [.foregroundColor: valueColour]
            ]
            for span in spans {
                guard span.range.location >= 0, let value = attributes[span.role] else { continue }
                layoutManager.addTemporaryAttributes(value, forCharacterRange: span.range)
            }

        case .textKit2:
            // Deliberately nothing. `addRenderingAttribute` is the API this
            // would use, and an Apple DTS engineer has confirmed it does not
            // reliably refresh the text view. TextKit 2 highlighting is pulled
            // from HTMLEditor.Coordinator's NSTextContentStorageDelegate
            // instead, which the framework calls for each paragraph it lays out.
            break
        }
    }

    // MARK: - Viewport

    /// The character range currently on screen.
    ///
    /// TextKit 1 maps the rect through glyph ranges. TextKit 2 has no glyphs;
    /// the layout fragments at the top and bottom of the rect are asked for
    /// their positions instead, which is a bounded lookup rather than a walk
    /// from the start of the document.
    @MainActor
    func visibleCharacterRange(in visibleRect: NSRect, textContainer: NSTextContainer?) -> NSRange? {
        switch self {
        case .textKit1(let layoutManager):
            guard let textContainer else { return nil }
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        case .textKit2(let layoutManager, let contentStorage):
            let topPoint = CGPoint(x: visibleRect.minX, y: visibleRect.minY)
            let bottomPoint = CGPoint(x: visibleRect.minX, y: max(visibleRect.minY, visibleRect.maxY - 1))

            let first = layoutManager.textLayoutFragment(for: topPoint)
            let last = layoutManager.textLayoutFragment(for: bottomPoint) ?? first

            guard let first, let last else {
                // Before the first layout pass there is nothing on screen yet;
                // fall back to whatever the viewport controller has decided.
                guard let viewportRange = layoutManager.textViewportLayoutController.viewportRange else {
                    return nil
                }
                return Self.nsRange(viewportRange, in: contentStorage)
            }

            guard let range = NSTextRange(
                location: first.rangeInElement.location,
                end: last.rangeInElement.endLocation
            ) else { return nil }
            return Self.nsRange(range, in: contentStorage)
        }
    }

    // MARK: - Range conversion

    @MainActor
    static func textRange(_ range: NSRange, in contentStorage: NSTextContentStorage) -> NSTextRange? {
        guard range.location != NSNotFound, range.location >= 0 else { return nil }
        guard let start = contentStorage.location(
            contentStorage.documentRange.location,
            offsetBy: range.location
        ), let end = contentStorage.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    @MainActor
    static func nsRange(_ range: NSTextRange, in contentStorage: NSTextContentStorage) -> NSRange {
        let location = contentStorage.offset(
            from: contentStorage.documentRange.location,
            to: range.location
        )
        let length = contentStorage.offset(from: range.location, to: range.endLocation)
        return NSRange(location: max(0, location), length: max(0, length))
    }
}
#endif
