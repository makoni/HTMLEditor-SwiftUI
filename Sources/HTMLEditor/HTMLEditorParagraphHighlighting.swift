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
        guard let textStorage = textContentStorage.textStorage,
              range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= textStorage.length else { return nil }

        let paragraph = textStorage.attributedSubstring(from: range)
        let plan = paragraphPlan(for: textStorage.string as NSString, range: range)
        guard !plan.spans.isEmpty else { return nil }

        let theme = parent.theme.current(for: NSApp.effectiveAppearance)
        let styled = NSMutableAttributedString(attributedString: paragraph)

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

        return NSTextParagraph(attributedString: styled)
    }

    /// A plan for one paragraph, cached so that laying the same paragraph out
    /// repeatedly — which scrolling does — does not rescan it.
    ///
    /// The scan starts in the `.text` state at the paragraph boundary. A tag or
    /// an attribute value spanning a newline is therefore coloured from the
    /// following line as if it were plain text; that is the cost of vending
    /// paragraph by paragraph, and it is what the framework's granularity gives
    /// us.
    @MainActor
    func paragraphPlan(
        for text: NSString,
        range: NSRange
    ) -> HTMLSyntaxHighlighter.HighlightPlan {
        let identity = ParagraphPlanKey(range: range, textLength: text.length)
        if let cached = paragraphPlanCache[identity] {
            return cached
        }

        let plan = HTMLHighlightPlanBuilder.buildPlan(in: text, coveredRange: range)

        if paragraphPlanCache.count >= Self.paragraphPlanCacheLimit {
            paragraphPlanCache.removeAll(keepingCapacity: true)
        }
        paragraphPlanCache[identity] = plan
        return plan
    }

    struct ParagraphPlanKey: Hashable {
        let range: NSRange
        let textLength: Int
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
        paragraphPlanCache.removeAll(keepingCapacity: true)

        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = textView.textContentStorage else { return }
        layoutManager.invalidateLayout(for: contentStorage.documentRange)
    }
}
#endif
