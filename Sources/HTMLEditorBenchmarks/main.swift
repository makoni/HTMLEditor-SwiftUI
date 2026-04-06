import AppKit
import Foundation
import HTMLEditor

@main
struct HTMLEditorBenchmarks {
    static func main() async throws {
        let html = try loadBenchmarkHTML()
        let sample = String(html.prefix(45_000))

        let samples = await HTMLEditorBenchmarkSupport.runDefaultBenchmarks(sampleHTML: sample)

        for sample in samples {
            print(
                "\(sample.label): avg=\(format(sample.averageMilliseconds))ms " +
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
        return String(repeating: row + "\n", count: 700)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
