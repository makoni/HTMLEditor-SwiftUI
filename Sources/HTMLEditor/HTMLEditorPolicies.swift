#if os(macOS)
import Foundation

enum HTMLEditorRefreshStrategy {
    case incremental
    case mediumChange
    case majorChange
    case largeDocument
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
}
#endif
