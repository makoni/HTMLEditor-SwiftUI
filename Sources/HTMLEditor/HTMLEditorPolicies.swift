#if os(macOS)
import Foundation

enum HTMLEditorRefreshStrategy {
    case incremental
    case mediumChange
    case majorChange
    case largeDocument
}

enum HTMLEditorHighlightTrigger {
    case scroll
    case edit
    case recovery
}

enum HTMLEditorHighlightDetail: Equatable {
    case full
    case tagsOnly
}

struct HTMLEditorHighlightBudget {
    let visibleExpansion: Int
    let fullPlanVisibleExpansion: Int
    let prewarmEnabled: Bool
    let prewarmDelayNanoseconds: UInt64
    let cachedRangePlanLimit: Int
    let highlightedRangeLimit: Int
}

extension HTMLEditor {
    nonisolated static func refreshStrategy(
        oldLength: Int,
        newLength: Int,
        editRangeLength: Int,
        replacementLength: Int
    ) -> HTMLEditorRefreshStrategy {
        if max(oldLength, newLength) > HTMLSyntaxHighlighter.maxHighlightLength {
            return .largeDocument
        }

        let lengthDelta = abs(newLength - oldLength)
        let editMagnitude = max(lengthDelta, max(editRangeLength, replacementLength))

        if oldLength == 0 || editMagnitude > 2_000 {
            return .majorChange
        }

        if editMagnitude > 200 {
            return .mediumChange
        }

        return .incremental
    }

    nonisolated static func highlightBudget(forTextLength textLength: Int) -> HTMLEditorHighlightBudget {
        if textLength > 150_000 {
            return HTMLEditorHighlightBudget(
                visibleExpansion: 80,
                fullPlanVisibleExpansion: 120,
                prewarmEnabled: false,
                prewarmDelayNanoseconds: 125_000_000,
                cachedRangePlanLimit: 6,
                highlightedRangeLimit: 4
            )
        }

        if textLength > HTMLSyntaxHighlighter.maxHighlightLength {
            return HTMLEditorHighlightBudget(
                visibleExpansion: 120,
                fullPlanVisibleExpansion: 180,
                prewarmEnabled: false,
                prewarmDelayNanoseconds: 100_000_000,
                cachedRangePlanLimit: 8,
                highlightedRangeLimit: 6
            )
        }

        return HTMLEditorHighlightBudget(
            visibleExpansion: 200,
            fullPlanVisibleExpansion: 300,
            prewarmEnabled: true,
            prewarmDelayNanoseconds: 75_000_000,
            cachedRangePlanLimit: 16,
            highlightedRangeLimit: 10
        )
    }

    nonisolated static func bindingSyncDelay(forTextLength textLength: Int) -> UInt64? {
        if textLength > 150_000 {
            return 225_000_000
        }

        if textLength > HTMLSyntaxHighlighter.maxHighlightLength {
            return 125_000_000
        }

        return nil
    }

    nonisolated static func semanticHighlightDelay(
        forTextLength textLength: Int,
        trigger: HTMLEditorHighlightTrigger
    ) -> UInt64 {
        switch trigger {
        case .edit:
            return 10_000_000
        case .recovery:
            return textLength > 150_000 ? 150_000_000 : 90_000_000
        case .scroll:
            if textLength > 150_000 {
                return 85_000_000
            }
            if textLength > HTMLSyntaxHighlighter.maxHighlightLength {
                return 45_000_000
            }
            return 10_000_000
        }
    }

    nonisolated static func highlightDetail(
        forTextLength textLength: Int,
        strategy: HTMLEditorRefreshStrategy,
        trigger: HTMLEditorHighlightTrigger
    ) -> HTMLEditorHighlightDetail {
        guard trigger == .edit else { return .full }
        return textLength > 150_000 && strategy != .incremental ? .tagsOnly : .full
    }

    nonisolated static func shouldPreserveVisibleHighlight(
        detail: HTMLEditorHighlightDetail,
        trigger: HTMLEditorHighlightTrigger,
        hasExistingOverlay: Bool
    ) -> Bool {
        detail == .tagsOnly && trigger == .edit && hasExistingOverlay
    }

    nonisolated static func shouldUseTwoPhaseEditing(forTextLength textLength: Int) -> Bool {
        textLength > HTMLSyntaxHighlighter.maxHighlightLength
    }

    nonisolated static func localDirtyHighlightLimit(forTextLength textLength: Int) -> Int {
        textLength > 150_000 ? 1_024 : 1_536
    }

    nonisolated static func localDirtyHighlightRange(
        around dirtyRange: NSRange,
        textLength: Int,
        maxLength: Int
    ) -> NSRange {
        guard dirtyRange.location != NSNotFound, dirtyRange.length > 0, textLength > 0 else {
            return NSRange(location: 0, length: 0)
        }

        guard dirtyRange.length > maxLength else {
            let end = min(textLength, NSMaxRange(dirtyRange))
            return NSRange(location: dirtyRange.location, length: max(0, end - dirtyRange.location))
        }

        let centeredStart = max(0, dirtyRange.location + (dirtyRange.length / 2) - (maxLength / 2))
        let start = min(centeredStart, max(0, textLength - maxLength))
        let end = min(textLength, start + maxLength)
        return NSRange(location: start, length: max(0, end - start))
    }

    nonisolated static func textIdentity(for text: String) -> Int {
        textIdentity(for: text as NSString)
    }

    nonisolated static func textIdentity(for text: NSString) -> Int {
        let length = text.length
        guard length > 0 else { return 0 }

        var hasher = Hasher()
        hasher.combine(length)
        hasher.combine(text.character(at: 0))
        if length > 1 { hasher.combine(text.character(at: length - 1)) }
        if length > 2 { hasher.combine(text.character(at: length / 2)) }
        return hasher.finalize()
    }
}
#endif
