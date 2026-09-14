//
//  HTMLEditorParagraphCacheTests.swift
//  HTMLEditor-SwiftUITests
//
//  The styled-paragraph cache must not hand back a stale paragraph.
//

import XCTest
@testable import HTMLEditor

/// Reported from the field, on iPhone, against ordinary posts:
///
/// > type "a1", delete one character to get "a", then type "2" — the editor
/// > shows "a1" instead of "a2". Typing one more character, "3", corrects it
/// > to "a23".
///
/// The text storage was right the whole time; only what was **drawn** was
/// stale, which is why the next keystroke fixed it. That points at
/// `styledParagraphCache`, whose key is (location, length, fingerprint) — and
/// the fingerprint sampled **five** offsets: 0, L/4, L/2, 3L/4 and L-1.
///
/// So "…a1…" and "…a2…" are the same length, at the same location, and differ
/// at a position that is usually not one of those five. Same key, and the
/// cache still held the entry from before the delete.
final class HTMLEditorParagraphCacheTests: XCTestCase {

    /// The fingerprint must distinguish two same-length paragraphs that differ
    /// anywhere, not just at five offsets.
    @MainActor
    func testFingerprintSeesAChangeAtEveryPosition() {
        let base = "<p class=\"note\">Lorem ipsum dolor sit amet consectetur adipiscing elit sed do</p>"
        let baseText = base as NSString
        let range = NSRange(location: 0, length: baseText.length)
        let baseline = HTMLEditor.Coordinator.fingerprint(baseText, range: range)

        var collisions: [Int] = []
        for index in 0..<baseText.length {
            var mutated = Array(base)
            // Swap in a character that is certainly different.
            mutated[index] = mutated[index] == "@" ? "#" : "@"
            let candidate = String(mutated) as NSString
            if HTMLEditor.Coordinator.fingerprint(candidate, range: range) == baseline {
                collisions.append(index)
            }
        }

        XCTAssertTrue(
            collisions.isEmpty,
            "Отпечаток не заметил правку в \(collisions.count) из \(baseText.length) позиций: \(collisions.prefix(12))…"
        )
    }

    /// The exact sequence from the report, at the level the bug lives.
    @MainActor
    func testTypeDeleteRetypeDoesNotReuseTheOldParagraph() {
        let prefix = "<div class=\"row\" id=\"r\"><span>value-"
        let suffix = "</span></div>"

        func paragraph(_ middle: String) -> (text: NSString, range: NSRange) {
            let s = (prefix + middle + suffix) as NSString
            return (s, NSRange(location: 0, length: s.length))
        }

        let a1 = paragraph("a1")
        let a = paragraph("a")
        let a2 = paragraph("a2")

        let f1 = HTMLEditor.Coordinator.fingerprint(a1.text, range: a1.range)
        let fA = HTMLEditor.Coordinator.fingerprint(a.text, range: a.range)
        let f2 = HTMLEditor.Coordinator.fingerprint(a2.text, range: a2.range)

        // The delete changes the length, so that step was never the problem.
        XCTAssertNotEqual(f1, fA)

        // This is the bug: same location, same length, different content — and
        // the cache is keyed on all three.
        XCTAssertNotEqual(
            f1, f2,
            "«a1» и «a2» дают одинаковый отпечаток: кэш вернёт устаревший абзац"
        )
        XCTAssertEqual(a1.range, a2.range, "Проверка смысла теста: длина и позиция совпадают")
    }


    /// The cache itself, not the hash it is keyed on.
    ///
    /// Every other test here calls `fingerprint` directly, which leaves the
    /// cache free to key on something else entirely and bring the field bug
    /// back. Proved: writing `fingerprint: 0` into `ParagraphPlanKey` while
    /// leaving the good hash in place makes the editor draw `a1` for `a2`
    /// again — and every other test still passes. This one fails.
    @MainActor
    func testTheCacheVendsTheEditedParagraphNotTheOldOne() throws {
        let storage = NSTextContentStorage()
        let prefix = "<div class=\"row\" id=\"r\"><span>value-"
        let suffix = "</span></div>"
        storage.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: prefix + "a1" + suffix
        )
        let coordinator = HTMLEditor(html: .constant("")).makeCoordinator()

        let whole = NSRange(location: 0, length: storage.textStorage?.length ?? 0)
        let before = coordinator.textContentStorage(storage, textParagraphWith: whole)
        XCTAssertEqual(before?.attributedString.string.contains("value-a1"), true)

        // Same location, same length, one character different — the shape that
        // the five-sample fingerprint could not see.
        let edited = NSRange(location: (prefix as NSString).length + 1, length: 1)
        storage.textStorage?.replaceCharacters(in: edited, with: "2")

        let after = coordinator.textContentStorage(storage, textParagraphWith: whole)
        XCTAssertEqual(
            after?.attributedString.string.contains("value-a2"), true,
            "Кэш вернул прежний абзац: «\(after?.attributedString.string ?? "nil")»"
        )
    }

    /// A paragraph the editor refuses to highlight is not cached either, so the
    /// fingerprint never runs on an unbounded string.
    @MainActor
    func testFingerprintOnlyRunsWithinTheHighlightedLimit() {
        // Equality, not an upper bound. The point is to trip when the limit
        // moves at all, because the full fingerprint's cost is argued from this
        // number; `<= 64_000` let it grow tenfold in silence.
        XCTAssertEqual(
            HTMLEditorDocumentSize.highlightedParagraphLimit,
            6_000,
            "Предел изменился — стоимость полного отпечатка надо перемерить"
        )
    }
}
