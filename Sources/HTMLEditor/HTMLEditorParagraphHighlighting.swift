#if os(macOS)
import AppKit

/// TextKit 2 highlighting, driven by the framework rather than by us.
///
/// `NSTextContentStorage` asks its delegate for each paragraph it is about to
/// lay out, which is exactly the set of paragraphs on screen. Returning an
/// `NSTextParagraph` carrying display attributes colours that paragraph without
/// touching the text storage — so undo stays intact, `textDidChange` is not
/// re-entered, and there is no separate notion of a "visible range" to keep in
/// step with the viewport. TextKit re-asks for a paragraph whenever it is
/// edited, so highlighting after a keystroke needs no scheduling at all.
///
/// This replaces `NSTextLayoutManager.addRenderingAttribute` on the TextKit 2
/// path. Rendering attributes are the obvious-looking API and the wrong one: an
/// Apple DTS engineer has confirmed that `addRenderingAttribute` together with
/// `invalidateLayout` does not reliably refresh the text view — the colours land
/// late or not until the window is resized. Display attributes through this
/// delegate are the documented approach, and the one Apple's own TextKit 2
/// session demonstrates for exactly this purpose.
/// The conformance is main-actor isolated: `NSTextContentStorageDelegate` is
/// not actor-annotated, but TextKit only ever calls it during layout, which
/// happens on the main thread.
extension HTMLEditor.Coordinator: @MainActor NSTextContentStorageDelegate {
    public func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        HTMLEditorSignpost.interval("paragraph-styling") {
            styledParagraph(in: textContentStorage, range: range)
        }
    }

    @MainActor
    private func styledParagraph(
        in textContentStorage: NSTextContentStorage,
        range: NSRange
    ) -> NSTextParagraph? {
        guard let textStorage = textContentStorage.textStorage,
              range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= textStorage.length else { return nil }

        // A line this long is minified, not written by hand, and colouring it
        // is what makes typing in it slow: the cost is not the scan (0.3 ms) but
        // TextKit laying out a paragraph carrying a thousand attribute runs
        // instead of uniform text, which measured 3.9 ms against 27.5 ms per
        // keystroke on a 28 000-character line. Leaving such a line plain is the
        // same bargain other editors strike, and it is invisible on markup
        // anyone actually reads.
        guard range.length <= HTMLEditorDocumentSize.highlightedParagraphLimit else { return nil }

        let text = textStorage.string as NSString
        let key = ParagraphPlanKey(
            location: range.location,
            length: range.length,
            fingerprint: Self.fingerprint(text, range: range)
        )
        // Hand back the identical element when the paragraph has not changed.
        // The delegate is asked for more paragraphs than the one being edited,
        // and rebuilding an equivalent-but-different element makes TextKit redo
        // layout it could have kept.
        if let cached = styledParagraphCache[key] {
            return cached
        }

        let plan = HTMLHighlightPlanBuilder.buildPlan(in: text, coveredRange: range)
        let paragraph = textStorage.attributedSubstring(from: range)
        guard !plan.spans.isEmpty else { return nil }

        let theme = parent.theme.current(for: NSApp.effectiveAppearance)
        let styled = NSMutableAttributedString(attributedString: paragraph)

        // Batch the attribute writes. A markup-dense line carries around a
        // thousand spans, and outside an editing transaction each write makes
        // the attributed string re-fix its attribute runs — which is the bulk of
        // what a keystroke inside such a line used to cost.
        styled.beginEditing()
        for span in plan.spans {
            // Span locations are document-absolute; the paragraph copy starts at 0.
            let local = NSRange(
                location: span.range.location - range.location,
                length: span.range.length
            )
            guard local.location >= 0, NSMaxRange(local) <= styled.length else { continue }
            styled.addAttribute(
                .foregroundColor,
                value: HTMLSyntaxHighlighter.colour(for: span.role, theme: theme),
                range: local
            )
        }
        styled.endEditing()

        let element = NSTextParagraph(attributedString: styled)
        if styledParagraphCache.count >= Self.paragraphPlanCacheLimit {
            styledParagraphCache.removeAll(keepingCapacity: true)
        }
        styledParagraphCache[key] = element
        return element
    }

    struct ParagraphPlanKey: Hashable {
        let location: Int
        let length: Int
        let fingerprint: Int
    }

    /// Cheap content check: the paragraph's length plus a handful of sampled
    /// code units. Keying on the document's total length instead would miss on
    /// every paragraph after every keystroke, which is exactly what this cache
    /// exists to avoid.
    static func fingerprint(_ text: NSString, range: NSRange) -> Int {
        var hasher = Hasher()
        hasher.combine(range.length)
        let offsets = [0, range.length / 4, range.length / 2, (range.length * 3) / 4, range.length - 1]
        for offset in offsets where offset >= 0 && offset < range.length {
            hasher.combine(text.character(at: range.location + offset))
        }
        return hasher.finalize()
    }

    /// Sized to comfortably hold a viewport's worth of paragraphs plus what
    /// scrolling passes over, and cleared wholesale rather than evicted — the
    /// entries are cheap to rebuild and the document length in the key already
    /// invalidates everything on any edit.
    static var paragraphPlanCacheLimit: Int { 512 }

    /// Makes TextKit re-ask for the paragraphs in `range`, which is how a
    /// highlight change that is not caused by editing — a theme swap — reaches
    /// the screen. `invalidateRenderingAttributes` does not do this.
    @MainActor
    func invalidateParagraphHighlighting(in textView: NSTextView) {
        styledParagraphCache.removeAll(keepingCapacity: true)

        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = textView.textContentStorage else { return }
        layoutManager.invalidateLayout(for: contentStorage.documentRange)
    }
}


#endif
