import Testing
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
