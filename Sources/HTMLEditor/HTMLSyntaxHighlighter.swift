#if os(macOS)
import AppKit
import Foundation

public struct HTMLSyntaxHighlighter {
    static let maxHighlightLength = 50_000

    enum HighlightRole: Sendable, Equatable, Hashable {
        case tag
        case attributeName
        case attributeValue
    }

    struct HighlightSpan: Sendable, Equatable, Hashable {
        let range: NSRange
        let role: HighlightRole
    }

    struct HighlightPlan: Sendable {
        let coveredRange: NSRange
        let spans: [HighlightSpan]
    }

    private static let planner = HTMLHighlightPlanner()
    private static let sharedPlannerDocumentID = UUID()

    public static func highlight(html: String, theme: HTMLEditorColorScheme) -> NSAttributedString {
        if html.utf16.count > maxHighlightLength {
            return basicAttributedString(html: html, theme: theme)
        }

        let plan = HTMLHighlightPlanBuilder.fullPlan(for: html)
        return attributedString(html: html, theme: theme, plan: plan)
    }

    static func plannedFullHighlight(html: String) async -> HighlightPlan? {
        await plannedFullHighlight(documentID: sharedPlannerDocumentID, html: html)
    }

    static func plannedFullHighlight(documentID: UUID, html: String) async -> HighlightPlan? {
        guard html.utf16.count <= maxHighlightLength else { return nil }
        return await planner.fullPlan(for: html, documentID: documentID)
    }

    static func plannedRangeHighlight(text: String, requestedRange: NSRange) async -> HighlightPlan {
        await plannedRangeHighlight(documentID: sharedPlannerDocumentID, text: text, requestedRange: requestedRange)
    }

    static func plannedRangeHighlight(documentID: UUID, text: String, requestedRange: NSRange) async -> HighlightPlan {
        await planner.rangePlan(for: text, requestedRange: requestedRange, documentID: documentID)
    }

    static func invalidatePlannerCache(
        documentID: UUID,
        editRange: NSRange,
        replacementUTF16Length: Int,
        newTextLength: Int
    ) async {
        await planner.invalidate(
            documentID: documentID,
            editRange: editRange,
            replacementUTF16Length: replacementUTF16Length,
            newTextLength: newTextLength
        )
    }

    static func clearPlannerCache(documentID: UUID) async {
        await planner.clear(documentID: documentID)
    }

    static func debugPlannerCacheCounts(documentID: UUID) async -> (plans: Int, chunks: Int) {
        await planner.debugCounts(documentID: documentID)
    }

    static func attributedString(html: String, theme: HTMLEditorColorScheme, plan: HighlightPlan?) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: html)
        let fullRange = NSRange(location: 0, length: attributed.length)
        applyBaseAttributes(to: attributed, range: fullRange, theme: theme)

        if let plan {
            apply(spans: plan.spans, to: attributed, theme: theme)
        }

        return attributed
    }

    static func clippedPlan(_ plan: HighlightPlan, to range: NSRange) -> HighlightPlan {
        let coveredRange = NSIntersectionRange(plan.coveredRange, range)
        guard coveredRange.location != NSNotFound, coveredRange.length > 0 else {
            return HighlightPlan(coveredRange: NSRange(location: 0, length: 0), spans: [])
        }

        let spans = plan.spans.compactMap { span -> HighlightSpan? in
            let intersection = NSIntersectionRange(span.range, coveredRange)
            guard intersection.location != NSNotFound, intersection.length > 0 else { return nil }
            return HighlightSpan(range: intersection, role: span.role)
        }

        return HighlightPlan(coveredRange: coveredRange, spans: spans)
    }

    static func basicAttributedString(html: String, theme: HTMLEditorColorScheme) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: html)
        let fullRange = NSRange(location: 0, length: attributed.length)
        applyBaseAttributes(to: attributed, range: fullRange, theme: theme)
        return attributed
    }

    public static func highlightRange(
        in textStorage: NSTextStorage,
        range: NSRange,
        theme: HTMLEditorColorScheme,
        expandedRange: inout NSRange
    ) {
        let plan = HTMLHighlightPlanBuilder.rangePlan(for: textStorage.string, requestedRange: range)
        expandedRange = plan.coveredRange
        apply(plan: plan, to: textStorage, theme: theme)
    }

    static func apply(plan: HighlightPlan, to textStorage: NSTextStorage, theme: HTMLEditorColorScheme) {
        guard plan.coveredRange.location != NSNotFound, plan.coveredRange.length > 0 else { return }

        textStorage.removeAttribute(.foregroundColor, range: plan.coveredRange)
        textStorage.addAttribute(.font, value: theme.font, range: plan.coveredRange)
        textStorage.addAttribute(.foregroundColor, value: theme.foreground, range: plan.coveredRange)
        apply(spans: plan.spans, to: textStorage, theme: theme)
    }

    static func clearTemporaryHighlights(in layoutManager: NSLayoutManager, range: NSRange) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
    }

    static func applyTemporary(plan: HighlightPlan, to layoutManager: NSLayoutManager, theme: HTMLEditorColorScheme) {
        clearTemporaryHighlights(in: layoutManager, range: plan.coveredRange)

        for span in plan.spans {
            guard span.range.location >= 0 else { continue }
            layoutManager.addTemporaryAttributes(
                [.foregroundColor: color(for: span.role, theme: theme)],
                forCharacterRange: span.range
            )
        }
    }

    static func applyTemporary(
        plan: HighlightPlan,
        replacing previousPlan: HighlightPlan?,
        to layoutManager: NSLayoutManager,
        theme: HTMLEditorColorScheme
    ) {
        guard let previousPlan else {
            applyTemporary(plan: plan, to: layoutManager, theme: theme)
            return
        }

        let overlap = NSIntersectionRange(previousPlan.coveredRange, plan.coveredRange)
        if overlap.location == NSNotFound || overlap.length == 0 {
            applyTemporary(plan: plan, to: layoutManager, theme: theme)
            return
        }

        // Clear the full overlap region rather than only the positions listed in
        // previousPlan.spans.  Temporary highlights applied by prewarm (which are
        // never tracked in the visible plan's span list) would otherwise survive
        // the transition and display stale colours on plain-text content.
        clearTemporaryHighlights(in: layoutManager, range: overlap)

        if previousPlan.coveredRange.location > plan.coveredRange.location {
            let leadingRange = NSRange(
                location: plan.coveredRange.location,
                length: previousPlan.coveredRange.location - plan.coveredRange.location
            )
            clearTemporaryHighlights(in: layoutManager, range: leadingRange)
        }

        if NSMaxRange(previousPlan.coveredRange) < NSMaxRange(plan.coveredRange) {
            let trailingRange = NSRange(
                location: NSMaxRange(previousPlan.coveredRange),
                length: NSMaxRange(plan.coveredRange) - NSMaxRange(previousPlan.coveredRange)
            )
            clearTemporaryHighlights(in: layoutManager, range: trailingRange)
        }

        for span in plan.spans {
            guard span.range.location >= 0 else { continue }
            layoutManager.addTemporaryAttributes(
                [.foregroundColor: color(for: span.role, theme: theme)],
                forCharacterRange: span.range
            )
        }
    }

    static func filteredPlan(_ plan: HighlightPlan, detail: HTMLEditorHighlightDetail) -> HighlightPlan {
        switch detail {
        case .full:
            return plan
        case .tagsOnly:
            return HighlightPlan(
                coveredRange: plan.coveredRange,
                spans: plan.spans.filter { $0.role == .tag }
            )
        }
    }

    static func mergedPlan(base: HighlightPlan, overlay: HighlightPlan) -> HighlightPlan {
        let overlayRange = overlay.coveredRange
        let retainedBaseSpans = base.spans.filter {
            NSIntersectionRange($0.range, overlayRange).length == 0
        }
        let mergedCoveredRange = NSUnionRange(base.coveredRange, overlay.coveredRange)
        let mergedSpans = (retainedBaseSpans + overlay.spans).sorted {
            if $0.range.location == $1.range.location {
                return $0.range.length < $1.range.length
            }
            return $0.range.location < $1.range.location
        }

        return HighlightPlan(coveredRange: mergedCoveredRange, spans: mergedSpans)
    }

    @MainActor
    static func applyThemeBase(to textView: NSTextView, theme: HTMLEditorColorScheme) {
        let fullRange = NSRange(location: 0, length: textView.string.utf16.count)
        textView.font = theme.font
        textView.textColor = theme.foreground
        textView.backgroundColor = theme.background

        guard let textStorage = textView.textStorage else { return }
        textStorage.beginEditing()
        textStorage.addAttribute(.font, value: theme.font, range: fullRange)
        textStorage.addAttribute(.foregroundColor, value: theme.foreground, range: fullRange)
        textStorage.endEditing()
    }

    private static func applyBaseAttributes(
        to attributedString: NSMutableAttributedString,
        range: NSRange,
        theme: HTMLEditorColorScheme
    ) {
        attributedString.addAttribute(.font, value: theme.font, range: range)
        attributedString.addAttribute(.foregroundColor, value: theme.foreground, range: range)
    }

    private static func apply(spans: [HighlightSpan], to attributedString: NSMutableAttributedString, theme: HTMLEditorColorScheme) {
        for span in spans {
            guard span.range.location >= 0,
                  NSMaxRange(span.range) <= attributedString.length else { continue }
            attributedString.addAttribute(.foregroundColor, value: color(for: span.role, theme: theme), range: span.range)
        }
    }

    private static func apply(spans: [HighlightSpan], to textStorage: NSTextStorage, theme: HTMLEditorColorScheme) {
        for span in spans {
            guard span.range.location >= 0,
                  NSMaxRange(span.range) <= textStorage.length else { continue }
            textStorage.addAttribute(.foregroundColor, value: color(for: span.role, theme: theme), range: span.range)
        }
    }

    private static func color(for role: HighlightRole, theme: HTMLEditorColorScheme) -> NSColor {
        switch role {
        case .tag:
            return theme.tag
        case .attributeName:
            return theme.attributeName
        case .attributeValue:
            return theme.attributeValue
        }
    }
}

extension NSRange {
    func toOptional() -> NSRange? {
        location != NSNotFound ? self : nil
    }
}

#endif
