#if os(macOS)
import Foundation

struct HTMLEditorHighlightCoverage {
    private static let blockSize = 256

    private(set) var cleanBlocks = IndexSet()
    private(set) var dirtyBlocks = IndexSet()

    mutating func clear() {
        cleanBlocks.removeAll()
        dirtyBlocks.removeAll()
    }

    mutating func markHighlighted(_ range: NSRange) {
        let blocks = Self.blocks(for: range)
        cleanBlocks.formUnion(blocks)
        dirtyBlocks.subtract(blocks)
    }

    /// Marks a range as needing re-highlighting.  Use this to invalidate
    /// prewarm highlights that may have become stale after an edit.
    mutating func markDirty(_ range: NSRange) {
        let blocks = Self.blocks(for: range)
        guard !blocks.isEmpty else { return }
        dirtyBlocks.formUnion(blocks)
        cleanBlocks.subtract(blocks)
    }

    mutating func remapAfterEdit(
        editRange: NSRange,
        replacementUTF16Length: Int,
        newTextLength: Int,
        dirtyRange: NSRange
    ) {
        cleanBlocks = Self.remapBlocks(
            cleanBlocks,
            editRange: editRange,
            replacementLength: replacementUTF16Length,
            newTextLength: newTextLength
        )
        dirtyBlocks = Self.remapBlocks(
            dirtyBlocks,
            editRange: editRange,
            replacementLength: replacementUTF16Length,
            newTextLength: newTextLength
        )
        dirtyBlocks.formUnion(Self.blocks(for: dirtyRange))
        cleanBlocks.subtract(dirtyBlocks)
    }

    func needsHighlighting(_ range: NSRange, force: Bool = false) -> Bool {
        if force {
            return true
        }

        let requestedBlocks = Self.blocks(for: range)
        guard !requestedBlocks.isEmpty else { return false }

        if !dirtyBlocks.intersection(requestedBlocks).isEmpty {
            return true
        }

        return !requestedBlocks.subtracting(cleanBlocks).isEmpty
    }

    private static func blocks(for range: NSRange) -> IndexSet {
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        let startBlock = range.location / blockSize
        let endBlock = max(range.location, NSMaxRange(range) - 1) / blockSize
        return IndexSet(integersIn: startBlock...endBlock)
    }

    private static func remapBlocks(
        _ blocks: IndexSet,
        editRange: NSRange,
        replacementLength: Int,
        newTextLength: Int
    ) -> IndexSet {
        guard !blocks.isEmpty else { return IndexSet() }

        // Remapping every block separately costs O(blocks), and a document
        // scrolled end to end is one contiguous run — thousands of remaps on
        // every keystroke.  Blocks below the edit are untouched and blocks past
        // it all move by the same delta, so each of those segments can be
        // remapped as a single range: within a segment the per-block images tile
        // contiguously, making the union of the parts equal to the union of the
        // blocks.  Only the segment overlapping the edit itself is not a plain
        // shift, and remapping it whole is still exact because the images there
        // are monotonic and therefore contiguous.
        //
        // Segmenting matters rather than remapping the run in one go: an edit
        // landing exactly on a block boundary straddles no block, so a whole-run
        // remap would stretch across the insertion and wrongly declare the
        // inserted text already highlighted.
        let editStart = max(0, editRange.location)
        let editEnd = max(editStart, NSMaxRange(editRange))
        let lastUnshiftedBlock = editStart / blockSize
        let firstShiftedBlock = (editEnd + blockSize - 1) / blockSize

        var remapped = IndexSet()

        func remapSegment(from lowerBlock: Int, to upperBlock: Int) {
            guard upperBlock > lowerBlock else { return }
            let segment = NSRange(
                location: lowerBlock * blockSize,
                length: (upperBlock - lowerBlock) * blockSize
            )
            guard let range = HTMLEditorVisibleHighlightState.remapRange(
                segment,
                editRange: editRange,
                replacementLength: replacementLength,
                newTextLength: newTextLength
            ) else {
                return
            }
            remapped.formUnion(Self.blocks(for: range))
        }

        for run in blocks.rangeView {
            remapSegment(from: run.lowerBound, to: min(run.upperBound, lastUnshiftedBlock))
            remapSegment(
                from: max(run.lowerBound, lastUnshiftedBlock),
                to: min(run.upperBound, firstShiftedBlock)
            )
            remapSegment(from: max(run.lowerBound, firstShiftedBlock), to: run.upperBound)
        }

        return remapped
    }
}
#endif
