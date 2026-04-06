#if os(macOS)
import AppKit
import Foundation

enum HTMLHighlightPlanBuilder {
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

    static func alignedChunkWindow(for coveredRange: NSRange, textLength: Int) -> NSRange {
        guard coveredRange.location != NSNotFound, coveredRange.length > 0, textLength > 0 else {
            return NSRange(location: 0, length: 0)
        }

        let start = chunkStart(for: coveredRange.location)
        let end = min(textLength, chunkEnd(forExclusiveLocation: NSMaxRange(coveredRange)))
        return NSRange(location: start, length: max(0, end - start))
    }

    static func chunkStart(for location: Int) -> Int {
        guard location > 0 else { return 0 }
        return (location / plannerChunkSize) * plannerChunkSize
    }

    static func chunkEnd(forExclusiveLocation location: Int) -> Int {
        guard location > 0 else { return plannerChunkSize }
        return ((max(0, location - 1) / plannerChunkSize) + 1) * plannerChunkSize
    }

    static func trimmedSpans(
        _ spans: [HTMLSyntaxHighlighter.HighlightSpan],
        to coveredRange: NSRange
    ) -> [HTMLSyntaxHighlighter.HighlightSpan] {
        spans.compactMap { span in
            let intersection = NSIntersectionRange(span.range, coveredRange)
            guard intersection.location != NSNotFound, intersection.length > 0 else { return nil }
            return .init(range: intersection, role: span.role)
        }
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
#endif
