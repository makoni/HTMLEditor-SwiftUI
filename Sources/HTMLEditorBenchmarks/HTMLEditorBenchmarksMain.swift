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
        print("longest line: \(longestLineLength(html)) units")

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

    /// Size of the generated document, in UTF-16 units.
    ///
    /// The default clears the conservative threshold so all three regimes are
    /// covered without an external file. `HTML_EDITOR_BENCHMARK_LENGTH` raises
    /// it — 13_000_000 approximates a full saved web page — at the cost of a
    /// much slower run.
    private static func syntheticBenchmarkHTML() -> String {
        let requested = ProcessInfo.processInfo.environment["HTML_EDITOR_BENCHMARK_LENGTH"]
            .flatMap(Int.init)
        return BenchmarkDocument.make(targetUTF16Length: requested ?? 1_000_000)
    }

    private static func longestLineLength(_ html: String) -> Int {
        var longest = 0
        var current = 0
        for unit in html.utf16 {
            if unit == 10 {
                longest = max(longest, current)
                current = 0
            } else {
                current += 1
            }
        }
        return max(longest, current)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
