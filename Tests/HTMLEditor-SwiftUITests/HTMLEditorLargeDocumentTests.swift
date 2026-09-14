//
//  HTMLEditorLargeDocumentTests.swift
//  HTMLEditor-SwiftUITests
//
//  Does editing in the middle of a very large document stay responsive?
//

import XCTest
@testable import HTMLEditor

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The question these answer is not "is it fast" but "is the cost **flat**".
///
/// A push-based editor re-scans and repaints work proportional to the document;
/// the pull-based TextKit 2 path is supposed to do work proportional to the
/// *viewport*. So every measurement below is taken in the **middle** of a
/// 100 000-line document, where a document-proportional implementation would be
/// at its worst, and compared against the same operation in a small one.
final class HTMLEditorLargeDocumentTests: XCTestCase {

    // MARK: - Fixture

    /// Markup shaped like a real page: nested divs, many attributes, the
    /// `href="https://…"` that link detection would otherwise scan as you type.
    static func document(lines: Int) -> String {
        var out = String()
        out.reserveCapacity(lines * 110)
        out += "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n</head>\n<body>\n"
        for index in 0..<lines {
            out += """
                <div class="row js-navigation-item" id="row-\(index)" data-index="\(index)">\
                <a class="js-navigation-open Link--primary" href="https://example.com/tree/main/file-\(index).swift" \
                title="file-\(index).swift">file-\(index).swift</a>\
                <span class="text-mono color-fg-muted">commit \(index % 997)</span></div>

                """
        }
        out += "</body>\n</html>\n"
        return out
    }

    private static let lineCount = 100_000
    private static let large = document(lines: lineCount)
    private static let small = document(lines: 200)

    // MARK: - Harness

    /// A text view configured the way the representable configures one, **in a
    /// window**.
    ///
    /// The window is not decoration. A detached text view has unbounded height,
    /// so its "viewport" is the whole document and TextKit lays out every
    /// paragraph — 100 008 of them, and 450 ms per keystroke. Put the same view
    /// in a 600 pt window and it asks for 164. Measuring without one measures
    /// the harness.
    @MainActor
    private func makeTextView(_ html: String, delegate: NSTextContentStorageDelegate? = nil) throws -> Harness {
        #if os(macOS)
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        #else
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)

        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        textView.isScrollEnabled = true
        textView.dataDetectorTypes = []
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocapitalizationType = .none
        textView.allowsEditingTextAttributes = false
        if #available(iOS 17.0, *) { textView.inlinePredictionType = .no }
        if #available(iOS 18.0, *) {
            textView.mathExpressionCompletionType = .no
            textView.writingToolsBehavior = .none
        }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.addSubview(textView)
        window.isHidden = false
        window.makeKeyAndVisible()
        #endif

        textView.htmlEditorTextContainer?.lineFragmentPadding = 0
        textView.htmlEditorTextContainer?.widthTracksTextView = true

        guard case .textKit2(_, let storage)? = HTMLEditorTextKitSurface.resolve(for: textView) else {
            throw XCTSkip("The text view is not on TextKit 2; these measurements would be meaningless")
        }
        // Before the text: TextKit asks the delegate as it lays each paragraph
        // out, so attaching afterwards misses the whole first pass.
        if let delegate { storage.delegate = delegate }
        textView.htmlEditorText = html
        #if os(macOS)
        textView.layoutSubtreeIfNeeded()
        #else
        textView.layoutIfNeeded()
        #endif
        return Harness(textView: textView, storage: storage, window: window)
    }

    /// Keeps the window alive for the duration of a measurement — a released
    /// window takes the viewport with it.
    @MainActor
    struct Harness {
        let textView: HTMLEditorPlatform.TextView
        let storage: NSTextContentStorage
        #if os(macOS)
        let window: NSWindow
        #else
        let window: UIWindow
        #endif
    }

    /// Forces layout of the viewport, which is what asks the delegate for
    /// paragraphs.
    @MainActor
    private func layOutViewport(_ textView: HTMLEditorPlatform.TextView) {
        guard let layoutManager = textView.textLayoutManager else { return }
        layoutManager.textViewportLayoutController.layoutViewport()
    }

    // MARK: - The document is only laid out where it is looked at

    @MainActor
    func testOpeningAHundredThousandLinesIsNotProportionalToItsSize() throws {
        // Build both windows first; the measurement is the document going in,
        // not AppKit/UIKit standing a window up.
        let smallHarness = try makeTextView("")
        let largeHarness = try makeTextView("")

        let smallTime = try measureOnce {
            smallHarness.textView.htmlEditorText = Self.small
            self.layOutViewport(smallHarness.textView)
        }
        let largeTime = try measureOnce {
            largeHarness.textView.htmlEditorText = Self.large
            self.layOutViewport(largeHarness.textView)
        }

        // Setting the string is inherently O(n) — it copies the text. What must
        // *not* happen is laying the whole thing out. Allow a generous factor:
        // the document is 500x bigger, so anything near-linear would blow past
        // this, while a copy plus viewport-only layout stays far under.
        XCTAssertLessThan(
            largeTime,
            max(smallTime, 0.001) * 120,
            "Открытие масштабируется с размером документа: small=\(ms(smallTime)) large=\(ms(largeTime))"
        )
        print("[open] 200 строк: \(ms(smallTime))   \(Self.lineCount) строк: \(ms(largeTime))")
    }

    // MARK: - The keystroke

    @MainActor
    func testTypingInTheMiddleOfAHundredThousandLinesStaysFlat() throws {
        let large = try makeTextView(Self.large)
        let small = try makeTextView(Self.small)
        layOutViewport(large.textView)
        layOutViewport(small.textView)

        let largeMiddle = (Self.large as NSString).length / 2
        let smallMiddle = (Self.small as NSString).length / 2

        let largePerKeystroke = try keystrokeCost(in: large.textView, storage: large.storage, at: largeMiddle)
        let smallPerKeystroke = try keystrokeCost(in: small.textView, storage: small.storage, at: smallMiddle)

        print("[keystroke] 200 строк: \(ms(smallPerKeystroke))   \(Self.lineCount) строк: \(ms(largePerKeystroke))")

        // A keystroke must not feel different in a huge document. 16 ms is one
        // frame at 60 Hz — the threshold above which typing is visibly laggy.
        XCTAssertLessThan(
            largePerKeystroke,
            0.016,
            "Нажатие в середине большого документа дороже кадра: \(ms(largePerKeystroke))"
        )
        XCTAssertLessThan(
            largePerKeystroke,
            max(smallPerKeystroke, 0.0002) * 25,
            "Стоимость нажатия растёт с размером документа: small=\(ms(smallPerKeystroke)) large=\(ms(largePerKeystroke))"
        )
    }

    /// Mean cost of inserting one character, including the re-styling TextKit
    /// asks for as a consequence.
    @MainActor
    private func keystrokeCost(
        in textView: HTMLEditorPlatform.TextView,
        storage: NSTextContentStorage,
        at location: Int
    ) throws -> TimeInterval {
        let iterations = 30
        var total: TimeInterval = 0

        for step in 0..<iterations {
            let insertAt = location + step
            let start = CFAbsoluteTimeGetCurrent()
            storage.textStorage?.replaceCharacters(in: NSRange(location: insertAt, length: 0), with: "x")
            layOutViewport(textView)
            total += CFAbsoluteTimeGetCurrent() - start
        }
        return total / Double(iterations)
    }

    // MARK: - Highlighting actually happens, and is bounded

    @MainActor
    func testHighlightingCoversTheViewportAndOnlyTheViewport() throws {
        let counter = ParagraphCounter()
        let harness = try makeTextView(Self.large, delegate: counter)
        layOutViewport(harness.textView)

        XCTAssertGreaterThan(
            counter.calls, 0,
            "Делегат абзацев ни разу не вызван — подсветки нет, а падения TextKit 2 не было"
        )
        // The whole point: a viewport's worth, not a document's worth.
        // A viewport's worth, not a document's worth. In a 600 pt window the
        // real number is ~164; the bound is loose so a different screen size or
        // font metric does not turn this into a flaky test.
        XCTAssertLessThan(
            counter.calls, 2_000,
            "Запрошено \(counter.calls) абзацев из \(Self.lineCount) — это не вьюпорт"
        )
        print("[paragraphs] запрошено \(counter.calls) из ~\(Self.lineCount)")
    }

    @MainActor
    func testScanningOneParagraphIsCheapEvenInAHugeDocument() throws {
        let text = Self.large as NSString
        let middle = text.length / 2
        let paragraphRange = text.paragraphRange(for: NSRange(location: middle, length: 0))

        let time = try measureOnce {
            for _ in 0..<200 {
                _ = HTMLHighlightPlanBuilder.buildPlan(in: text, coveredRange: paragraphRange)
            }
        }
        let perScan = time / 200
        print("[scan] один абзац в середине: \(ms(perScan))")
        XCTAssertLessThan(perScan, 0.001, "Скан одного абзаца дороже миллисекунды: \(ms(perScan))")
    }

    // MARK: - Helpers

    private func measureOnce(_ body: () throws -> Void) rethrows -> TimeInterval {
        let start = CFAbsoluteTimeGetCurrent()
        try body()
        return CFAbsoluteTimeGetCurrent() - start
    }

    private func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.3f ms", seconds * 1000)
    }
}

/// Counts how many paragraphs TextKit asks for.
///
/// The failure this exists to catch is the one that looks like success: if the
/// delegate is attached to a content storage the view later replaces,
/// `textLayoutManager` stays non-nil and everything "works" — just without
/// colour.
private final class ParagraphCounter: NSObject, @unchecked Sendable, NSTextContentStorageDelegate {
    private(set) var calls = 0

    func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        calls += 1
        return nil
    }
}
