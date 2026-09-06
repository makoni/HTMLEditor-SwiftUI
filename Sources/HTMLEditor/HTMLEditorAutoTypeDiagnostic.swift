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

            // Driven by a tight loop that pumps the run loop to quiescence after
            // each keystroke, rather than by a Timer: an unfocused app has its
            // timers coalesced by the system, which showed up as half-second
            // gaps that had nothing to do with the editor.
            NSApp.activate(ignoringOtherApps: true)
            let state = TypingState()
            for _ in 0..<120 {
                state.step(textView: textView, settle: millis / 1000)
            }
            state.finish()
        }
    }

    @MainActor
    private final class TypingState {
        private var typed = 0
        private var worst: Double = 0
        private var total: Double = 0

        private var settleTotal: Double = 0
        private var settleWorst: Double = 0

        func step(textView: NSTextView, settle: Double) {
            let selected = textView.selectedRange()

            let start = DispatchTime.now().uptimeNanoseconds
            textView.insertText("x", replacementRange: selected)
            let inserted = DispatchTime.now().uptimeNanoseconds

            // Everything the keystroke set in motion — layout, drawing, the
            // deferred passes — happens on the run loop after insertText
            // returns. That is what a person waits for, so measure it.
            let deadline = Date().addingTimeInterval(settle)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
            }
            let settled = DispatchTime.now().uptimeNanoseconds

            let insertMS = Double(inserted - start) / 1_000_000
            let settleMS = Double(settled - inserted) / 1_000_000 - settle * 1000

            typed += 1
            total += insertMS
            settleTotal += max(0, settleMS)
            if insertMS > worst { worst = insertMS }
            if settleMS > settleWorst { settleWorst = settleMS }

            if typed % 40 == 0 {
                NSLog("AUTOTYPE #%d insert %.2fms settle-overrun %.2fms", typed, insertMS, settleMS)
            }
        }

        func finish() {
            NSLog("AUTOTYPE done: %d keystrokes | insert mean %.2fms worst %.2fms | settle-overrun mean %.2fms worst %.2fms",
                  typed, total / Double(max(typed, 1)), worst,
                  settleTotal / Double(max(typed, 1)), settleWorst)
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
