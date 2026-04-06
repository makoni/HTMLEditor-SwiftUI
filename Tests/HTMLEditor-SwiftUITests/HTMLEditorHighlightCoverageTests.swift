import Testing
import Foundation
@testable import HTMLEditor

@Test func testHighlightCoverageMarksRangeAsCleanByBlocks() async throws {
    var coverage = HTMLEditorHighlightCoverage()
    coverage.markHighlighted(NSRange(location: 512, length: 120))

    #expect(coverage.needsHighlighting(NSRange(location: 520, length: 20)) == false)
    #expect(coverage.needsHighlighting(NSRange(location: 900, length: 20)) == true)
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
