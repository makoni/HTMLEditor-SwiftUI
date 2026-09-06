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

    /// Lower edge of the hysteresis band for the non-contiguous layout switch.
    static let nonContiguousLayoutOff = 40_000
}

/// How big the edit was.  Deliberately independent of document size: the two
/// used to be folded into one enum whose document-size check came first, so any
/// document over the viewport-first threshold reported `.largeDocument` no
/// matter how small the edit.  That made the incremental path unreachable for
/// exactly the documents the incremental machinery exists for — every keystroke
/// dropped the whole planner cache — and left a dead sub-expression in
/// `highlightDetail`, which could then only ever return `.tagsOnly` while typing
/// in a conservative-regime document.
enum HTMLEditorEditMagnitude {
    case incremental
    case medium
    case major
}

/// Which runtime regime the document's size puts the editor in.
enum HTMLEditorSizeRegime {
    case full
    case viewportFirst
    case conservative
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
    nonisolated static func editMagnitude(
        oldLength: Int,
        newLength: Int,
        editRangeLength: Int,
        replacementLength: Int
    ) -> HTMLEditorEditMagnitude {
        let lengthDelta = abs(newLength - oldLength)
        let magnitude = max(lengthDelta, max(editRangeLength, replacementLength))

        // An empty starting document means the whole content just arrived.
        if oldLength == 0 || magnitude > 2_000 {
            return .major
        }

        if magnitude > 200 {
            return .medium
        }

        return .incremental
    }

    nonisolated static func sizeRegime(forTextLength textLength: Int) -> HTMLEditorSizeRegime {
        if textLength > HTMLEditorDocumentSize.conservative {
            return .conservative
        }
        if textLength > HTMLEditorDocumentSize.viewportFirst {
            return .viewportFirst
        }
        return .full
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

    /// Typing a single character in a huge document now keeps full detail, which
    /// is what this rule always said and never did: `strategy` could not be
    /// `.incremental` above the conservative threshold, so the size test alone
    /// decided the result.  Bulk edits there still drop to tags-only and recover
    /// through the delayed full-detail pass.
    nonisolated static func highlightDetail(
        forTextLength textLength: Int,
        magnitude: HTMLEditorEditMagnitude,
        trigger: HTMLEditorHighlightTrigger
    ) -> HTMLEditorHighlightDetail {
        guard trigger == .edit else { return .full }
        return sizeRegime(forTextLength: textLength) == .conservative && magnitude != .incremental
            ? .tagsOnly
            : .full
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

    /// Switching *back* to contiguous layout forces a full relayout — tens of
    /// milliseconds on a few hundred KB — so a document sitting on the threshold
    /// must not flip on every keystroke.  Turn on at the threshold, off only
    /// once the document has shrunk well below it.
    nonisolated static func shouldUseNonContiguousLayout(
        forTextLength textLength: Int,
        currentlyEnabled: Bool
    ) -> Bool {
        if currentlyEnabled {
            return textLength > HTMLEditorDocumentSize.nonContiguousLayoutOff
        }
        return textLength > HTMLEditorDocumentSize.viewportFirst
    }

}
#endif
