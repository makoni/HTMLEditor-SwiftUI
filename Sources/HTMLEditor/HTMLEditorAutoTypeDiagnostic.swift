#if os(macOS)
import AppKit

/// Temporary diagnostic driver. Types into the running editor through the real
/// `insertText` path so a profiler sees exactly what a person typing would
/// produce — undo registration, delegate callbacks, layout and drawing — rather
/// than the narrower path a benchmark can reach.
///
/// Enabled with `HTMLEDITOR_AUTOTYPE_MS=<interval>`; `HTMLEDITOR_AUTOTYPE_WHERE`
/// picks `longline` (default) or `mid`, and `HTMLEDITOR_AUTOTYPE_TEXT` chooses
/// what to type: `plain` for letters, or `html` (default) for markup typed one
/// character at a time.
///
/// The distinction matters more than anything else measured here. A letter
/// changes one character's colour. Typing `<a href="` opens a tag and then an
/// unterminated quoted value, so on each keystroke the *entire rest of the
/// paragraph* is reinterpreted — a 28 000-character line stops being a thousand
/// small spans and becomes one enormous attribute value — and TextKit has to
/// restyle and re-lay out all of it.
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

            let snippet: String
            switch ProcessInfo.processInfo.environment["HTMLEDITOR_AUTOTYPE_TEXT"] {
            case "plain":
                snippet = String(repeating: "x", count: 120)
            case "unclosed":
                // The worst shape: the quote is never closed, so from the second
                // keystroke onwards the whole rest of the paragraph parses as one
                // attribute value and is restyled on every character.
                snippet = #"<a href="https://example.com/some/fairly/long/path/for/testing"#
            default:
                snippet = String(repeating: #"<a href="https://example.com/page">link</a>"#, count: 3)
            }

            let state = TypingState()
            for character in snippet {
                state.step(textView: textView, typing: String(character), settle: millis / 1000)
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

        func step(textView: NSTextView, typing text: String, settle: Double) {
            let selected = textView.selectedRange()

            let start = DispatchTime.now().uptimeNanoseconds
            textView.insertText(text, replacementRange: selected)
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

            if insertMS + settleMS > 12 || typed % 20 == 0 {
                NSLog("AUTOTYPE #%d '%@' insert %.2fms settle %.2fms",
                      typed, text, insertMS, settleMS)
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
