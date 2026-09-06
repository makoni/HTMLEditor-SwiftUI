#if os(macOS)
import AppKit

/// Temporary diagnostic driver. Types into the running editor through the real
/// `insertText` path so a profiler sees exactly what a person typing would
/// produce — undo registration, delegate callbacks, layout and drawing — rather
/// than the narrower path a benchmark can reach.
///
/// Enabled with `HTMLEDITOR_AUTOTYPE_MS=<interval>`; `HTMLEDITOR_AUTOTYPE_WHERE`
/// picks `longline` (default) or `mid`.
///
/// Delete once the TextKit question is settled.
enum HTMLEditorAutoTypeDiagnostic {
    @MainActor
    static func startIfRequested(textView: NSTextView, scrollView: NSScrollView) {
        guard let millis = ProcessInfo.processInfo.environment["HTMLEDITOR_AUTOTYPE_MS"]
            .flatMap(Double.init) else { return }

        let where_ = ProcessInfo.processInfo.environment["HTMLEDITOR_AUTOTYPE_WHERE"] ?? "longline"
        let text = textView.string as NSString
        let caret = where_ == "mid" ? text.length / 2 : middleOfLongestLine(text)

        NSLog("AUTOTYPE: %d units, caret %d (%@), textKit2=%@",
              text.length, caret, where_,
              textView.textLayoutManager != nil ? "yes" : "no")

        // Let the first layout and highlight pass settle before typing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            textView.scrollRangeToVisible(NSRange(location: caret, length: 0))

            let state = TypingState()
            let timer = Timer(timeInterval: millis / 1000, repeats: true) { _ in
                MainActor.assumeIsolated {
                    state.step(textView: textView)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            state.timer = timer
        }
    }

    @MainActor
    private final class TypingState {
        var timer: Timer?
        private var typed = 0
        private var worst: Double = 0
        private var total: Double = 0

        func step(textView: NSTextView) {
            guard typed < 120 else {
                NSLog("AUTOTYPE done: %d keystrokes, mean %.2fms, worst %.2fms",
                      typed, total / Double(max(typed, 1)), worst)
                timer?.invalidate()
                timer = nil
                return
            }

            let selected = textView.selectedRange()
            let start = DispatchTime.now().uptimeNanoseconds
            textView.insertText("x", replacementRange: selected)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

            typed += 1
            total += elapsed
            if elapsed > worst { worst = elapsed }
            if elapsed > 8 {
                NSLog("AUTOTYPE slow keystroke #%d: %.2fms", typed, elapsed)
            }
        }
    }

    @MainActor
    private static func middleOfLongestLine(_ text: NSString) -> Int {
        var start = 0
        var length = 0
        var lineStart = 0
        for index in 0..<text.length where text.character(at: index) == 10 {
            if index - lineStart > length {
                length = index - lineStart
                start = lineStart
            }
            lineStart = index + 1
        }
        return start + length / 2
    }
}
#endif
