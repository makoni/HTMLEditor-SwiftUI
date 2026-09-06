import Testing
import AppKit
@testable import HTMLEditor

/// Two editors must not disturb each other's caches. This was once enforced by
/// filtering a shared cache on a document UUID; it is now structural, since each
/// coordinator owns its planner — so the caps are per-document too, rather than
/// two editors evicting each other's chunks out of one global budget.
@Test func testPlannersAreIndependentOfEachOther() async throws {
    let first = HTMLHighlightPlanner()
    let second = HTMLHighlightPlanner()
    let html = "<div class=\"alpha\" data-id=\"123\">content</div>"
    let targetRange = (html as NSString).range(of: "class=\"alpha\"")

    let firstBefore = await first.rangePlan(for: html, requestedRange: targetRange)
    let secondBefore = await second.rangePlan(for: html, requestedRange: targetRange)
    #expect(await second.counts().plans == 1)

    await first.invalidate(
        editRange: targetRange,
        replacementUTF16Length: targetRange.length + 4,
        newTextLength: html.utf16.count + 4
    )

    // The second planner kept everything it had.
    #expect(await second.counts().plans == 1)

    let firstAfter = await first.rangePlan(for: html, requestedRange: targetRange)
    let secondAfter = await second.rangePlan(for: html, requestedRange: targetRange)

    #expect(firstBefore.coveredRange == firstAfter.coveredRange)
    #expect(secondBefore.coveredRange == secondAfter.coveredRange)
    #expect(firstBefore.spans.map(\.range) == firstAfter.spans.map(\.range))
    #expect(secondBefore.spans.map(\.range) == secondAfter.spans.map(\.range))

    // Clearing one leaves the other alone.
    await first.clear()
    #expect(await first.counts().plans == 0)
    #expect(await second.counts().plans == 1)
}

@Test func testPlannerSameLengthEditPreservesDownstreamChunkCache() async throws {
    let planner = HTMLHighlightPlanner()
    let repeated = String(repeating: "<div class=\"item\" data-id=\"123\">value</div>\n", count: 200)
    let targetRange = NSRange(location: 3_600, length: 1_400)
    let editRange = NSRange(location: 3_620, length: 5)

    _ = await planner.rangePlan(

        for: repeated,
            requestedRange: targetRange
    )

    let beforeCounts = await planner.counts()
    await planner.invalidate(
        editRange: editRange,
        replacementUTF16Length: editRange.length,
        newTextLength: repeated.utf16.count
    )
    let afterInvalidationCounts = await planner.counts()

    #expect(beforeCounts.chunks > 0)
    #expect(afterInvalidationCounts.chunks > 0)
    #expect(afterInvalidationCounts.chunks <= beforeCounts.chunks)
    #expect(afterInvalidationCounts.chunks < beforeCounts.chunks || afterInvalidationCounts.plans == 0)
}

@Test func testCoveringPlanCacheHitForSubRangeRequest() async throws {
    let planner = HTMLHighlightPlanner()
    let html = String(repeating: "<p class=\"row\">text</p>\n", count: 12)

    let fullPlan = await planner.fullPlan(for: html)
    #expect(fullPlan != nil)
    let countsAfterFull = await planner.counts()
    #expect(countsAfterFull.plans >= 1)

    let subRange = NSRange(location: 12, length: 24)
    let subPlan = await planner.rangePlan(
            for: html,
            requestedRange: subRange
    )

    let countsAfterSub = await planner.counts()

    #expect(countsAfterSub.plans == countsAfterFull.plans)
    #expect(subPlan.coveredRange.location != NSNotFound)
    #expect(NSMaxRange(subPlan.coveredRange) <= html.utf16.count)
    #expect(!subPlan.spans.isEmpty)
}

@Test func testLengthChangingEditRemapsUnaffectedChunksForDocument() async throws {
    let planner = HTMLHighlightPlanner()
    let html = String(repeating: "<li class=\"item\" data-id=\"1\">value</li>\n", count: 100)

    _ = await planner.rangePlan(

        for: html,
            requestedRange: NSRange(location: 1000, length: 600)
    )

    let countsBefore = await planner.counts()
    #expect(countsBefore.chunks > 0)

    await planner.invalidate(

        editRange: NSRange(location: 1200, length: 0),
        replacementUTF16Length: 3,
        newTextLength: html.utf16.count + 3
    )

    let countsAfter = await planner.counts()

    #expect(countsAfter.chunks > 0)
    #expect(countsAfter.chunks < countsBefore.chunks)
    #expect(countsAfter.plans == 0)
}

@Test func testAlignedNeighboringRequestReusesPreviousChunkState() async throws {
    let planner = HTMLHighlightPlanner()
    let html = String(repeating: "<div class=\"row\" data-id=\"123\">value</div>\n", count: 180)
    let firstRange = NSRange(location: 2_048, length: 900)
    let neighboringRange = NSRange(location: 2_560, length: 900)

    _ = await planner.rangePlan(

        for: html,
            requestedRange: firstRange
    )
    let afterFirst = await planner.counts()

    _ = await planner.rangePlan(

        for: html,
            requestedRange: neighboringRange
    )
    let afterNeighbor = await planner.counts()

    #expect(afterFirst.chunks > 0)
    #expect(afterNeighbor.chunks >= afterFirst.chunks)
    #expect(afterNeighbor.chunks - afterFirst.chunks <= 2)
}

@Test func testContextIndependentChunkCanBeReusedAcrossStateMismatch() async throws {
    let planner = HTMLHighlightPlanner()
    let html = String(repeating: "<div>plain text</div>\n", count: 220)
    let targetRange = NSRange(location: 2_048, length: 512)

    _ = await planner.rangePlan(

        for: html,
            requestedRange: targetRange
    )
    let before = await planner.counts()

    await planner.invalidate(

        editRange: NSRange(location: 32, length: 1),
        replacementUTF16Length: 1,
        newTextLength: html.utf16.count
    )

    _ = await planner.rangePlan(

        for: html,
            requestedRange: targetRange
    )
    let after = await planner.counts()

    #expect(before.chunks > 0)
    #expect(after.chunks >= before.chunks)
}

@Test func testClippedPlanRestrictsSpansToVisibleWindow() async throws {
    let html = "<div class=\"visible\">text</div>"
    let plan = await HTMLHighlightPlanner().fullPlan(for: html)

    let clipped = HTMLSyntaxHighlighter.clippedPlan(
        plan,
        to: NSRange(location: 0, length: 10)
    )

    #expect(clipped.coveredRange.location == 0)
    #expect(clipped.coveredRange.length == 10)
    #expect(clipped.spans.allSatisfy { NSMaxRange($0.range) <= 10 })
}

@Test func testPlannerCacheRemainsBoundedUnderViewportChurn() async throws {
    let planner = HTMLHighlightPlanner()
    let html = String(repeating: "<div class=\"row\" data-id=\"123\">value</div>\n", count: 800)

    for index in 0..<400 {
        let location = min(max(0, html.utf16.count - 2), (index * 137) % max(1, html.utf16.count - 1))
        let length = min(900, html.utf16.count - location)
        _ = await planner.rangePlan(
            for: html,
            requestedRange: NSRange(location: location, length: max(1, length))
        )
    }

    let counts = await planner.counts()
    #expect(counts.plans <= 24)
    #expect(counts.chunks <= 192)
}

@Test func testMixedEditChurnKeepsPlansWithinBounds() async throws {
    let planner = HTMLHighlightPlanner()
    var html = String(repeating: "<div class=\"item\">value</div>\n", count: 220)

    for index in 0..<20 {
        let nsHTML = html as NSString
        let location = min(max(0, nsHTML.length - 2), 100 + index * 47)
        let replaceLength = index.isMultiple(of: 2) ? 1 : 0
        let safeLength = min(replaceLength, max(0, nsHTML.length - location))
        let editRange = NSRange(location: location, length: safeLength)
        let replacement = index.isMultiple(of: 3) ? "<a>" : "\""

        html = nsHTML.replacingCharacters(in: editRange, with: replacement)
        await planner.invalidate(
            editRange: editRange,
            replacementUTF16Length: replacement.utf16.count,
            newTextLength: html.utf16.count
        )

        let currentLength = html.utf16.count
        let requestLocation = min(location, max(0, currentLength - 1))
        let requestLength = max(1, min(700, currentLength - requestLocation))
        let plan = await planner.rangePlan(
            for: html,
            requestedRange: NSRange(location: requestLocation, length: requestLength)
        )

        #expect(plan.coveredRange.location != NSNotFound)
        #expect(NSMaxRange(plan.coveredRange) <= currentLength)
        #expect(plan.spans.allSatisfy { $0.range.location >= 0 && NSMaxRange($0.range) <= currentLength })
    }
}
