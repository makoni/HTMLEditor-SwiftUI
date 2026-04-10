import Testing
import Foundation
@testable import HTMLEditor

@Test func testHighlightCoverageMarksRangeAsCleanByBlocks() async throws {
    var coverage = HTMLEditorHighlightCoverage()
    coverage.markHighlighted(NSRange(location: 512, length: 120))

    #expect(coverage.needsHighlighting(NSRange(location: 520, length: 20)) == false)
    #expect(coverage.needsHighlighting(NSRange(location: 900, length: 20)) == true)
}

@Test func testHighlightCoverageMarkDirtyForcesNeedsHighlighting() async throws {
    // Bug 2: after an edit the prewarm zone must be re-queued.  markDirty() is
    // the mechanism that puts a previously-clean block back on the dirty set so
    // the prewarm triggered by the edit will re-highlight it.
    var coverage = HTMLEditorHighlightCoverage()
    coverage.markHighlighted(NSRange(location: 0, length: 1200))

    // Sanity: whole range clean to start.
    #expect(coverage.needsHighlighting(NSRange(location: 800, length: 400)) == false)

    // Simulate marking the prewarm zone as dirty after an edit.
    coverage.markDirty(NSRange(location: 800, length: 400))

    // Prewarm zone must now report as needing a highlight pass.
    #expect(coverage.needsHighlighting(NSRange(location: 800, length: 400)) == true)
    // Area before the mark is unaffected.
    #expect(coverage.needsHighlighting(NSRange(location: 0, length: 512)) == false)
}

@Test func testHighlightCoverageRemapsAndDirtiesEditedBlocks() async throws {
    var coverage = HTMLEditorHighlightCoverage()
    coverage.markHighlighted(NSRange(location: 256, length: 512))

    let dirtyRange = HTMLEditorVisibleHighlightState.dirtyRange(
        for: NSRange(location: 384, length: 0),
        replacementLength: 24,
        newTextLength: 2_048,
        expansion: 64
    )

    coverage.remapAfterEdit(
        editRange: NSRange(location: 384, length: 0),
        replacementUTF16Length: 24,
        newTextLength: 2_048,
        dirtyRange: dirtyRange
    )

    #expect(coverage.needsHighlighting(NSRange(location: 384, length: 48)) == true)
    #expect(coverage.needsHighlighting(NSRange(location: 700, length: 32)) == false)
}
