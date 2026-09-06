import AppKit
import Foundation
import HTMLEditor

@main
struct HTMLEditorBenchmarks {
    static func main() async throws {
        let html = try loadBenchmarkHTML()
        // The truncated sample keeps the full-semantic regime measurable; the
        // unmodified document is what exercises the large-document paths.
        let sample = String(html.prefix(45_000))

        print("document: \(html.utf16.count) UTF-16 units, sample: \(sample.utf16.count)")

        let samples = await HTMLEditorBenchmarkSupport.runDefaultBenchmarks(
            sampleHTML: sample,
            largeHTML: html
        )

        for sample in samples {
            print(
                "\(sample.label): avg=\(format(sample.averageMilliseconds))ms " +
                "p50=\(format(sample.medianMilliseconds))ms " +
                "min=\(format(sample.minimumMilliseconds))ms " +
                "max=\(format(sample.maximumMilliseconds))ms"
            )
        }
    }

    private static func loadBenchmarkHTML() throws -> String {
        let path = ProcessInfo.processInfo.environment["HTML_EDITOR_BENCHMARK_HTML"] ?? "/tmp/pikabu-copilot-benchmark.html"
        guard FileManager.default.fileExists(atPath: path) else {
            return syntheticBenchmarkHTML()
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let string = NSString(data: data, encoding: String.Encoding.utf8.rawValue) {
            return string as String
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func syntheticBenchmarkHTML() -> String {
        let row = #"<div class="row" data-id="123"><a href="https://example.com/item">plain text</a><span>value</span></div>"#
        // Large enough to reach the >150_000 conservative regime, so the suite
        // covers all three size regimes without an external file.
        return String(repeating: row + "\n", count: 10_000)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
