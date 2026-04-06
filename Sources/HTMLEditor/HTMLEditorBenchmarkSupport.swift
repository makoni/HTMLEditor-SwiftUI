#if os(macOS)
import AppKit
import Foundation

public struct HTMLEditorBenchmarkResult: Sendable {
    public let label: String
    public let averageMilliseconds: Double
    public let minimumMilliseconds: Double
    public let maximumMilliseconds: Double
}

public enum HTMLEditorBenchmarkSupport {
    public static func runDefaultBenchmarks(sampleHTML: String) async -> [HTMLEditorBenchmarkResult] {
        await [
            benchmarkPlannedFull(sampleHTML),
            benchmarkOverlap(sampleHTML),
            benchmarkSameLengthEdit(sampleHTML),
            benchmarkLengthChangingEdit(sampleHTML),
            benchmarkContextIndependentReuse(),
            benchmarkVisibleHighlightRemap(sampleHTML),
            benchmarkDirtyBlockLocalPass(sampleHTML, localLength: 256),
            benchmarkDirtyBlockLocalPass(sampleHTML),
            benchmarkLayoutVisibleRangeMap(sampleHTML),
            benchmarkApplyTemporaryVisiblePlan(sampleHTML),
            benchmarkDirtyBlockLocalPass(sampleHTML, localLength: 512),
            benchmarkDirtyBlockLocalPass(sampleHTML, localLength: 768),
            benchmarkDirtyBlockLocalPass(sampleHTML, localLength: 1_024)
        ]
    }

    private static func benchmarkPlannedFull(_ sampleHTML: String) async -> HTMLEditorBenchmarkResult {
        await measure(label: "bench-planned-full-45k", iterations: 20) {
            _ = await HTMLSyntaxHighlighter.plannedFullHighlight(documentID: UUID(), html: sampleHTML)
        }
    }

    private static func benchmarkOverlap(_ sampleHTML: String) async -> HTMLEditorBenchmarkResult {
        let documentID = UUID()
        _ = await HTMLSyntaxHighlighter.plannedRangeHighlight(
            documentID: documentID,
            text: sampleHTML,
            requestedRange: NSRange(location: 14_000, length: 1_600)
        )

        return await measure(label: "bench-overlap-range", iterations: 25) {
            _ = await HTMLSyntaxHighlighter.plannedRangeHighlight(
                documentID: documentID,
                text: sampleHTML,
                requestedRange: NSRange(location: 14_220, length: 1_600)
            )
        }
    }

    private static func benchmarkSameLengthEdit(_ sampleHTML: String) async -> HTMLEditorBenchmarkResult {
        let documentID = UUID()
        let targetRange = NSRange(location: 12_000, length: 1_800)
        _ = await HTMLSyntaxHighlighter.plannedRangeHighlight(
            documentID: documentID,
            text: sampleHTML,
            requestedRange: targetRange
        )
        await HTMLSyntaxHighlighter.invalidatePlannerCache(
            documentID: documentID,
            editRange: NSRange(location: 12_020, length: 5),
            replacementUTF16Length: 5,
            newTextLength: sampleHTML.utf16.count
        )

        return await measure(label: "bench-same-length-edit", iterations: 25) {
            _ = await HTMLSyntaxHighlighter.plannedRangeHighlight(
                documentID: documentID,
                text: sampleHTML,
                requestedRange: targetRange
            )
        }
    }

    private static func benchmarkLengthChangingEdit(_ sampleHTML: String) async -> HTMLEditorBenchmarkResult {
        let documentID = UUID()
        let targetRange = NSRange(location: 18_000, length: 1_500)
        _ = await HTMLSyntaxHighlighter.plannedRangeHighlight(
            documentID: documentID,
            text: sampleHTML,
            requestedRange: targetRange
        )
        await HTMLSyntaxHighlighter.invalidatePlannerCache(
            documentID: documentID,
            editRange: NSRange(location: 400, length: 4),
            replacementUTF16Length: 9,
            newTextLength: sampleHTML.utf16.count + 5
        )

        return await measure(label: "bench-length-changing-edit", iterations: 25) {
            _ = await HTMLSyntaxHighlighter.plannedRangeHighlight(
                documentID: documentID,
                text: sampleHTML,
                requestedRange: targetRange
            )
        }
    }

    private static func benchmarkContextIndependentReuse() async -> HTMLEditorBenchmarkResult {
        let documentID = UUID()
        let html = String(repeating: "<div>plain text</div>\n", count: 220)
        let targetRange = NSRange(location: 2_048, length: 512)
        _ = await HTMLSyntaxHighlighter.plannedRangeHighlight(
            documentID: documentID,
            text: html,
            requestedRange: targetRange
        )
        await HTMLSyntaxHighlighter.invalidatePlannerCache(
            documentID: documentID,
            editRange: NSRange(location: 32, length: 1),
            replacementUTF16Length: 1,
            newTextLength: html.utf16.count
        )

        return await measure(label: "bench-context-independent-reuse", iterations: 25) {
            _ = await HTMLSyntaxHighlighter.plannedRangeHighlight(
                documentID: documentID,
                text: html,
                requestedRange: targetRange
            )
        }
    }

    private static func benchmarkVisibleHighlightRemap(_ sampleHTML: String) async -> HTMLEditorBenchmarkResult {
        let initialPlan = await HTMLSyntaxHighlighter.plannedRangeHighlight(
            documentID: UUID(),
            text: sampleHTML,
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

    private static func benchmarkDirtyBlockLocalPass(_ sampleHTML: String) async -> HTMLEditorBenchmarkResult {
        await benchmarkDirtyBlockLocalPass(sampleHTML, localLength: 1_024)
    }

    private static func benchmarkDirtyBlockLocalPass(
        _ sampleHTML: String,
        localLength: Int
    ) async -> HTMLEditorBenchmarkResult {
        let initialPlan = await HTMLSyntaxHighlighter.plannedRangeHighlight(
            documentID: UUID(),
            text: sampleHTML,
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

    private static func benchmarkLayoutVisibleRangeMap(_ sampleHTML: String) async -> HTMLEditorBenchmarkResult {
        let runtime = makeRuntimeProbe(sampleHTML)

        return await measure(label: "bench-layout-visible-range-map", iterations: 100) {
            let glyphRange = runtime.layoutManager.glyphRange(forBoundingRect: runtime.probeRect, in: runtime.textContainer)
            _ = runtime.layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        }
    }

    private static func benchmarkApplyTemporaryVisiblePlan(_ sampleHTML: String) async -> HTMLEditorBenchmarkResult {
        let runtime = makeRuntimeProbe(sampleHTML)
        let plan = await HTMLSyntaxHighlighter.plannedRangeHighlight(
            documentID: UUID(),
            text: sampleHTML,
            requestedRange: runtime.visibleRange
        )

        return await measure(label: "bench-apply-temporary-visible-plan", iterations: 100) {
            HTMLSyntaxHighlighter.applyTemporary(plan: plan, to: runtime.layoutManager, theme: runtime.theme)
        }
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

        let average = samples.reduce(0, +) / Double(samples.count)
        return HTMLEditorBenchmarkResult(
            label: label,
            averageMilliseconds: average,
            minimumMilliseconds: samples.min() ?? 0,
            maximumMilliseconds: samples.max() ?? 0
        )
    }

    private static func replaceUTF16Range(in text: String, range: NSRange, replacement: String) -> String {
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: range, with: replacement)
        return mutable as String
    }

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
