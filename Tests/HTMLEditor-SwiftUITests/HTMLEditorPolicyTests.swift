import Testing
import Foundation
@testable import HTMLEditor

@Test func testEditMagnitudeClassifiesSmallEditAsIncremental() async throws {
    let magnitude = HTMLEditorPolicy.editMagnitude(
        oldLength: 1_000,
        newLength: 1_001,
        editRangeLength: 1,
        replacementLength: 2
    )
    #expect(magnitude == .incremental)
}

@Test func testEditMagnitudeClassifiesMediumPaste() async throws {
    let magnitude = HTMLEditorPolicy.editMagnitude(
        oldLength: 4_000,
        newLength: 4_320,
        editRangeLength: 0,
        replacementLength: 320
    )
    #expect(magnitude == .medium)
}

@Test func testEditMagnitudeClassifiesMajorPaste() async throws {
    let magnitude = HTMLEditorPolicy.editMagnitude(
        oldLength: 4_000,
        newLength: 6_500,
        editRangeLength: 0,
        replacementLength: 2_500
    )
    #expect(magnitude == .major)
}

@Test func testEditMagnitudeIgnoresDocumentSize() async throws {
    // The whole point of splitting the axes: a keystroke stays incremental no
    // matter how big the document is.  This used to report .largeDocument, which
    // dropped the entire planner cache on every character typed and pinned
    // highlightDetail to tags-only.
    let keystrokeInHugeDocument = HTMLEditorPolicy.editMagnitude(
        oldLength: 2_000_000,
        newLength: 2_000_001,
        editRangeLength: 0,
        replacementLength: 1
    )
    #expect(keystrokeInHugeDocument == .incremental)

    let keystrokeInSmallDocument = HTMLEditorPolicy.editMagnitude(
        oldLength: 200,
        newLength: 201,
        editRangeLength: 0,
        replacementLength: 1
    )
    #expect(keystrokeInSmallDocument == keystrokeInHugeDocument)

    // A bulk edit is still major, again regardless of document size.
    #expect(
        HTMLEditorPolicy.editMagnitude(
            oldLength: 2_000_000,
            newLength: 2_010_000,
            editRangeLength: 0,
            replacementLength: 10_000
        ) == .major
    )
}

@Test func testSizeRegimeTracksTheDocumentThresholds() async throws {
    #expect(HTMLEditorPolicy.sizeRegime(forTextLength: 10_000) == .full)
    #expect(HTMLEditorPolicy.sizeRegime(forTextLength: HTMLEditorDocumentSize.viewportFirst) == .full)
    #expect(HTMLEditorPolicy.sizeRegime(forTextLength: HTMLEditorDocumentSize.viewportFirst + 1) == .viewportFirst)
    #expect(HTMLEditorPolicy.sizeRegime(forTextLength: HTMLEditorDocumentSize.conservative) == .viewportFirst)
    #expect(HTMLEditorPolicy.sizeRegime(forTextLength: HTMLEditorDocumentSize.conservative + 1) == .conservative)
}

@Test func testKeystrokeInHugeDocumentKeepsFullDetail() async throws {
    // Previously unreachable: above the conservative threshold every edit was
    // classified .largeDocument, so this always came back .tagsOnly.
    let detail = HTMLEditorPolicy.highlightDetail(
        forTextLength: 2_000_000,
        magnitude: .incremental,
        trigger: .edit
    )
    #expect(detail == .full)
}

@Test func testHighlightBudgetTightensForLargeDocuments() async throws {
    let normal = HTMLEditorPolicy.highlightBudget(forTextLength: 10_000)
    let large = HTMLEditorPolicy.highlightBudget(forTextLength: 80_000)
    let huge = HTMLEditorPolicy.highlightBudget(forTextLength: 180_000)

    #expect(normal.prewarmEnabled == true)
    #expect(large.prewarmEnabled == false)
    #expect(huge.prewarmEnabled == false)
    #expect(large.cachedRangePlanLimit < normal.cachedRangePlanLimit)
    #expect(huge.cachedRangePlanLimit <= large.cachedRangePlanLimit)
}

@Test func testBindingSyncIsDeferredForLargeDocuments() async throws {
    #expect(HTMLEditorPolicy.bindingSyncDelay(forTextLength: 10_000) == nil)
    #expect(HTMLEditorPolicy.bindingSyncDelay(forTextLength: 80_000) != nil)
    #expect(HTMLEditorPolicy.bindingSyncDelay(forTextLength: 180_000) != nil)
}

@Test func testBindingSyncDelayGrowsWithTheDocument() async throws {
    // Publishing through the binding makes SwiftUI compare the old and new
    // values, and comparing multi-megabyte strings costs hundreds of
    // milliseconds on the main thread. The bigger the document, the rarer that
    // has to be.
    let large = HTMLEditorPolicy.bindingSyncDelay(forTextLength: 80_000)!
    let conservative = HTMLEditorPolicy.bindingSyncDelay(
        forTextLength: HTMLEditorDocumentSize.conservative + 1
    )!
    let veryLarge = HTMLEditorPolicy.bindingSyncDelay(
        forTextLength: HTMLEditorDocumentSize.veryLarge + 1
    )!

    #expect(large < conservative)
    #expect(conservative < veryLarge)
    // A pause inside a burst of typing must not trigger it on a huge document.
    #expect(veryLarge >= 1_000_000_000)
}

@Test func testScrollHighlightDelaySlowsDownForLargeDocuments() async throws {
    let normal = HTMLEditorPolicy.semanticHighlightDelay(forTextLength: 10_000, trigger: .scroll)
    let large = HTMLEditorPolicy.semanticHighlightDelay(forTextLength: 80_000, trigger: .scroll)
    let huge = HTMLEditorPolicy.semanticHighlightDelay(forTextLength: 180_000, trigger: .scroll)

    #expect(normal < large)
    #expect(large < huge)
}

@Test func testEditTriggerKeepsFastHighlightDelay() async throws {
    let delay = HTMLEditorPolicy.semanticHighlightDelay(forTextLength: 180_000, trigger: .edit)
    #expect(delay == 10_000_000)
}

@Test func testHugeDocumentEditUsesTagsOnlyDetail() async throws {
    let detail = HTMLEditorPolicy.highlightDetail(
        forTextLength: 180_000,
        magnitude: .major,
        trigger: .edit
    )
    #expect(detail == .tagsOnly)
}

@Test func testRecoveryAndScrollUseFullDetail() async throws {
    #expect(
        HTMLEditorPolicy.highlightDetail(
            forTextLength: 180_000,
            magnitude: .major,
            trigger: .scroll
        ) == .full
    )
    #expect(
        HTMLEditorPolicy.highlightDetail(
            forTextLength: 180_000,
            magnitude: .major,
            trigger: .recovery
        ) == .full
    )
}

@Test func testTagsOnlyEditCanPreserveExistingVisibleHighlight() async throws {
    #expect(
        HTMLEditorPolicy.shouldPreserveVisibleHighlight(
            detail: .tagsOnly,
            trigger: .edit,
            hasExistingOverlay: true
        ) == true
    )
    #expect(
        HTMLEditorPolicy.shouldPreserveVisibleHighlight(
            detail: .tagsOnly,
            trigger: .edit,
            hasExistingOverlay: false
        ) == false
    )
    #expect(
        HTMLEditorPolicy.shouldPreserveVisibleHighlight(
            detail: .full,
            trigger: .edit,
            hasExistingOverlay: true
        ) == false
    )
}

@Test func testTwoPhaseEditingPolicyAppliesOnlyToLargeDocuments() async throws {
    #expect(HTMLEditorPolicy.shouldUseTwoPhaseEditing(forTextLength: 10_000) == false)
    #expect(HTMLEditorPolicy.shouldUseTwoPhaseEditing(forTextLength: 80_000) == true)
}

@Test func testLocalDirtyHighlightLimitTightensForHugeDocuments() async throws {
    #expect(HTMLEditorPolicy.localDirtyHighlightLimit(forTextLength: 80_000) == 1_024)
    #expect(HTMLEditorPolicy.localDirtyHighlightLimit(forTextLength: 180_000) == 768)
}

@Test func testImmediateEditHighlightLimitStaysSmallerThanDeferredLocalPass() async throws {
    #expect(
        HTMLEditorPolicy.immediateEditHighlightLimit(forTextLength: 80_000) <
        HTMLEditorPolicy.localDirtyHighlightLimit(forTextLength: 80_000)
    )
    #expect(
        HTMLEditorPolicy.immediateEditHighlightLimit(forTextLength: 180_000) <
        HTMLEditorPolicy.localDirtyHighlightLimit(forTextLength: 180_000)
    )
}

@Test func testEditBurstCoalescingDelayAppliesOnlyToLargeDocuments() async throws {
    #expect(HTMLEditorPolicy.editBurstCoalescingDelay(forTextLength: 10_000) == nil)
    #expect(HTMLEditorPolicy.editBurstCoalescingDelay(forTextLength: 80_000) == 25_000_000)
    #expect(HTMLEditorPolicy.editBurstCoalescingDelay(forTextLength: 180_000) == 40_000_000)
}

@Test func testScrollIdleModeAppliesOnlyToLargeDocuments() async throws {
    #expect(HTMLEditorPolicy.shouldUseScrollIdleMode(forTextLength: 10_000) == false)
    #expect(HTMLEditorPolicy.shouldUseScrollIdleMode(forTextLength: 80_000) == true)
}

@Test func testNonContiguousLayoutAppliesOnlyToLargeDocuments() async throws {
    #expect(
        HTMLEditorPolicy.shouldUseNonContiguousLayout(forTextLength: 10_000, currentlyEnabled: false) == false
    )
    #expect(
        HTMLEditorPolicy.shouldUseNonContiguousLayout(forTextLength: 80_000, currentlyEnabled: false) == true
    )
}

@Test func testNonContiguousLayoutDoesNotFlipAtTheThreshold() async throws {
    // Turning the switch back off forces a full relayout, so a document parked
    // on the threshold must not toggle on every keystroke.
    let threshold = HTMLEditorDocumentSize.viewportFirst

    // Crossing upwards enables it...
    #expect(HTMLEditorPolicy.shouldUseNonContiguousLayout(forTextLength: threshold, currentlyEnabled: false) == false)
    #expect(HTMLEditorPolicy.shouldUseNonContiguousLayout(forTextLength: threshold + 1, currentlyEnabled: false) == true)

    // ...and dropping a character back below it does not disable it again.
    #expect(HTMLEditorPolicy.shouldUseNonContiguousLayout(forTextLength: threshold, currentlyEnabled: true) == true)
    #expect(
        HTMLEditorPolicy.shouldUseNonContiguousLayout(
            forTextLength: HTMLEditorDocumentSize.nonContiguousLayoutOff + 1,
            currentlyEnabled: true
        ) == true
    )

    // Only a document that has genuinely shrunk goes back to contiguous layout.
    #expect(
        HTMLEditorPolicy.shouldUseNonContiguousLayout(
            forTextLength: HTMLEditorDocumentSize.nonContiguousLayoutOff,
            currentlyEnabled: true
        ) == false
    )
}

@Test func testLocalDirtyHighlightRangeIsClamped() async throws {
    let dirtyRange = NSRange(location: 1_000, length: 800)
    let clamped = HTMLEditorPolicy.localDirtyHighlightRange(
        around: dirtyRange,
        textLength: 5_000,
        maxLength: 512
    )

    #expect(clamped.length == 512)
    #expect(clamped.location <= dirtyRange.location + dirtyRange.length / 2)
    #expect(NSMaxRange(clamped) >= dirtyRange.location + dirtyRange.length / 2)
}

@Test func testStructuralDirtyRangeAlignsToTagBoundaries() async throws {
    let html = "<div class=\"one\"><span id=\"two\">text</span></div>" as NSString
    let classRange = html.range(of: "class")
    let aligned = HTMLEditorPolicy.structuralDirtyRange(
        for: classRange,
        replacementLength: "data-class".utf16.count,
        in: html,
        expansion: 8
    )

    #expect(aligned.location <= html.range(of: "<div").location)
    #expect(NSMaxRange(aligned) >= html.range(of: ">").location + 1)
}
