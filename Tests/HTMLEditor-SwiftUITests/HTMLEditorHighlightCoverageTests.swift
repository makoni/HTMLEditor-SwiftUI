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

@Test func testLargePasteLeavesInsertedRegionDirty() async throws {
    // The remap stretches the block straddling the edit, which on its own would
    // declare the whole inserted span clean.  What keeps that sound is the
    // coupling with the dirty range textDidChange passes alongside it:
    // `structuralDirtyRange` is anchored on `replacementLength`, so it always
    // covers the replacement.  This test pins that coupling — a remap called
    // with a dirty range narrower than the insertion would silently leave pasted
    // text unhighlighted until an edit landed near it.
    let oldLength = 20_000
    let insertedLength = 10_000
    let newLength = oldLength + insertedLength
    let editRange = NSRange(location: 2_000, length: 0)

    var coverage = HTMLEditorHighlightCoverage()
    coverage.markHighlighted(NSRange(location: 0, length: oldLength))

    let text = String(repeating: "a", count: newLength) as NSString
    let dirtyRange = HTMLEditor.structuralDirtyRange(
        for: editRange,
        replacementLength: insertedLength,
        in: text,
        expansion: HTMLEditor.highlightBudget(forTextLength: newLength).visibleExpansion
    )

    coverage.remapAfterEdit(
        editRange: editRange,
        replacementUTF16Length: insertedLength,
        newTextLength: newLength,
        dirtyRange: dirtyRange
    )

    // Everything inside the pasted span must still be queued for highlighting.
    for probe in [2_000, 5_000, 8_000, 11_500] {
        #expect(coverage.needsHighlighting(NSRange(location: probe, length: 32)) == true)
    }

    // Text that merely shifted stays clean; re-highlighting it would be waste.
    #expect(coverage.needsHighlighting(NSRange(location: 13_000, length: 32)) == false)
    #expect(coverage.needsHighlighting(NSRange(location: 25_000, length: 32)) == false)
}

@Test func testRunBasedRemapMatchesPerBlockRemap() async throws {
    // The run-based remap must be indistinguishable from remapping every block
    // individually.  Compare against an explicit per-block reference over a
    // spread of edit shapes, including deletions and edits that straddle runs.
    func referenceRemap(
        _ blocks: IndexSet,
        editRange: NSRange,
        replacementLength: Int,
        newTextLength: Int
    ) -> IndexSet {
        var remapped = IndexSet()
        for block in blocks {
            let blockRange = NSRange(location: block * 256, length: 256)
            guard let range = HTMLEditorVisibleHighlightState.remapRange(
                blockRange,
                editRange: editRange,
                replacementLength: replacementLength,
                newTextLength: newTextLength
            ) else { continue }
            let start = range.location / 256
            let end = max(range.location, NSMaxRange(range) - 1) / 256
            remapped.formUnion(IndexSet(integersIn: start...end))
        }
        return remapped
    }

    let shapes: [(NSRange, Int)] = [
        (NSRange(location: 0, length: 0), 1),
        (NSRange(location: 300, length: 0), 17),
        (NSRange(location: 4_096, length: 0), 10_000),
        (NSRange(location: 5_000, length: 800), 0),
        (NSRange(location: 5_000, length: 800), 40),
        (NSRange(location: 12_000, length: 3_000), 9),
        (NSRange(location: 19_000, length: 1_000), 1_000)
    ]

    for (editRange, replacementLength) in shapes {
        for seedRanges in [
            [0..<80],
            [0..<12, 40..<44, 60..<79],
            [30..<31],
            [0..<1, 79..<80]
        ] {
            var coverage = HTMLEditorHighlightCoverage()
            var seed = IndexSet()
            for range in seedRanges {
                seed.insert(integersIn: range)
                coverage.markHighlighted(
                    NSRange(location: range.lowerBound * 256, length: range.count * 256)
                )
            }

            let newTextLength = 20_000 - editRange.length + replacementLength
            coverage.remapAfterEdit(
                editRange: editRange,
                replacementUTF16Length: replacementLength,
                newTextLength: newTextLength,
                dirtyRange: NSRange(location: 0, length: 0)
            )

            let expected = referenceRemap(
                seed,
                editRange: editRange,
                replacementLength: replacementLength,
                newTextLength: newTextLength
            )

            #expect(
                coverage.cleanBlocks == expected,
                "edit \(editRange) x\(replacementLength) seed \(seedRanges)"
            )
        }
    }
}
