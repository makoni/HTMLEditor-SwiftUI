//
//  HTMLEditorParagraphCacheCostTests.swift
//  HTMLEditor-SwiftUITests
//
//  The styled-paragraph cache has to be worth having.
//

import XCTest
@testable import HTMLEditor

/// Two relations hold the cache up, and neither is obvious from reading it.
///
/// The fingerprint went from sampling five offsets to hashing the whole
/// paragraph, because five samples could not tell `a1` from `a2` and the editor
/// drew stale text (`HTMLEditorParagraphCacheTests`). That trade is only sound
/// while the hash stays cheaper than the work it saves — so these measure it
/// rather than assert it in a comment.
///
/// Ratios, not absolute times: both sides run in the same process on the same
/// strings, so the comparison survives a slower machine.
final class HTMLEditorParagraphCacheCostTests: XCTestCase {

    /// Markup shaped like a real line, padded to an exact length.
    private func line(_ length: Int) -> NSString {
        var s = "<div class=\"row js-navigation-item\" id=\"row-7\" data-index=\"7\">"
            + "<a href=\"https://example.com/tree/main/file-7.swift\">file-7.swift</a></div>"
        while s.utf16.count < length { s += s }
        return String(s.prefix(length)) as NSString
    }

    /// The fingerprint runs on **every** delegate call, hit or miss. The scan
    /// runs only on a miss. So the fingerprint has to be the cheaper of the
    /// two, or the cache costs more than it saves.
    ///
    /// 6 000 is not an arbitrary upper bound: it is
    /// ``HTMLEditorDocumentSize/highlightedParagraphLimit``, the longest
    /// paragraph that gets coloured at all, and therefore the longest one the
    /// fingerprint can ever see.
    @MainActor
    func testHashingAParagraphIsCheaperThanScanningIt() {
        for length in [120, 600, HTMLEditorDocumentSize.highlightedParagraphLimit] {
            let text = line(length)
            let range = NSRange(location: 0, length: text.length)

            var sink = 0
            let hashStart = CFAbsoluteTimeGetCurrent()
            for _ in 0..<20_000 { sink &+= HTMLEditor.Coordinator.fingerprint(text, range: range) }
            let hash = (CFAbsoluteTimeGetCurrent() - hashStart) / 20_000

            let scanStart = CFAbsoluteTimeGetCurrent()
            for _ in 0..<200 { _ = HTMLHighlightPlanBuilder.buildPlan(in: text, coveredRange: range) }
            let scan = (CFAbsoluteTimeGetCurrent() - scanStart) / 200

            XCTAssertNotEqual(sink, Int.min)
            XCTAssertLessThan(
                hash, scan,
                "Отпечаток \(length)-символьного абзаца дороже скана, который он экономит: "
                    + String(format: "%.3f мкс против %.3f мкс", hash * 1e6, scan * 1e6)
            )
        }
    }

    /// And the point of the whole thing: a hit must beat rebuilding.
    ///
    /// A miss is not just the scan — it copies the paragraph, writes a span per
    /// token and allocates an `NSTextParagraph`. Measured in Release at ~4.6 µs
    /// against ~1.3 µs for a hit.
    @MainActor
    func testAHitIsCheaperThanRebuildingTheParagraph() {
        let storage = NSTextContentStorage()
        let text = String(
            repeating: "<div class=\"row\" id=\"r\"><span class=\"v\">value</span></div>\n",
            count: 400
        )
        storage.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        let coordinator = HTMLEditor(html: .constant("")).makeCoordinator()

        let ns = text as NSString
        var ranges: [NSRange] = []
        var cursor = 0
        while cursor < ns.length && ranges.count < 300 {
            let paragraph = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            ranges.append(paragraph)
            cursor = NSMaxRange(paragraph)
        }

        // Nothing is cached yet, so every call here is a miss.
        let missStart = CFAbsoluteTimeGetCurrent()
        for range in ranges { _ = coordinator.textContentStorage(storage, textParagraphWith: range) }
        let miss = (CFAbsoluteTimeGetCurrent() - missStart) / Double(ranges.count)

        // The same ranges, unedited: every call is a hit.
        let hitStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 {
            for range in ranges { _ = coordinator.textContentStorage(storage, textParagraphWith: range) }
        }
        let hit = (CFAbsoluteTimeGetCurrent() - hitStart) / Double(ranges.count * 20)

        // A margin, not `hit < miss`. The bare inequality passed with the
        // cache **entirely disabled** — the miss pass is the first pass over
        // the ranges and absorbs allocator and class-realisation warmup, so it
        // was measuring warmup, not caching.
        XCTAssertLessThan(
            hit * 3, miss,
            "Попадание в кэш не даёт трёхкратной экономии: "
                + String(format: "%.3f мкс против %.3f мкс", hit * 1e6, miss * 1e6)
        )

        // And the contract the production comment actually states: an unchanged
        // paragraph comes back as the *identical* element, so TextKit can keep
        // the layout it already has. A timing margin cannot see that.
        let range = ranges[0]
        let first = coordinator.textContentStorage(storage, textParagraphWith: range)
        let second = coordinator.textContentStorage(storage, textParagraphWith: range)
        XCTAssertNotNil(first)
        XCTAssertTrue(
            first === second,
            "Неизменённый абзац пересобран заново, а не отдан из кэша"
        )
    }
}
