import Testing
import Foundation
@testable import HTMLEditor

@Test func testRefreshStrategyClassifiesSmallEditAsIncremental() async throws {
    let strategy = HTMLEditor.refreshStrategy(
        oldLength: 1_000,
        newLength: 1_001,
        editRangeLength: 1,
        replacementLength: 2
    )
    #expect(strategy == .incremental)
}

@Test func testRefreshStrategyClassifiesMediumPaste() async throws {
    let strategy = HTMLEditor.refreshStrategy(
        oldLength: 4_000,
        newLength: 4_320,
        editRangeLength: 0,
        replacementLength: 320
    )
    #expect(strategy == .mediumChange)
}

@Test func testRefreshStrategyClassifiesMajorPaste() async throws {
    let strategy = HTMLEditor.refreshStrategy(
        oldLength: 4_000,
        newLength: 6_500,
        editRangeLength: 0,
        replacementLength: 2_500
    )
    #expect(strategy == .majorChange)
}

@Test func testRefreshStrategyClassifiesLargeDocument() async throws {
    let strategy = HTMLEditor.refreshStrategy(
        oldLength: 60_000,
        newLength: 60_010,
        editRangeLength: 5,
        replacementLength: 15
    )
    #expect(strategy == .largeDocument)
}

@Test func testHighlightBudgetTightensForLargeDocuments() async throws {
    let normal = HTMLEditor.highlightBudget(forTextLength: 10_000)
    let large = HTMLEditor.highlightBudget(forTextLength: 80_000)
    let huge = HTMLEditor.highlightBudget(forTextLength: 180_000)

    #expect(normal.prewarmEnabled == true)
    #expect(large.prewarmEnabled == false)
    #expect(huge.prewarmEnabled == false)
    #expect(large.cachedRangePlanLimit < normal.cachedRangePlanLimit)
    #expect(huge.cachedRangePlanLimit <= large.cachedRangePlanLimit)
    #expect(huge.highlightedRangeLimit <= large.highlightedRangeLimit)
}

@Test func testBindingSyncIsDeferredForLargeDocuments() async throws {
    #expect(HTMLEditor.bindingSyncDelay(forTextLength: 10_000) == nil)
    #expect(HTMLEditor.bindingSyncDelay(forTextLength: 80_000) != nil)
    #expect(HTMLEditor.bindingSyncDelay(forTextLength: 180_000) != nil)
}

@Test func testScrollHighlightDelaySlowsDownForLargeDocuments() async throws {
    let normal = HTMLEditor.semanticHighlightDelay(forTextLength: 10_000, trigger: .scroll)
    let large = HTMLEditor.semanticHighlightDelay(forTextLength: 80_000, trigger: .scroll)
    let huge = HTMLEditor.semanticHighlightDelay(forTextLength: 180_000, trigger: .scroll)

    #expect(normal < large)
    #expect(large < huge)
}

@Test func testEditTriggerKeepsFastHighlightDelay() async throws {
    let delay = HTMLEditor.semanticHighlightDelay(forTextLength: 180_000, trigger: .edit)
    #expect(delay == 10_000_000)
}

@Test func testHugeDocumentEditUsesTagsOnlyDetail() async throws {
    let detail = HTMLEditor.highlightDetail(
        forTextLength: 180_000,
        strategy: .largeDocument,
        trigger: .edit
    )
    #expect(detail == .tagsOnly)
}

@Test func testRecoveryAndScrollUseFullDetail() async throws {
    #expect(
        HTMLEditor.highlightDetail(
            forTextLength: 180_000,
            strategy: .largeDocument,
            trigger: .scroll
        ) == .full
    )
    #expect(
        HTMLEditor.highlightDetail(
            forTextLength: 180_000,
            strategy: .largeDocument,
            trigger: .recovery
        ) == .full
    )
}

@Test func testTagsOnlyEditCanPreserveExistingVisibleHighlight() async throws {
    #expect(
        HTMLEditor.shouldPreserveVisibleHighlight(
            detail: .tagsOnly,
            trigger: .edit,
            hasExistingOverlay: true
        ) == true
    )
    #expect(
        HTMLEditor.shouldPreserveVisibleHighlight(
            detail: .tagsOnly,
            trigger: .edit,
            hasExistingOverlay: false
        ) == false
    )
    #expect(
        HTMLEditor.shouldPreserveVisibleHighlight(
            detail: .full,
            trigger: .edit,
            hasExistingOverlay: true
        ) == false
    )
}

@Test func testTwoPhaseEditingPolicyAppliesOnlyToLargeDocuments() async throws {
    #expect(HTMLEditor.shouldUseTwoPhaseEditing(forTextLength: 10_000) == false)
    #expect(HTMLEditor.shouldUseTwoPhaseEditing(forTextLength: 80_000) == true)
}

@Test func testLocalDirtyHighlightRangeIsClamped() async throws {
    let dirtyRange = NSRange(location: 1_000, length: 800)
    let clamped = HTMLEditor.localDirtyHighlightRange(
        around: dirtyRange,
        textLength: 5_000,
        maxLength: 512
    )

    #expect(clamped.length == 512)
    #expect(clamped.location <= dirtyRange.location + dirtyRange.length / 2)
    #expect(NSMaxRange(clamped) >= dirtyRange.location + dirtyRange.length / 2)
}
