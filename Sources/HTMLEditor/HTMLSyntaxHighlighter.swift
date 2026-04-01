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

private enum HTMLHighlightScannerState: Hashable, Sendable {
    case text
    case afterTagOpen
    case tagName
    case insideTag
    case attributeName
    case afterAttributeName
    case beforeAttributeValue
    case quotedAttributeValue(unichar)
    case unquotedAttributeValue
}

private struct HTMLHighlightChunkResult: Sendable {
    let endState: HTMLHighlightScannerState
    let spans: [HTMLSyntaxHighlighter.HighlightSpan]
}

private actor HTMLHighlightPlanner {
    private struct CachedPlanEntry: Sendable {
        let key: PlannerCacheKey
        let plan: HTMLSyntaxHighlighter.HighlightPlan
    }

    private struct CachedChunkEntry: Sendable {
        let key: PlannerChunkCacheKey
        let result: HTMLHighlightChunkResult
    }

    private struct PlannerCacheKey: Hashable, Sendable {
        let documentID: UUID
        let textLength: Int
        let range: NSRange
        let fingerprint: Int
    }

    private struct PlannerChunkCacheKey: Hashable, Sendable {
        let documentID: UUID
        let textLength: Int
        let range: NSRange
        let fingerprint: Int
        let inputState: HTMLHighlightScannerState
    }

    private var cachedPlans: [CachedPlanEntry] = []
    private var cachedChunks: [CachedChunkEntry] = []

    func fullPlan(for html: String, documentID: UUID) -> HTMLSyntaxHighlighter.HighlightPlan {
        let fullRange = NSRange(location: 0, length: (html as NSString).length)
        return cachedPlan(for: html, range: fullRange, documentID: documentID) {
            buildPlan(for: html, coveredRange: fullRange, documentID: documentID)
        }
    }

    func rangePlan(for text: String, requestedRange: NSRange, documentID: UUID) -> HTMLSyntaxHighlighter.HighlightPlan {
        let normalizedRange = HTMLHighlightPlanBuilder.normalizedRange(for: text, requestedRange: requestedRange)
        guard normalizedRange.location != NSNotFound, normalizedRange.length > 0 else {
            return HTMLSyntaxHighlighter.HighlightPlan(coveredRange: NSRange(location: 0, length: 0), spans: [])
        }

        return cachedPlan(for: text, range: normalizedRange, documentID: documentID) {
            buildPlan(for: text, coveredRange: normalizedRange, documentID: documentID)
        }
    }

    func invalidate(
        documentID: UUID,
        editRange: NSRange,
        replacementUTF16Length: Int,
        newTextLength: Int
    ) {
        let planInvalidationStart = max(0, editRange.location - 256)
        let chunkInvalidationStart = HTMLHighlightPlanBuilder.chunkStart(for: planInvalidationStart)
        let planInvalidationEnd = max(planInvalidationStart, editRange.location + max(editRange.length, replacementUTF16Length) + 256)
        let chunkInvalidationEnd = HTMLHighlightPlanBuilder.chunkEnd(forExclusiveLocation: planInvalidationEnd)
        let lengthDelta = replacementUTF16Length - editRange.length

        if abs(lengthDelta) > HTMLHighlightPlanBuilder.plannerChunkSize * 8 {
            clear(documentID: documentID)
            return
        }

        if lengthDelta == 0 {
            let planInvalidationRange = NSRange(location: planInvalidationStart, length: max(0, planInvalidationEnd - planInvalidationStart))
            let chunkInvalidationRange = NSRange(location: chunkInvalidationStart, length: max(0, chunkInvalidationEnd - chunkInvalidationStart))

            cachedPlans.removeAll {
                $0.key.documentID == documentID &&
                NSIntersectionRange($0.key.range, planInvalidationRange).length > 0
            }

            cachedChunks.removeAll {
                $0.key.documentID == documentID &&
                NSIntersectionRange($0.key.range, chunkInvalidationRange).length > 0
            }
        } else {
            cachedPlans.removeAll {
                $0.key.documentID == documentID
            }

            cachedChunks.removeAll {
                $0.key.documentID == documentID &&
                NSMaxRange($0.key.range) > chunkInvalidationStart
            }
        }

        if newTextLength <= planInvalidationStart {
            clear(documentID: documentID)
        }
    }

    func clear(documentID: UUID) {
        cachedPlans.removeAll { $0.key.documentID == documentID }
        cachedChunks.removeAll { $0.key.documentID == documentID }
    }

    func debugCounts(documentID: UUID) -> (plans: Int, chunks: Int) {
        (
            plans: cachedPlans.filter { $0.key.documentID == documentID }.count,
            chunks: cachedChunks.filter { $0.key.documentID == documentID }.count
        )
    }

    private func cachedPlan(
        for text: String,
        range: NSRange,
        documentID: UUID,
        build: () -> HTMLSyntaxHighlighter.HighlightPlan
    ) -> HTMLSyntaxHighlighter.HighlightPlan {
        let key = PlannerCacheKey(
            documentID: documentID,
            textLength: text.utf16.count,
            range: range,
            fingerprint: textFingerprint(text, range: range)
        )

        if let exactIndex = cachedPlans.firstIndex(where: { $0.key == key }) {
            let entry = cachedPlans.remove(at: exactIndex)
            cachedPlans.append(entry)
            return entry.plan
        }

        if let coveringIndex = cachedPlans.firstIndex(where: {
            $0.key.documentID == key.documentID &&
            $0.key.textLength == key.textLength &&
            NSLocationInRange(range.location, $0.key.range) &&
            NSMaxRange(range) <= NSMaxRange($0.key.range) &&
            textFingerprint(text, range: $0.key.range) == $0.key.fingerprint
        }) {
            let entry = cachedPlans.remove(at: coveringIndex)
            cachedPlans.append(entry)
            return entry.plan
        }

        let plan = build()
        cachedPlans.append(CachedPlanEntry(key: key, plan: plan))
        if cachedPlans.count > 24 {
            cachedPlans.removeFirst(cachedPlans.count - 24)
        }
        return plan
    }

    private func buildPlan(for text: String, coveredRange: NSRange, documentID: UUID) -> HTMLSyntaxHighlighter.HighlightPlan {
        let nsText = text as NSString
        guard coveredRange.location != NSNotFound,
              coveredRange.length > 0,
              coveredRange.location >= 0,
              NSMaxRange(coveredRange) <= nsText.length else {
            return HTMLSyntaxHighlighter.HighlightPlan(coveredRange: NSRange(location: 0, length: 0), spans: [])
        }

        var spans: [HTMLSyntaxHighlighter.HighlightSpan] = []
        spans.reserveCapacity(max(32, coveredRange.length / 16))

        var scannerState: HTMLHighlightScannerState = .text
        for chunkRange in HTMLHighlightPlanBuilder.chunkRanges(for: coveredRange) {
            let chunk = cachedChunk(for: text, range: chunkRange, inputState: scannerState, documentID: documentID) {
                HTMLHighlightPlanBuilder.buildChunk(in: nsText, range: chunkRange, initialState: scannerState)
            }
            spans.append(contentsOf: chunk.spans)
            scannerState = chunk.endState
        }

        return HTMLSyntaxHighlighter.HighlightPlan(
            coveredRange: coveredRange,
            spans: HTMLHighlightPlanBuilder.coalesce(spans)
        )
    }

    private func cachedChunk(
        for text: String,
        range: NSRange,
        inputState: HTMLHighlightScannerState,
        documentID: UUID,
        build: () -> HTMLHighlightChunkResult
    ) -> HTMLHighlightChunkResult {
        let key = PlannerChunkCacheKey(
            documentID: documentID,
            textLength: text.utf16.count,
            range: range,
            fingerprint: textFingerprint(text, range: range),
            inputState: inputState
        )

        if let hitIndex = cachedChunks.firstIndex(where: { $0.key == key }) {
            let entry = cachedChunks.remove(at: hitIndex)
            cachedChunks.append(entry)
            return entry.result
        }

        let result = build()
        cachedChunks.append(CachedChunkEntry(key: key, result: result))
        if cachedChunks.count > 192 {
            cachedChunks.removeFirst(cachedChunks.count - 192)
        }
        return result
    }

    private func textFingerprint(_ text: String, range: NSRange) -> Int {
        let nsText = text as NSString
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= nsText.length else {
            return 0
        }

        let sample = nsText.substring(with: range)
        var hasher = Hasher()
        hasher.combine(range.location)
        hasher.combine(range.length)
        hasher.combine(sample)
        return hasher.finalize()
    }
}

private enum HTMLHighlightPlanBuilder {
    static let plannerChunkSize = 512

    static func fullPlan(for html: String) -> HTMLSyntaxHighlighter.HighlightPlan {
        let nsHTML = html as NSString
        return buildPlan(in: nsHTML, coveredRange: NSRange(location: 0, length: nsHTML.length))
    }

    static func rangePlan(for text: String, requestedRange: NSRange) -> HTMLSyntaxHighlighter.HighlightPlan {
        let nsText = text as NSString
        let normalized = normalizedRange(for: text, requestedRange: requestedRange)
        guard normalized.location != NSNotFound, normalized.length > 0 else {
            return HTMLSyntaxHighlighter.HighlightPlan(coveredRange: NSRange(location: 0, length: 0), spans: [])
        }
        return buildPlan(in: nsText, coveredRange: normalized)
    }

    static func normalizedRange(for text: String, requestedRange: NSRange) -> NSRange {
        let nsText = text as NSString
        let textLength = nsText.length

        guard textLength > 0,
              requestedRange.location != NSNotFound,
              requestedRange.location >= 0,
              requestedRange.location < textLength else {
            return NSRange(location: 0, length: 0)
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

        return expandedRange
    }

    static func buildPlan(in text: NSString, coveredRange: NSRange) -> HTMLSyntaxHighlighter.HighlightPlan {
        guard coveredRange.location != NSNotFound,
              coveredRange.length > 0,
              coveredRange.location >= 0,
              NSMaxRange(coveredRange) <= text.length else {
            return HTMLSyntaxHighlighter.HighlightPlan(coveredRange: NSRange(location: 0, length: 0), spans: [])
        }

        var spans: [HTMLSyntaxHighlighter.HighlightSpan] = []
        spans.reserveCapacity(max(32, coveredRange.length / 16))
        var scannerState: HTMLHighlightScannerState = .text

        for chunkRange in chunkRanges(for: coveredRange) {
            let chunk = buildChunk(in: text, range: chunkRange, initialState: scannerState)
            spans.append(contentsOf: chunk.spans)
            scannerState = chunk.endState
        }

        return HTMLSyntaxHighlighter.HighlightPlan(coveredRange: coveredRange, spans: coalesce(spans))
    }

    static func chunkRanges(for coveredRange: NSRange) -> [NSRange] {
        guard coveredRange.location != NSNotFound, coveredRange.length > 0 else { return [] }

        var ranges: [NSRange] = []
        ranges.reserveCapacity(max(1, coveredRange.length / plannerChunkSize + 1))

        let coveredEnd = NSMaxRange(coveredRange)
        var cursor = coveredRange.location

        while cursor < coveredEnd {
            let nextBoundary = ((cursor / plannerChunkSize) + 1) * plannerChunkSize
            let chunkEnd = min(coveredEnd, max(cursor + 1, nextBoundary))
            ranges.append(NSRange(location: cursor, length: chunkEnd - cursor))
            cursor = chunkEnd
        }

        return ranges
    }

    static func chunkStart(for location: Int) -> Int {
        guard location > 0 else { return 0 }
        return (location / plannerChunkSize) * plannerChunkSize
    }

    static func chunkEnd(forExclusiveLocation location: Int) -> Int {
        guard location > 0 else { return plannerChunkSize }
        return ((max(0, location - 1) / plannerChunkSize) + 1) * plannerChunkSize
    }

    static func buildChunk(
        in text: NSString,
        range: NSRange,
        initialState: HTMLHighlightScannerState
    ) -> HTMLHighlightChunkResult {
        guard range.location != NSNotFound,
              range.length > 0,
              range.location >= 0,
              NSMaxRange(range) <= text.length else {
            return HTMLHighlightChunkResult(endState: initialState, spans: [])
        }

        var spans: [HTMLSyntaxHighlighter.HighlightSpan] = []
        spans.reserveCapacity(max(8, range.length / 24))

        var state = initialState
        var activeRole: HTMLSyntaxHighlighter.HighlightRole?
        var activeStart = 0
        var activeEnd = 0

        func flushActiveSpan() {
            guard let role = activeRole, activeEnd > activeStart else { return }
            spans.append(.init(range: NSRange(location: activeStart, length: activeEnd - activeStart), role: role))
            activeRole = nil
        }

        func emit(role: HTMLSyntaxHighlighter.HighlightRole, at location: Int) {
            if activeRole == role, activeEnd == location {
                activeEnd += 1
                return
            }

            flushActiveSpan()
            activeRole = role
            activeStart = location
            activeEnd = location + 1
        }

        let end = NSMaxRange(range)
        var index = range.location
        while index < end {
            let current = text.character(at: index)

            switch state {
            case .text:
                flushActiveSpan()
                if current == codeUnit("<") {
                    emit(role: .tag, at: index)
                    state = .afterTagOpen
                }

            case .afterTagOpen:
                if current == codeUnit("/") {
                    emit(role: .tag, at: index)
                    state = .tagName
                } else if isTagNameCharacter(current) {
                    emit(role: .tag, at: index)
                    state = .tagName
                } else {
                    flushActiveSpan()
                    state = .text
                }

            case .tagName:
                if isTagNameCharacter(current) {
                    emit(role: .tag, at: index)
                } else if isWhitespace(current) {
                    flushActiveSpan()
                    state = .insideTag
                } else if current == codeUnit(">") {
                    emit(role: .tag, at: index)
                    flushActiveSpan()
                    state = .text
                } else if current == codeUnit("/") {
                    emit(role: .tag, at: index)
                    flushActiveSpan()
                    state = .insideTag
                } else {
                    flushActiveSpan()
                    state = .insideTag
                }

            case .insideTag:
                flushActiveSpan()
                if isWhitespace(current) {
                    break
                } else if current == codeUnit(">") {
                    emit(role: .tag, at: index)
                    flushActiveSpan()
                    state = .text
                } else if current == codeUnit("/") {
                    emit(role: .tag, at: index)
                    flushActiveSpan()
                } else if isAttributeNameCharacter(current) {
                    emit(role: .attributeName, at: index)
                    state = .attributeName
                }

            case .attributeName:
                if isAttributeNameCharacter(current) {
                    emit(role: .attributeName, at: index)
                } else if isWhitespace(current) {
                    flushActiveSpan()
                    state = .afterAttributeName
                } else if current == codeUnit("=") {
                    flushActiveSpan()
                    state = .beforeAttributeValue
                } else if current == codeUnit(">") {
                    flushActiveSpan()
                    emit(role: .tag, at: index)
                    flushActiveSpan()
                    state = .text
                } else if current == codeUnit("/") {
                    flushActiveSpan()
                    emit(role: .tag, at: index)
                    flushActiveSpan()
                    state = .insideTag
                } else {
                    flushActiveSpan()
                    state = .insideTag
                }

            case .afterAttributeName:
                flushActiveSpan()
                if isWhitespace(current) {
                    break
                } else if current == codeUnit("=") {
                    state = .beforeAttributeValue
                } else if current == codeUnit(">") {
                    emit(role: .tag, at: index)
                    flushActiveSpan()
                    state = .text
                } else if current == codeUnit("/") {
                    emit(role: .tag, at: index)
                    flushActiveSpan()
                    state = .insideTag
                } else if isAttributeNameCharacter(current) {
                    emit(role: .attributeName, at: index)
                    state = .attributeName
                } else {
                    state = .insideTag
                }

            case .beforeAttributeValue:
                flushActiveSpan()
                if isWhitespace(current) {
                    break
                } else if current == codeUnit("\"") || current == codeUnit("'") {
                    emit(role: .attributeValue, at: index)
                    state = .quotedAttributeValue(current)
                } else if current == codeUnit(">") {
                    emit(role: .tag, at: index)
                    flushActiveSpan()
                    state = .text
                } else {
                    emit(role: .attributeValue, at: index)
                    state = .unquotedAttributeValue
                }

            case .quotedAttributeValue(let quote):
                emit(role: .attributeValue, at: index)
                if current == quote {
                    flushActiveSpan()
                    state = .insideTag
                }

            case .unquotedAttributeValue:
                if isWhitespace(current) {
                    flushActiveSpan()
                    state = .insideTag
                } else if current == codeUnit(">") {
                    flushActiveSpan()
                    emit(role: .tag, at: index)
                    flushActiveSpan()
                    state = .text
                } else {
                    emit(role: .attributeValue, at: index)
                }
            }

            index += 1
        }

        flushActiveSpan()
        return HTMLHighlightChunkResult(endState: state, spans: spans)
    }

    static func coalesce(_ spans: [HTMLSyntaxHighlighter.HighlightSpan]) -> [HTMLSyntaxHighlighter.HighlightSpan] {
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
