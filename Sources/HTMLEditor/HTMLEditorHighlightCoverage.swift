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

    mutating func remapAfterEdit(
        editRange: NSRange,
        replacementUTF16Length: Int,
        newTextLength: Int,
        dirtyExpansion: Int
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
        let dirtyRange = HTMLEditorVisibleHighlightState.dirtyRange(
            for: editRange,
            replacementLength: replacementUTF16Length,
            newTextLength: newTextLength,
            expansion: dirtyExpansion
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
        var remapped = IndexSet()

        for block in blocks {
            let blockRange = NSRange(location: block * blockSize, length: blockSize)
            guard let range = HTMLEditorVisibleHighlightState.remapRange(
                blockRange,
                editRange: editRange,
                replacementLength: replacementLength,
                newTextLength: newTextLength
            ) else {
                continue
            }
            remapped.formUnion(Self.blocks(for: range))
        }

        return remapped
    }
}
#endif
