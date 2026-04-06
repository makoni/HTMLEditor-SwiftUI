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
            benchmarkContextIndependentReuse()
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
}
#endif
