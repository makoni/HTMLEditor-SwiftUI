#if os(macOS)
import Foundation

struct HTMLEditorVisibleHighlightState {
    private enum OffsetAffinity {
        case lowerBound
        case upperBound
    }

    private(set) var plan: HTMLSyntaxHighlighter.HighlightPlan?
    private(set) var dirtyRange: NSRange?

    var hasOverlay: Bool {
        plan != nil
    }

    mutating func clear() {
        plan = nil
        dirtyRange = nil
    }

    mutating func replace(with plan: HTMLSyntaxHighlighter.HighlightPlan?) {
        self.plan = plan
        dirtyRange = nil
    }

    mutating func storeOverlayPlan(_ plan: HTMLSyntaxHighlighter.HighlightPlan?) {
        self.plan = plan
    }

    mutating func remapAfterEdit(
        editRange: NSRange,
        replacementUTF16Length: Int,
        newTextLength: Int,
        dirtyExpansion: Int
    ) -> HTMLSyntaxHighlighter.HighlightPlan? {
        let newDirtyRange = Self.dirtyRange(
            for: editRange,
            replacementLength: replacementUTF16Length,
            newTextLength: newTextLength,
            expansion: dirtyExpansion
        )

        let remappedExistingDirtyRange = dirtyRange.flatMap {
            Self.remapRange(
                $0,
                editRange: editRange,
                replacementLength: replacementUTF16Length,
                newTextLength: newTextLength
            )
        }
        let combinedDirtyRange = remappedExistingDirtyRange.map {
            Self.union($0, newDirtyRange)
        } ?? newDirtyRange

        dirtyRange = combinedDirtyRange

        guard let plan else { return nil }

        let remappedPlan = Self.remapPlan(
            plan,
            editRange: editRange,
            replacementLength: replacementUTF16Length,
            newTextLength: newTextLength,
            dirtyRange: combinedDirtyRange
        )
        self.plan = remappedPlan
        return remappedPlan
    }

    static func remapPlan(
        _ plan: HTMLSyntaxHighlighter.HighlightPlan,
        editRange: NSRange,
        replacementLength: Int,
        newTextLength: Int,
        dirtyRange: NSRange
    ) -> HTMLSyntaxHighlighter.HighlightPlan? {
        guard let coveredRange = remapRange(
            plan.coveredRange,
            editRange: editRange,
            replacementLength: replacementLength,
            newTextLength: newTextLength
        ) else {
            return nil
        }

        let remappedSpans = plan.spans.compactMap { span -> HTMLSyntaxHighlighter.HighlightSpan? in
            guard let remappedRange = remapRange(
                span.range,
                editRange: editRange,
                replacementLength: replacementLength,
                newTextLength: newTextLength
            ) else {
                return nil
            }

            let overlap = NSIntersectionRange(remappedRange, dirtyRange)
            if overlap.location != NSNotFound, overlap.length > 0 {
                return nil
            }

            return HTMLSyntaxHighlighter.HighlightSpan(range: remappedRange, role: span.role)
        }

        return HTMLSyntaxHighlighter.HighlightPlan(coveredRange: coveredRange, spans: remappedSpans)
    }

    static func dirtyRange(
        for editRange: NSRange,
        replacementLength: Int,
        newTextLength: Int,
        expansion: Int
    ) -> NSRange {
        guard newTextLength > 0 else {
            return NSRange(location: 0, length: 0)
        }

        let anchorLocation = min(editRange.location, max(0, newTextLength - 1))
        let anchorLength = max(replacementLength, 1)
        let dirtyStart = max(0, anchorLocation - expansion)
        let dirtyEnd = min(newTextLength, anchorLocation + anchorLength + expansion)
        return NSRange(location: dirtyStart, length: max(0, dirtyEnd - dirtyStart))
    }

    static func remapRange(
        _ range: NSRange,
        editRange: NSRange,
        replacementLength: Int,
        newTextLength: Int
    ) -> NSRange? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }

        let start = remapOffset(
            range.location,
            editRange: editRange,
            replacementLength: replacementLength,
            affinity: .lowerBound
        )
        let end = remapOffset(
            NSMaxRange(range),
            editRange: editRange,
            replacementLength: replacementLength,
            affinity: .upperBound
        )

        let clampedStart = min(max(0, start), newTextLength)
        let clampedEnd = min(max(clampedStart, end), newTextLength)
        guard clampedEnd > clampedStart else { return nil }
        return NSRange(location: clampedStart, length: clampedEnd - clampedStart)
    }

    private static func remapOffset(
        _ offset: Int,
        editRange: NSRange,
        replacementLength: Int,
        affinity: OffsetAffinity
    ) -> Int {
        let editStart = editRange.location
        let editEnd = NSMaxRange(editRange)
        let delta = replacementLength - editRange.length

        if editRange.length == 0 {
            if offset < editStart {
                return offset
            }
            if offset > editStart {
                return offset + delta
            }
            return affinity == .lowerBound ? editStart + replacementLength : editStart
        }

        if offset < editStart {
            return offset
        }
        if offset > editEnd {
            return offset + delta
        }
        if offset == editEnd {
            return editStart + replacementLength
        }

        return affinity == .lowerBound ? editStart : editStart + replacementLength
    }

    private static func union(_ lhs: NSRange, _ rhs: NSRange) -> NSRange {
        let start = min(lhs.location, rhs.location)
        let end = max(NSMaxRange(lhs), NSMaxRange(rhs))
        return NSRange(location: start, length: end - start)
    }
}
#endif
