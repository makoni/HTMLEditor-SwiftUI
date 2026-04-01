#if os(macOS)
import AppKit
import Foundation

public struct HTMLSyntaxHighlighter {
    static let maxHighlightLength = 50_000

    enum HighlightRole: Sendable {
        case tag
        case attributeName
        case attributeValue
    }

    struct HighlightSpan: Sendable {
        let range: NSRange
        let role: HighlightRole
    }

    struct HighlightPlan: Sendable {
        let coveredRange: NSRange
        let spans: [HighlightSpan]
    }

    private static let planner = HTMLHighlightPlanner()

    public static func highlight(html: String, theme: HTMLEditorColorScheme) -> NSAttributedString {
        if html.utf16.count > maxHighlightLength {
            return basicAttributedString(html: html, theme: theme)
        }

        let plan = HTMLHighlightPlanBuilder.fullPlan(for: html)
        return attributedString(html: html, theme: theme, plan: plan)
    }

    static func plannedFullHighlight(html: String) async -> HighlightPlan? {
        guard html.utf16.count <= maxHighlightLength else { return nil }
        return await planner.fullPlan(for: html)
    }

    static func plannedRangeHighlight(text: String, requestedRange: NSRange) async -> HighlightPlan {
        await planner.rangePlan(for: text, requestedRange: requestedRange)
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

private actor HTMLHighlightPlanner {
    func fullPlan(for html: String) -> HTMLSyntaxHighlighter.HighlightPlan {
        HTMLHighlightPlanBuilder.fullPlan(for: html)
    }

    func rangePlan(for text: String, requestedRange: NSRange) -> HTMLSyntaxHighlighter.HighlightPlan {
        HTMLHighlightPlanBuilder.rangePlan(for: text, requestedRange: requestedRange)
    }
}

private enum HTMLHighlightPlanBuilder {
    static func fullPlan(for html: String) -> HTMLSyntaxHighlighter.HighlightPlan {
        let nsHTML = html as NSString
        return buildPlan(in: nsHTML, coveredRange: NSRange(location: 0, length: nsHTML.length))
    }

    static func rangePlan(for text: String, requestedRange: NSRange) -> HTMLSyntaxHighlighter.HighlightPlan {
        let nsText = text as NSString
        let textLength = nsText.length

        guard textLength > 0,
              requestedRange.location != NSNotFound,
              requestedRange.location >= 0,
              requestedRange.location < textLength else {
            return HTMLSyntaxHighlighter.HighlightPlan(coveredRange: NSRange(location: 0, length: 0), spans: [])
        }

        let expandRadius = min(100, textLength / 10)
        let expandedStart = max(0, requestedRange.location - expandRadius)
        let expandedEnd = min(textLength, NSMaxRange(requestedRange) + expandRadius)
        var expandedRange = NSRange(location: expandedStart, length: expandedEnd - expandedStart)

        if expandedRange.length > 2000 {
            let center = requestedRange.location + requestedRange.length / 2
            let clampedStart = max(0, center - 1000)
            expandedRange = NSRange(location: clampedStart, length: min(2000, textLength - clampedStart))
        }

        if expandedRange.length < 1000 && expandedRange.length > 0 {
            let startLocation = max(0, min(expandedRange.location, textLength - 1))
            let endLocation = max(0, min(NSMaxRange(expandedRange) - 1, textLength - 1))

            if startLocation < textLength && endLocation < textLength {
                let lineStart = nsText.lineRange(for: NSRange(location: startLocation, length: 0)).location
                let lineEnd = nsText.lineRange(for: NSRange(location: endLocation, length: 0))
                let lineEndLocation = NSMaxRange(lineEnd)
                if lineStart <= lineEndLocation && lineEndLocation <= textLength {
                    expandedRange = NSRange(location: lineStart, length: lineEndLocation - lineStart)
                }
            }
        }

        return buildPlan(in: nsText, coveredRange: expandedRange)
    }

    private static func buildPlan(in text: NSString, coveredRange: NSRange) -> HTMLSyntaxHighlighter.HighlightPlan {
        guard coveredRange.location != NSNotFound,
              coveredRange.length > 0,
              coveredRange.location >= 0,
              NSMaxRange(coveredRange) <= text.length else {
            return HTMLSyntaxHighlighter.HighlightPlan(coveredRange: NSRange(location: 0, length: 0), spans: [])
        }

        var spans: [HTMLSyntaxHighlighter.HighlightSpan] = []
        spans.reserveCapacity(32)

        let end = NSMaxRange(coveredRange)
        var index = coveredRange.location

        while index < end {
            if text.character(at: index) != codeUnit("<") {
                index += 1
                continue
            }

            let tagStart = index
            var cursor = index + 1
            var tagNameStart = cursor

            if cursor < end && text.character(at: cursor) == codeUnit("/") {
                cursor += 1
                tagNameStart = cursor
            }

            guard tagNameStart < end, isTagNameCharacter(text.character(at: tagNameStart)) else {
                index += 1
                continue
            }

            spans.append(.init(range: NSRange(location: tagStart, length: 1), role: .tag))
            if tagStart + 1 < tagNameStart {
                spans.append(.init(range: NSRange(location: tagStart + 1, length: 1), role: .tag))
            }

            while cursor < end, isTagNameCharacter(text.character(at: cursor)) {
                cursor += 1
            }

            spans.append(.init(range: NSRange(location: tagNameStart, length: cursor - tagNameStart), role: .tag))

            while cursor < end {
                let current = text.character(at: cursor)

                if isWhitespace(current) {
                    cursor += 1
                    continue
                }

                if current == codeUnit(">") {
                    spans.append(.init(range: NSRange(location: cursor, length: 1), role: .tag))
                    cursor += 1
                    break
                }

                if current == codeUnit("/") {
                    spans.append(.init(range: NSRange(location: cursor, length: 1), role: .tag))
                    cursor += 1
                    continue
                }

                let attributeStart = cursor
                while cursor < end, isAttributeNameCharacter(text.character(at: cursor)) {
                    cursor += 1
                }

                if cursor == attributeStart {
                    cursor += 1
                    continue
                }

                spans.append(.init(range: NSRange(location: attributeStart, length: cursor - attributeStart), role: .attributeName))

                while cursor < end, isWhitespace(text.character(at: cursor)) {
                    cursor += 1
                }

                guard cursor < end, text.character(at: cursor) == codeUnit("=") else {
                    continue
                }

                cursor += 1
                while cursor < end, isWhitespace(text.character(at: cursor)) {
                    cursor += 1
                }

                guard cursor < end else { break }

                let currentValueStarter = text.character(at: cursor)
                if currentValueStarter == codeUnit("\"") || currentValueStarter == codeUnit("'") {
                    let quote = currentValueStarter
                    let valueStart = cursor
                    cursor += 1

                    while cursor < end, text.character(at: cursor) != quote {
                        cursor += 1
                    }

                    if cursor < end, text.character(at: cursor) == quote {
                        cursor += 1
                    }

                    spans.append(.init(range: NSRange(location: valueStart, length: cursor - valueStart), role: .attributeValue))
                } else {
                    let valueStart = cursor
                    while cursor < end,
                          !isWhitespace(text.character(at: cursor)),
                          text.character(at: cursor) != codeUnit(">") {
                        cursor += 1
                    }

                    if cursor > valueStart {
                        spans.append(.init(range: NSRange(location: valueStart, length: cursor - valueStart), role: .attributeValue))
                    }
                }
            }

            index = max(cursor, tagStart + 1)
        }

        return HTMLSyntaxHighlighter.HighlightPlan(coveredRange: coveredRange, spans: coalesce(spans))
    }

    private static func coalesce(_ spans: [HTMLSyntaxHighlighter.HighlightSpan]) -> [HTMLSyntaxHighlighter.HighlightSpan] {
        let sorted = spans.sorted {
            if $0.range.location == $1.range.location {
                return $0.range.length < $1.range.length
            }
            return $0.range.location < $1.range.location
        }

        var merged: [HTMLSyntaxHighlighter.HighlightSpan] = []
        merged.reserveCapacity(sorted.count)

        for span in sorted {
            guard span.range.location != NSNotFound, span.range.length > 0 else { continue }

            if let last = merged.last,
               last.role == span.role,
               span.range.location <= NSMaxRange(last.range) {
                let newStart = last.range.location
                let newEnd = max(NSMaxRange(last.range), NSMaxRange(span.range))
                merged[merged.count - 1] = .init(range: NSRange(location: newStart, length: newEnd - newStart), role: last.role)
            } else {
                merged.append(span)
            }
        }

        return merged
    }

    private static func isTagNameCharacter(_ value: unichar) -> Bool {
        isASCIIAlpha(value) || isASCIIDigit(value)
    }

    private static func isAttributeNameCharacter(_ value: unichar) -> Bool {
        isTagNameCharacter(value) || value == codeUnit("-") || value == codeUnit(":") || value == codeUnit("_")
    }

    private static func isWhitespace(_ value: unichar) -> Bool {
        value == 9 || value == 10 || value == 13 || value == 32
    }

    private static func isASCIIAlpha(_ value: unichar) -> Bool {
        (65...90).contains(Int(value)) || (97...122).contains(Int(value))
    }

    private static func isASCIIDigit(_ value: unichar) -> Bool {
        (48...57).contains(Int(value))
    }

    private static func codeUnit(_ character: Character) -> unichar {
        String(character).utf16.first!
    }
}

extension NSRange {
    func toOptional() -> NSRange? {
        location != NSNotFound ? self : nil
    }
}

#endif
