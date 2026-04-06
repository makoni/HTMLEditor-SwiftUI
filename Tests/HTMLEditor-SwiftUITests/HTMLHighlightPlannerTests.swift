import Testing
import AppKit
@testable import HTMLEditor

@Test func testPlannerCacheSupportsDocumentScopedInvalidation() async throws {
    let documentA = UUID()
    let documentB = UUID()
    let html = "<div class=\"alpha\" data-id=\"123\">content</div>"
    let targetRange = (html as NSString).range(of: "class=\"alpha\"")

    let planA1 = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: documentA,
        text: html,
        requestedRange: targetRange
    )
    let planB1 = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: documentB,
        text: html,
        requestedRange: targetRange
    )

    await HTMLSyntaxHighlighter.invalidatePlannerCache(
        documentID: documentA,
        editRange: targetRange,
        replacementUTF16Length: targetRange.length + 4,
        newTextLength: html.utf16.count + 4
    )

    let planA2 = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: documentA,
        text: html,
        requestedRange: targetRange
    )
    let planB2 = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: documentB,
        text: html,
        requestedRange: targetRange
    )

    #expect(planA1.coveredRange == planA2.coveredRange)
    #expect(planB1.coveredRange == planB2.coveredRange)
    #expect(planA1.spans.map(\.range) == planA2.spans.map(\.range))
    #expect(planB1.spans.map(\.range) == planB2.spans.map(\.range))
}

@Test func testPlannerSameLengthEditPreservesDownstreamChunkCache() async throws {
    let documentID = UUID()
    let repeated = String(repeating: "<div class=\"item\" data-id=\"123\">value</div>\n", count: 200)
    let targetRange = NSRange(location: 3_600, length: 1_400)
    let editRange = NSRange(location: 3_620, length: 5)

    _ = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: documentID,
        text: repeated,
        requestedRange: targetRange
    )

    let beforeCounts = await HTMLSyntaxHighlighter.debugPlannerCacheCounts(documentID: documentID)
    await HTMLSyntaxHighlighter.invalidatePlannerCache(
        documentID: documentID,
        editRange: editRange,
        replacementUTF16Length: editRange.length,
        newTextLength: repeated.utf16.count
    )
    let afterInvalidationCounts = await HTMLSyntaxHighlighter.debugPlannerCacheCounts(documentID: documentID)

    #expect(beforeCounts.chunks > 0)
    #expect(afterInvalidationCounts.chunks > 0)
    #expect(afterInvalidationCounts.chunks <= beforeCounts.chunks)
    #expect(afterInvalidationCounts.chunks < beforeCounts.chunks || afterInvalidationCounts.plans == 0)
}

@Test func testCoveringPlanCacheHitForSubRangeRequest() async throws {
    let docID = UUID()
    let html = String(repeating: "<p class=\"row\">text</p>\n", count: 12)

    let fullPlan = await HTMLSyntaxHighlighter.plannedFullHighlight(documentID: docID, html: html)
    #expect(fullPlan != nil)
    let countsAfterFull = await HTMLSyntaxHighlighter.debugPlannerCacheCounts(documentID: docID)
    #expect(countsAfterFull.plans >= 1)

    let subRange = NSRange(location: 12, length: 24)
    let subPlan = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: docID,
        text: html,
        requestedRange: subRange
    )

    let countsAfterSub = await HTMLSyntaxHighlighter.debugPlannerCacheCounts(documentID: docID)

    #expect(countsAfterSub.plans == countsAfterFull.plans)
    #expect(subPlan.coveredRange.location != NSNotFound)
    #expect(NSMaxRange(subPlan.coveredRange) <= html.utf16.count)
    #expect(!subPlan.spans.isEmpty)
}

@Test func testLengthChangingEditRemapsUnaffectedChunksForDocument() async throws {
    let docID = UUID()
    let html = String(repeating: "<li class=\"item\" data-id=\"1\">value</li>\n", count: 100)

    _ = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: docID,
        text: html,
        requestedRange: NSRange(location: 1000, length: 600)
    )

    let countsBefore = await HTMLSyntaxHighlighter.debugPlannerCacheCounts(documentID: docID)
    #expect(countsBefore.chunks > 0)

    await HTMLSyntaxHighlighter.invalidatePlannerCache(
        documentID: docID,
        editRange: NSRange(location: 1200, length: 0),
        replacementUTF16Length: 3,
        newTextLength: html.utf16.count + 3
    )

    let countsAfter = await HTMLSyntaxHighlighter.debugPlannerCacheCounts(documentID: docID)

    #expect(countsAfter.chunks > 0)
    #expect(countsAfter.chunks < countsBefore.chunks)
    #expect(countsAfter.plans == 0)
}

@Test func testAlignedNeighboringRequestReusesPreviousChunkState() async throws {
    let docID = UUID()
    let html = String(repeating: "<div class=\"row\" data-id=\"123\">value</div>\n", count: 180)
    let firstRange = NSRange(location: 2_048, length: 900)
    let neighboringRange = NSRange(location: 2_560, length: 900)

    _ = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: docID,
        text: html,
        requestedRange: firstRange
    )
    let afterFirst = await HTMLSyntaxHighlighter.debugPlannerCacheCounts(documentID: docID)

    _ = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: docID,
        text: html,
        requestedRange: neighboringRange
    )
    let afterNeighbor = await HTMLSyntaxHighlighter.debugPlannerCacheCounts(documentID: docID)

    #expect(afterFirst.chunks > 0)
    #expect(afterNeighbor.chunks >= afterFirst.chunks)
    #expect(afterNeighbor.chunks - afterFirst.chunks <= 2)
}

@Test func testContextIndependentChunkCanBeReusedAcrossStateMismatch() async throws {
    let docID = UUID()
    let html = String(repeating: "<div>plain text</div>\n", count: 220)
    let targetRange = NSRange(location: 2_048, length: 512)

    _ = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: docID,
        text: html,
        requestedRange: targetRange
    )
    let before = await HTMLSyntaxHighlighter.debugPlannerCacheCounts(documentID: docID)

    await HTMLSyntaxHighlighter.invalidatePlannerCache(
        documentID: docID,
        editRange: NSRange(location: 32, length: 1),
        replacementUTF16Length: 1,
        newTextLength: html.utf16.count
    )

    _ = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: docID,
        text: html,
        requestedRange: targetRange
    )
    let after = await HTMLSyntaxHighlighter.debugPlannerCacheCounts(documentID: docID)

    #expect(before.chunks > 0)
    #expect(after.chunks >= before.chunks)
}

@Test func testClippedPlanRestrictsSpansToVisibleWindow() async throws {
    let html = "<div class=\"visible\">text</div>"
    let plan = await HTMLSyntaxHighlighter.plannedFullHighlight(documentID: UUID(), html: html)
    #expect(plan != nil)

    let clipped = HTMLSyntaxHighlighter.clippedPlan(
        plan!,
        to: NSRange(location: 0, length: 10)
    )

    #expect(clipped.coveredRange.location == 0)
    #expect(clipped.coveredRange.length == 10)
    #expect(clipped.spans.allSatisfy { NSMaxRange($0.range) <= 10 })
}

@Test func testPlannerCacheRemainsBoundedUnderViewportChurn() async throws {
    let docID = UUID()
    let html = String(repeating: "<div class=\"row\" data-id=\"123\">value</div>\n", count: 800)

    for index in 0..<400 {
        let location = min(max(0, html.utf16.count - 2), (index * 137) % max(1, html.utf16.count - 1))
        let length = min(900, html.utf16.count - location)
        _ = await HTMLSyntaxHighlighter.plannedRangeHighlight(
            documentID: docID,
            text: html,
            requestedRange: NSRange(location: location, length: max(1, length))
        )
    }

    let counts = await HTMLSyntaxHighlighter.debugPlannerCacheCounts(documentID: docID)
    #expect(counts.plans <= 24)
    #expect(counts.chunks <= 192)
}

@Test func testMixedEditChurnKeepsPlansWithinBounds() async throws {
    let docID = UUID()
    var html = String(repeating: "<div class=\"item\">value</div>\n", count: 220)

    for index in 0..<20 {
        let nsHTML = html as NSString
        let location = min(max(0, nsHTML.length - 2), 100 + index * 47)
        let replaceLength = index.isMultiple(of: 2) ? 1 : 0
        let safeLength = min(replaceLength, max(0, nsHTML.length - location))
        let editRange = NSRange(location: location, length: safeLength)
        let replacement = index.isMultiple(of: 3) ? "<a>" : "\""

        html = nsHTML.replacingCharacters(in: editRange, with: replacement)
        await HTMLSyntaxHighlighter.invalidatePlannerCache(
            documentID: docID,
            editRange: editRange,
            replacementUTF16Length: replacement.utf16.count,
            newTextLength: html.utf16.count
        )

        let currentLength = html.utf16.count
        let requestLocation = min(location, max(0, currentLength - 1))
        let requestLength = max(1, min(700, currentLength - requestLocation))
        let plan = await HTMLSyntaxHighlighter.plannedRangeHighlight(
            documentID: docID,
            text: html,
            requestedRange: NSRange(location: requestLocation, length: requestLength)
        )

        #expect(plan.coveredRange.location != NSNotFound)
        #expect(NSMaxRange(plan.coveredRange) <= currentLength)
        #expect(plan.spans.allSatisfy { $0.range.location >= 0 && NSMaxRange($0.range) <= currentLength })
    }
}
