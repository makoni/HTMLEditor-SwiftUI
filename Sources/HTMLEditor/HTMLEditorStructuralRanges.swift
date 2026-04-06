#if os(macOS)
import Foundation

extension HTMLEditor {
    nonisolated static func structuralAlignmentRadius(forTextLength textLength: Int) -> Int {
        textLength > 150_000 ? 160 : 224
    }

    nonisolated static func structuralDirtyRange(
        for editRange: NSRange,
        replacementLength: Int,
        in text: NSString,
        expansion: Int
    ) -> NSRange {
        let baseRange = HTMLEditorVisibleHighlightState.dirtyRange(
            for: editRange,
            replacementLength: replacementLength,
            newTextLength: text.length,
            expansion: expansion
        )
        return alignedHighlightRange(baseRange, in: text)
    }

    nonisolated static func alignedHighlightRange(_ range: NSRange, in text: NSString) -> NSRange {
        guard range.location != NSNotFound, range.length > 0, text.length > 0 else {
            return NSRange(location: 0, length: 0)
        }

        let radius = structuralAlignmentRadius(forTextLength: text.length)
        let start = alignedStart(for: range.location, in: text, radius: radius)
        let end = alignedEnd(for: NSMaxRange(range), in: text, radius: radius)
        return NSRange(location: start, length: max(0, end - start))
    }

    private nonisolated static func alignedStart(for location: Int, in text: NSString, radius: Int) -> Int {
        let lowerBound = max(0, location - radius)
        var index = max(0, min(location, text.length))

        while index > lowerBound {
            let previousIndex = index - 1
            let character = text.character(at: previousIndex)
            if isHardBoundary(character) {
                return boundaryStartIndex(after: character, at: previousIndex)
            }
            index -= 1
        }

        return lowerBound
    }

    private nonisolated static func alignedEnd(for location: Int, in text: NSString, radius: Int) -> Int {
        let upperBound = min(text.length, location + radius)
        var index = max(0, min(location, text.length))

        while index < upperBound {
            let character = text.character(at: index)
            if isHardBoundary(character) {
                return boundaryEndIndex(after: character, at: index, textLength: text.length)
            }
            index += 1
        }

        return upperBound
    }

    private nonisolated static func isHardBoundary(_ character: unichar) -> Bool {
        switch character {
        case 10, 13, 32, 34, 39, 60, 62, 9:
            return true
        default:
            return false
        }
    }

    private nonisolated static func boundaryStartIndex(after character: unichar, at index: Int) -> Int {
        switch character {
        case 60:
            return index
        default:
            return index + 1
        }
    }

    private nonisolated static func boundaryEndIndex(after character: unichar, at index: Int, textLength: Int) -> Int {
        min(textLength, index + 1)
    }
}
#endif
