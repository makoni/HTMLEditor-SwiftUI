#if os(macOS)
import Foundation

/// Document-size boundaries between the editor's three runtime regimes, and the
/// radius caches are invalidated over around an edit.
///
/// These were spelled as literals at eleven sites across three files, including
/// one outside this file entirely, and the invalidation radius shared its value
/// with `HTMLEditorHighlightCoverage.blockSize` while meaning something else —
/// a trap for whoever tuned one of them.
enum HTMLEditorDocumentSize {
    /// Above this the editor stops building whole-document plans and works
    /// viewport-first.  Shared with the highlighter's own full-pass limit.
    static let viewportFirst = HTMLSyntaxHighlighter.maxHighlightLength

    /// Above this it switches to conservative behaviour: tighter budgets,
    /// tags-only repaint while typing, scroll-idle semantic work.
    static let conservative = 150_000

    /// How far either side of an edit cached plans and chunks are dropped
    /// before the remainder is remapped.
    static let editInvalidationRadius = 256
}

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
}

extension HTMLEditor {
    nonisolated static func refreshStrategy(
        oldLength: Int,
        newLength: Int,
        editRangeLength: Int,
        replacementLength: Int
    ) -> HTMLEditorRefreshStrategy {
        if max(oldLength, newLength) > HTMLEditorDocumentSize.viewportFirst {
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
        if textLength > HTMLEditorDocumentSize.conservative {
            return HTMLEditorHighlightBudget(
                visibleExpansion: 80,
                fullPlanVisibleExpansion: 120,
                prewarmEnabled: false,
                prewarmDelayNanoseconds: 125_000_000,
                cachedRangePlanLimit: 6
            )
        }

        if textLength > HTMLEditorDocumentSize.viewportFirst {
            return HTMLEditorHighlightBudget(
                visibleExpansion: 120,
                fullPlanVisibleExpansion: 180,
                prewarmEnabled: false,
                prewarmDelayNanoseconds: 100_000_000,
                cachedRangePlanLimit: 8
            )
        }

        return HTMLEditorHighlightBudget(
            visibleExpansion: 200,
            fullPlanVisibleExpansion: 300,
            prewarmEnabled: true,
            prewarmDelayNanoseconds: 75_000_000,
            cachedRangePlanLimit: 16
        )
    }

    nonisolated static func bindingSyncDelay(forTextLength textLength: Int) -> UInt64? {
        if textLength > HTMLEditorDocumentSize.conservative {
            return 225_000_000
        }

        if textLength > HTMLEditorDocumentSize.viewportFirst {
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
            return textLength > HTMLEditorDocumentSize.conservative ? 150_000_000 : 90_000_000
        case .scroll:
            if textLength > HTMLEditorDocumentSize.conservative {
                return 85_000_000
            }
            if textLength > HTMLEditorDocumentSize.viewportFirst {
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
        return textLength > HTMLEditorDocumentSize.conservative && strategy != .incremental ? .tagsOnly : .full
    }

    nonisolated static func shouldPreserveVisibleHighlight(
        detail: HTMLEditorHighlightDetail,
        trigger: HTMLEditorHighlightTrigger,
        hasExistingOverlay: Bool
    ) -> Bool {
        detail == .tagsOnly && trigger == .edit && hasExistingOverlay
    }

    nonisolated static func shouldUseTwoPhaseEditing(forTextLength textLength: Int) -> Bool {
        textLength > HTMLEditorDocumentSize.viewportFirst
    }

    nonisolated static func localDirtyHighlightLimit(forTextLength textLength: Int) -> Int {
        textLength > HTMLEditorDocumentSize.conservative ? 768 : 1_024
    }

    nonisolated static func immediateEditHighlightLimit(forTextLength textLength: Int) -> Int {
        textLength > HTMLEditorDocumentSize.conservative ? 256 : 384
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

    nonisolated static func editBurstCoalescingDelay(forTextLength textLength: Int) -> UInt64? {
        if textLength > HTMLEditorDocumentSize.conservative {
            return 40_000_000
        }

        if textLength > HTMLEditorDocumentSize.viewportFirst {
            return 25_000_000
        }

        return nil
    }

    nonisolated static func shouldUseScrollIdleMode(forTextLength textLength: Int) -> Bool {
        textLength > HTMLEditorDocumentSize.viewportFirst
    }

    nonisolated static func shouldUseNonContiguousLayout(forTextLength textLength: Int) -> Bool {
        textLength > HTMLEditorDocumentSize.viewportFirst
    }

}
#endif
