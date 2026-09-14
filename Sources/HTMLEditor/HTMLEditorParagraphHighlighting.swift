#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

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

        // The coordinator resolves this when the appearance changes. Reading
        // it here would be wrong on iOS: `UITraitCollection.current` is only
        // valid inside a trait-propagating context, and a content-storage
        // delegate callback is not one.
        let theme = appliedColorScheme ?? parent.theme.current(for: .light)
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

    /// Content hash of the paragraph, over **every** code unit.
    ///
    /// This used to sample five offsets — 0, L/4, L/2, 3L/4 and L-1 — which is
    /// not enough to answer the question the cache asks ("is this the same
    /// paragraph?"). Two same-length paragraphs differing anywhere else hashed
    /// identically, so the cache handed back the older one and the editor drew
    /// stale text.
    ///
    /// The symptom, reported from an iPhone: type `a1`, delete one character to
    /// get `a`, type `2` — the editor shows `a1`. The storage was correct all
    /// along; only the drawn paragraph was stale, which is why the next
    /// keystroke (changing the length again, and so the key) fixed it. Measured
    /// on the 81-character line in the test, the old fingerprint missed the
    /// change in **76 of 81 positions**.
    ///
    /// Hashing the whole paragraph is affordable because it is bounded: a
    /// paragraph longer than ``HTMLEditorDocumentSize/highlightedParagraphLimit``
    /// is never styled, so it never reaches here. Measured, Release, on a
    /// typical 120-unit markup line: 0.26 µs against 0.02 µs for the five
    /// samples. That is 13× the old figure and still half the cost of the scan
    /// it guards (0.51 µs), let alone a whole cache miss (4.6 µs — the scan
    /// plus copying the paragraph, writing its spans and allocating the
    /// element). The cache still saves 73% of a miss, and a viewport of 150
    /// paragraphs pays 0.04 ms for the hashing — against a 16.7 ms frame.
    /// `HTMLEditorParagraphCacheCostTests` keeps those relations honest.
    static func fingerprint(_ text: NSString, range: NSRange) -> Int {
        var hasher = Hasher()
        hasher.combine(range.length)
        guard range.length > 0 else { return hasher.finalize() }

        // One bulk copy plus one bulk hash, rather than a call per character:
        // `character(at:)` on a lazily bridged NSString is not cheap in a loop.
        //
        // On the stack, not the heap: this runs once per paragraph per layout
        // pass, and an `Array` here would be a malloc and a zero-fill on that
        // path — immediately overwritten by `getCharacters`. Bounded by
        // ``HTMLEditorDocumentSize/highlightedParagraphLimit``, so it fits.
        withUnsafeTemporaryAllocation(of: unichar.self, capacity: range.length) { buffer in
            guard let base = buffer.baseAddress else { return }
            text.getCharacters(base, range: range)
            hasher.combine(bytes: UnsafeRawBufferPointer(buffer))
        }
        return hasher.finalize()
    }

    /// Sized to comfortably hold a viewport's worth of paragraphs plus what
    /// scrolling passes over, and cleared wholesale rather than evicted — the
    /// entries are cheap to rebuild and the document length in the key already
    /// invalidates everything on any edit.
    static var paragraphPlanCacheLimit: Int { 512 }

    /// Drops the styled-paragraph cache and invalidates layout.
    ///
    /// ⚠️ This alone does **not** make TextKit re-ask the delegate. Measured on
    /// both platforms with a call counter: `invalidateLayout(for:)` over the
    /// whole document produced **+0** delegate calls and the colour on screen
    /// did not change; only an edit to the text storage re-asks (+75 on iOS,
    /// +179 on macOS). Theme switching works because the caller continues into
    /// `HTMLSyntaxHighlighter.applyThemeBase`, whose
    /// `beginEditing`/`endEditing` pair *is* that edit. Clearing the cache here
    /// is what makes the re-ask produce new colours rather than cached ones —
    /// so the two must stay paired.
    @MainActor
    func invalidateParagraphHighlighting(in textView: HTMLEditorPlatform.TextView) {
        styledParagraphCache.removeAll(keepingCapacity: true)

        guard case .textKit2(let layoutManager, let contentStorage)? =
                HTMLEditorTextKitSurface.resolve(for: textView) else { return }
        layoutManager.invalidateLayout(for: contentStorage.documentRange)
    }
}
