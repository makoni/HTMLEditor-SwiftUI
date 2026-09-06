#if os(macOS)
import AppKit
import Foundation

public struct HTMLEditorBenchmarkResult: Sendable {
    public let label: String
    public let averageMilliseconds: Double
    public let medianMilliseconds: Double
    public let minimumMilliseconds: Double
    public let maximumMilliseconds: Double
}

public enum HTMLEditorBenchmarkSupport {
    /// Runs the benchmark suite.
    ///
    /// `sampleHTML` stays below `HTMLSyntaxHighlighter.maxHighlightLength` so the
    /// full-semantic regime is measured.  `largeHTML` is the caller's unmodified
    /// input and exercises the viewport-first and conservative regimes, which the
    /// suite never reached while every benchmark ran against a truncated sample.
    public static func runDefaultBenchmarks(
        sampleHTML: String,
        largeHTML: String
    ) async -> [HTMLEditorBenchmarkResult] {
        var results = await [
            benchmarkPlannedFull(sampleHTML),
            benchmarkOverlap(sampleHTML),
            benchmarkSameLengthEdit(sampleHTML),
            benchmarkLengthChangingEdit(sampleHTML),
            benchmarkContextIndependentReuse(),
            benchmarkVisibleHighlightRemap(sampleHTML),
            benchmarkDirtyBlockLocalPass(sampleHTML, localLength: 256),
            benchmarkDirtyBlockLocalPass(sampleHTML, localLength: 512),
            benchmarkDirtyBlockLocalPass(sampleHTML, localLength: 768),
            benchmarkDirtyBlockLocalPass(sampleHTML, localLength: 1_024)
        ]

        results += await MainActor.run {
            var mainActorResults = [
                benchmarkLayoutVisibleRangeMap(sampleHTML),
                benchmarkApplyTemporaryVisiblePlan(sampleHTML),
                benchmarkPlanOverTextStorageString(sampleHTML)
            ]
            // Opt-in: it hosts a window and drives the real edit path, which is
            // slower and needs a usable AppKit session.
            if ProcessInfo.processInfo.environment["HTML_EDITOR_BENCHMARK_KEYSTROKE"] != nil {
                mainActorResults += benchmarkKeystrokePath(largeHTML, caret: .midDocument)
                mainActorResults += benchmarkKeystrokePath(largeHTML, caret: .longestLine)
            }
            return mainActorResults
        }

        results += await [
            benchmarkCoverageRemap(textLength: 200_000),
            benchmarkCoverageRemap(textLength: 1_000_000),
            benchmarkCoverageRemap(textLength: 2_000_000),
            benchmarkNormalizedRange(largeHTML, label: "as-supplied"),
            benchmarkNormalizedRange(minified(largeHTML), label: "minified"),
            benchmarkLargeDocumentRangePlan(largeHTML),
            benchmarkKeystrokeLocalPass(largeHTML, label: "as-supplied"),
            benchmarkKeystrokeLocalPass(minified(largeHTML), label: "minified")
        ]

        return results
    }

    private static func benchmarkPlannedFull(_ sampleHTML: String) async -> HTMLEditorBenchmarkResult {
        await measure(label: "bench-planned-full-45k", iterations: 20) {
            _ = await HTMLHighlightPlanner().fullPlan(for: sampleHTML)
        }
    }

    private static func benchmarkOverlap(_ sampleHTML: String) async -> HTMLEditorBenchmarkResult {
        let planner = HTMLHighlightPlanner()
        _ = await planner.rangePlan(
            for: sampleHTML,
            requestedRange: NSRange(location: 14_000, length: 1_600)
        )

        return await measure(label: "bench-overlap-range", iterations: 25) {
            _ = await planner.rangePlan(
                for: sampleHTML,
            requestedRange: NSRange(location: 14_220, length: 1_600)
            )
        }
    }

    private static func benchmarkSameLengthEdit(_ sampleHTML: String) async -> HTMLEditorBenchmarkResult {
        let planner = HTMLHighlightPlanner()
        let targetRange = NSRange(location: 12_000, length: 1_800)
        _ = await planner.rangePlan(
            for: sampleHTML,
            requestedRange: targetRange
        )
        await planner.invalidate(
            editRange: NSRange(location: 12_020, length: 5),
            replacementUTF16Length: 5,
            newTextLength: sampleHTML.utf16.count
        )

        return await measure(label: "bench-same-length-edit", iterations: 25) {
            _ = await planner.rangePlan(
                for: sampleHTML,
            requestedRange: targetRange
            )
        }
    }

    private static func benchmarkLengthChangingEdit(_ sampleHTML: String) async -> HTMLEditorBenchmarkResult {
        let planner = HTMLHighlightPlanner()
        let targetRange = NSRange(location: 18_000, length: 1_500)
        _ = await planner.rangePlan(
            for: sampleHTML,
            requestedRange: targetRange
        )
        await planner.invalidate(
            editRange: NSRange(location: 400, length: 4),
            replacementUTF16Length: 9,
            newTextLength: sampleHTML.utf16.count + 5
        )

        return await measure(label: "bench-length-changing-edit", iterations: 25) {
            _ = await planner.rangePlan(
                for: sampleHTML,
            requestedRange: targetRange
            )
        }
    }

    private static func benchmarkContextIndependentReuse() async -> HTMLEditorBenchmarkResult {
        let planner = HTMLHighlightPlanner()
        let html = String(repeating: "<div>plain text</div>\n", count: 220)
        let targetRange = NSRange(location: 2_048, length: 512)
        _ = await planner.rangePlan(
            for: html,
            requestedRange: targetRange
        )
        await planner.invalidate(
            editRange: NSRange(location: 32, length: 1),
            replacementUTF16Length: 1,
            newTextLength: html.utf16.count
        )

        return await measure(label: "bench-context-independent-reuse", iterations: 25) {
            _ = await planner.rangePlan(
                for: html,
            requestedRange: targetRange
            )
        }
    }

    private static func benchmarkVisibleHighlightRemap(_ sampleHTML: String) async -> HTMLEditorBenchmarkResult {
        let initialPlan = await HTMLHighlightPlanner().rangePlan(
            for: sampleHTML,
            requestedRange: NSRange(location: 14_000, length: 1_600)
        )
        let editLocation = 14_320
        let replacement = " data-role=\"new\""
        let updatedHTML = replaceUTF16Range(
            in: sampleHTML,
            range: NSRange(location: editLocation, length: 0),
            replacement: replacement
        )

        return await measure(label: "bench-visible-highlight-remap", iterations: 25) {
            _ = HTMLEditorVisibleHighlightState.remapPlan(
                initialPlan,
                editRange: NSRange(location: editLocation, length: 0),
                replacementLength: replacement.utf16.count,
                newTextLength: updatedHTML.utf16.count,
                dirtyRange: HTMLEditorVisibleHighlightState.dirtyRange(
                    for: NSRange(location: editLocation, length: 0),
                    replacementLength: replacement.utf16.count,
                    newTextLength: updatedHTML.utf16.count,
                    expansion: HTMLEditor.highlightBudget(forTextLength: updatedHTML.utf16.count).visibleExpansion
                )
            )
        }
    }

    private static func benchmarkDirtyBlockLocalPass(
        _ sampleHTML: String,
        localLength: Int
    ) async -> HTMLEditorBenchmarkResult {
        let initialPlan = await HTMLHighlightPlanner().rangePlan(
            for: sampleHTML,
            requestedRange: NSRange(location: 14_000, length: 1_600)
        )
        let localRange = NSRange(location: 14_200, length: min(localLength, max(1, sampleHTML.utf16.count - 14_200)))

        return await measure(label: "bench-dirty-block-local-pass-\(localLength)", iterations: 25) {
            let localPlan = HTMLHighlightPlanBuilder.rangePlan(
                for: sampleHTML,
                requestedRange: localRange
            )
            _ = HTMLSyntaxHighlighter.mergedPlan(
                base: initialPlan,
                overlay: HTMLSyntaxHighlighter.clippedPlan(localPlan, to: localRange)
            )
        }
    }

    /// Cost of `HTMLEditorHighlightCoverage.remapAfterEdit` for a document that has
    /// been scrolled end to end, which is the shape that makes the remap expensive.
    private static func benchmarkCoverageRemap(textLength: Int) async -> HTMLEditorBenchmarkResult {
        let editRange = NSRange(location: textLength / 2, length: 0)
        let dirtyRange = HTMLEditorVisibleHighlightState.dirtyRange(
            for: editRange,
            replacementLength: 1,
            newTextLength: textLength,
            expansion: 200
        )
        var scrolled = HTMLEditorHighlightCoverage()
        scrolled.markHighlighted(NSRange(location: 0, length: textLength))
        let baseline = scrolled

        return await measure(label: "bench-coverage-remap-\(textLength)", iterations: 25) {
            var coverage = baseline
            coverage.remapAfterEdit(
                editRange: editRange,
                replacementUTF16Length: 1,
                newTextLength: textLength,
                dirtyRange: dirtyRange
            )
        }
    }

    /// `normalizedRange` snaps short ranges to line boundaries, so a document with
    /// no newlines expands to its full length.  Measuring both shapes keeps that
    /// difference visible.
    private static func benchmarkNormalizedRange(_ html: String, label: String) async -> HTMLEditorBenchmarkResult {
        let requestedRange = NSRange(location: max(0, html.utf16.count / 2), length: 256)

        return await measure(label: "bench-normalized-range-\(label)", iterations: 25) {
            _ = HTMLHighlightPlanBuilder.normalizedRange(for: html, requestedRange: requestedRange)
        }
    }

    private static func benchmarkLargeDocumentRangePlan(_ html: String) async -> HTMLEditorBenchmarkResult {
        let planner = HTMLHighlightPlanner()
        let requestedRange = NSRange(location: max(0, html.utf16.count / 2), length: 2_048)

        return await measure(label: "bench-large-doc-range-plan", iterations: 25) {
            _ = await planner.rangePlan(
                for: html,
            requestedRange: requestedRange
            )
        }
    }

    /// The synchronous work `applyLocalDirtyHighlight` performs on the main thread
    /// for a single inserted character.
    private static func benchmarkKeystrokeLocalPass(_ html: String, label: String) async -> HTMLEditorBenchmarkResult {
        let textLength = html.utf16.count
        let editRange = NSRange(location: max(0, textLength / 2), length: 0)
        let dirtyRange = HTMLEditor.structuralDirtyRange(
            for: editRange,
            replacementLength: 1,
            in: html as NSString,
            expansion: HTMLEditor.highlightBudget(forTextLength: textLength).visibleExpansion
        )
        let localRange = HTMLEditor.localDirtyHighlightRange(
            around: dirtyRange,
            textLength: textLength,
            maxLength: HTMLEditor.immediateEditHighlightLimit(forTextLength: textLength)
        )

        return await measure(label: "bench-keystroke-local-pass-\(label)", iterations: 25) {
            let localPlan = HTMLHighlightPlanBuilder.rangePlan(for: html, requestedRange: localRange)
            _ = HTMLSyntaxHighlighter.clippedPlan(localPlan, to: localRange)
        }
    }

    private static func minified(_ html: String) -> String {
        html
            .replacingOccurrences(of: "\r\n", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    @MainActor
    private static func benchmarkLayoutVisibleRangeMap(_ sampleHTML: String) -> HTMLEditorBenchmarkResult {
        let runtime = makeRuntimeProbe(sampleHTML)

        return measureSync(label: "bench-layout-visible-range-map", iterations: 100) {
            let glyphRange = runtime.layoutManager.glyphRange(forBoundingRect: runtime.probeRect, in: runtime.textContainer)
            _ = runtime.layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        }
    }

    @MainActor
    private static func benchmarkApplyTemporaryVisiblePlan(_ sampleHTML: String) -> HTMLEditorBenchmarkResult {
        let runtime = makeRuntimeProbe(sampleHTML)
        let plan = HTMLHighlightPlanBuilder.rangePlan(for: sampleHTML, requestedRange: runtime.visibleRange)

        return measureSync(label: "bench-apply-temporary-visible-plan-\(plan.spans.count)-spans", iterations: 100) {
            HTMLSyntaxHighlighter.applyTemporary(plan: plan, to: runtime.layoutManager, theme: runtime.theme)
        }
    }

    /// The same full plan as `bench-planned-full-45k`, but over the string a live
    /// NSTextStorage hands back rather than a bridged Swift string.  That is an
    /// NSBigMutableString, whose per-code-unit reads are markedly more expensive,
    /// so this is the row that reflects what the editor actually pays.
    @MainActor
    private static func benchmarkPlanOverTextStorageString(_ sampleHTML: String) -> HTMLEditorBenchmarkResult {
        let textStorage = NSTextStorage(string: sampleHTML)
        let liveString = textStorage.string

        return measureSync(label: "bench-planned-full-textstorage-string", iterations: 20) {
            _ = HTMLHighlightPlanBuilder.fullPlan(for: liveString)
        }
    }

    /// The per-keystroke cost of the real edit path, with the text view hosted in
    /// a window so that layout invalidation and drawing actually happen.
    ///
    /// Every other row here measures a leaf.  This one exists because the leaves
    /// were all cheap while typing in a large document was not: putting the view
    /// in a window made the coordinator's synchronous work an order of magnitude
    /// more expensive, which no isolated benchmark could show.
    /// Where to put the caret before typing.  Position matters more than
    /// anything the editor does: a word-wrapping text view has to re-wrap the
    /// whole line on every keystroke, so a caret inside a very long line — which
    /// minified HTML is made of — costs several times what one in ordinary
    /// markup does, and that difference dwarfs the coordinator's own work.
    private enum KeystrokeCaret: String {
        case midDocument = "mid"
        case longestLine = "long-line"
    }

    @MainActor
    private static func benchmarkKeystrokePath(
        _ html: String,
        caret: KeystrokeCaret
    ) -> [HTMLEditorBenchmarkResult] {
        let theme = HTMLEditorColorScheme(
            foreground: .black, background: .white, tag: .red,
            attributeName: .blue, attributeValue: .green,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular)
        )

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        textView.isRichText = false
        scrollView.documentView = textView
        textView.string = html
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        // The window must actually be on screen: with the view unhosted, drawing
        // is skipped and the coordinator's work measures an order of magnitude
        // cheaper than it is in the app.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        window.orderBack(nil)

        let coordinator = HTMLEditor.Coordinator(
            HTMLEditor(html: .constant(html), theme: HTMLEditorTheme(light: theme, dark: theme))
        )
        textView.delegate = coordinator
        coordinator.previousText = html

        let caretStart: Int
        switch caret {
        case .midDocument:
            caretStart = html.utf16.count / 2
        case .longestLine:
            caretStart = middleOfLongestLine(in: html as NSString)
        }
        textView.setSelectedRange(NSRange(location: caretStart, length: 0))
        textView.scrollRangeToVisible(NSRange(location: caretStart, length: 0))

        let visibleWindow = coordinator.visibleHighlightWindow(
            for: textView, scrollView: scrollView,
            textLength: textView.string.utf16.count, expansion: 200
        )
        let seed = HTMLHighlightPlanBuilder.rangePlan(for: textView.string, requestedRange: visibleWindow)
        coordinator.visibleHighlightState.replace(with: seed)
        if let layoutManager = textView.layoutManager {
            HTMLSyntaxHighlighter.applyTemporary(plan: seed, to: layoutManager, theme: theme)
        }

        var insertSamples: [Double] = []
        var coordinatorSamples: [Double] = []
        var drawSamples: [Double] = []

        for offset in 0..<40 {
            let insertRange = NSRange(location: caretStart + offset, length: 0)

            let insertStart = DispatchTime.now().uptimeNanoseconds
            textView.textStorage?.replaceCharacters(in: insertRange, with: "x")
            insertSamples.append(Double(DispatchTime.now().uptimeNanoseconds - insertStart) / 1_000_000)

            coordinator.pendingEdit = HTMLEditor.Coordinator.PendingEdit(
                affectedRange: insertRange, replacementUTF16Length: 1
            )
            let coordinatorStart = DispatchTime.now().uptimeNanoseconds
            coordinator.textDidChange(
                Notification(name: NSText.didChangeNotification, object: textView)
            )
            coordinatorSamples.append(Double(DispatchTime.now().uptimeNanoseconds - coordinatorStart) / 1_000_000)

            let drawStart = DispatchTime.now().uptimeNanoseconds
            if let layoutManager = textView.layoutManager, let container = textView.textContainer {
                layoutManager.ensureLayout(forBoundingRect: scrollView.documentVisibleRect, in: container)
            }
            textView.display()
            drawSamples.append(Double(DispatchTime.now().uptimeNanoseconds - drawStart) / 1_000_000)
        }

        return [
            result(label: "bench-keystroke-appkit-insert-\(caret.rawValue)", samples: insertSamples),
            result(label: "bench-keystroke-coordinator-\(caret.rawValue)", samples: coordinatorSamples),
            result(label: "bench-keystroke-layout-and-draw-\(caret.rawValue)", samples: drawSamples)
        ]
    }

    private static func middleOfLongestLine(in text: NSString) -> Int {
        var longestStart = 0
        var longestLength = 0
        var lineStart = 0

        for index in 0..<text.length where text.character(at: index) == 10 {
            if index - lineStart > longestLength {
                longestLength = index - lineStart
                longestStart = lineStart
            }
            lineStart = index + 1
        }

        if text.length - lineStart > longestLength {
            longestLength = text.length - lineStart
            longestStart = lineStart
        }

        return longestStart + longestLength / 2
    }

    private static func measure(
        label: String,
        iterations: Int,
        block: () async -> Void
    ) async -> HTMLEditorBenchmarkResult {
        var samples: [Double] = []
        samples.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            await block()
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end - start) / 1_000_000)
        }

        return result(label: label, samples: samples)
    }

    private static func measureSync(
        label: String,
        iterations: Int,
        block: () -> Void
    ) -> HTMLEditorBenchmarkResult {
        var samples: [Double] = []
        samples.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            block()
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end - start) / 1_000_000)
        }

        return result(label: label, samples: samples)
    }

    private static func result(label: String, samples: [Double]) -> HTMLEditorBenchmarkResult {
        guard !samples.isEmpty else {
            return HTMLEditorBenchmarkResult(
                label: label,
                averageMilliseconds: 0,
                medianMilliseconds: 0,
                minimumMilliseconds: 0,
                maximumMilliseconds: 0
            )
        }

        let sorted = samples.sorted()
        return HTMLEditorBenchmarkResult(
            label: label,
            averageMilliseconds: samples.reduce(0, +) / Double(samples.count),
            medianMilliseconds: sorted[sorted.count / 2],
            minimumMilliseconds: sorted[0],
            maximumMilliseconds: sorted[sorted.count - 1]
        )
    }

    private static func replaceUTF16Range(in text: String, range: NSRange, replacement: String) -> String {
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: range, with: replacement)
        return mutable as String
    }

    @MainActor
    private static func makeRuntimeProbe(_ sampleHTML: String) -> (
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        probeRect: NSRect,
        visibleRange: NSRange,
        theme: HTMLEditorColorScheme
    ) {
        let theme = HTMLEditorColorScheme(
            foreground: .black,
            background: .white,
            tag: .red,
            attributeName: .blue,
            attributeValue: .green,
            font: .systemFont(ofSize: 14)
        )
        let textStorage = NSTextStorage(string: sampleHTML)
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.addAttribute(.font, value: theme.font, range: fullRange)
        textStorage.addAttribute(.foregroundColor, value: theme.foreground, range: fullRange)

        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 900, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        let probeRect = NSRect(x: 0, y: max(0, usedRect.midY - 300), width: 900, height: 600)
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: probeRect, in: textContainer)
        let visibleRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
        return (layoutManager, textContainer, probeRect, visibleRange, theme)
    }
}
#endif
