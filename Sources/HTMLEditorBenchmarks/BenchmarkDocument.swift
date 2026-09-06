import Foundation

/// Generates HTML shaped like the documents this editor actually struggles with,
/// rather than the uniform short lines that earlier synthetic input used.
///
/// Shape is what the highlighting pipeline reacts to, not content. The previous
/// generator emitted nothing but short, newline-terminated rows — the one shape
/// that hid a whole-document line scan on every keystroke, because a range
/// snapping outward to line boundaries stayed small. Real pages mix that with
/// long minified runs, inline `<style>` and `<script>` blocks, non-ASCII text,
/// and deep nesting, so the generator does too.
enum BenchmarkDocument {
    /// Roughly how many UTF-16 units to emit. The result overshoots slightly,
    /// finishing whichever section it is in.
    static func make(targetUTF16Length: Int) -> String {
        var parts: [String] = [header]
        var length = header.utf16.count
        var index = 0

        while length < targetUTF16Length {
            let section = self.section(index)
            parts.append(section)
            length += section.utf16.count
            index += 1
        }

        parts.append(footer)
        return parts.joined()
    }

    /// The four shapes are interleaved rather than grouped so that any given
    /// viewport is likely to span more than one of them.
    private static func section(_ index: Int) -> String {
        switch index % 4 {
        case 0: return prettyPrintedBlock(index)
        case 1: return minifiedRun(index)
        case 2: return nonASCIIBlock(index)
        default: return embeddedCodeBlock(index)
        }
    }

    private static let header = """
    <!DOCTYPE html>
    <html lang="en" data-color-mode="auto" data-theme="light">
    <head>
    <meta charset="utf-8">
    <title>Benchmark document</title>
    </head>
    <body>

    """

    private static let footer = "\n</body>\n</html>\n"

    /// Ordinary formatted markup: short lines, one tag per line, nested a few
    /// levels deep.
    private static func prettyPrintedBlock(_ index: Int) -> String {
        var block = """
        <section id="section-\(index)" class="panel panel--wide" data-index="\(index)">
          <header class="panel__header">
            <h2 class="panel__title">Section \(index)</h2>
          </header>
          <div class="panel__body">

        """

        for row in 0..<24 {
            block += """
              <article class="card" data-id="\(index)-\(row)" data-state="idle">
                <a class="card__link" href="https://example.com/items/\(index)/\(row)" rel="noopener">Item \(row)</a>
                <p class="card__text">Plain text that carries no markup at all, which is what most of a page is.</p>
              </article>

            """
        }

        return block + "  </div>\n</section>\n\n"
    }

    /// A single line thousands of units long. This is the shape that makes an
    /// unbounded line search scan the whole document.
    private static func minifiedRun(_ index: Int) -> String {
        var line = "<div class=\"m\" data-run=\"\(index)\">"
        for item in 0..<140 {
            line += "<span class=\"c\" data-k=\"\(item)\" title=\"tooltip \(item)\">"
            line += "<b>\(item)</b><i>·</i><a href=\"/x/\(index)/\(item)\">link</a>"
            line += "</span>"
        }
        return line + "</div>\n"
    }

    /// Non-ASCII content, so UTF-16 offsets stop matching character counts and
    /// surrogate pairs appear in the scanner's input.
    private static func nonASCIIBlock(_ index: Int) -> String {
        var block = "<section class=\"i18n\" data-index=\"\(index)\">\n"
        let samples = [
            "Текст на русском языке с разметкой внутри абзаца.",
            "日本語のテキストと<strong>タグ</strong>の混在。",
            "Ελληνικό κείμενο με χαρακτηριστικά γνωρίσματα.",
            "Emoji run: 🎯🔥🧪🚀 mixed with <em>markup</em>."
        ]

        for row in 0..<12 {
            let sample = samples[row % samples.count]
            block += "  <p class=\"i18n__line\" lang=\"auto\" data-row=\"\(row)\">\(sample)</p>\n"
        }

        return block + "</section>\n\n"
    }

    /// Inline `<style>` and `<script>`. The scanner does not understand either,
    /// so their bodies are a long stretch of text containing characters — angle
    /// brackets, quotes — that look structural but are not.
    private static func embeddedCodeBlock(_ index: Int) -> String {
        """
        <style type="text/css">
        .panel-\(index) { display: flex; align-items: center; gap: 8px; }
        .panel-\(index) > .card { border: 1px solid rgba(0, 0, 0, 0.12); border-radius: 6px; }
        .panel-\(index) a[href^="https://"]::after { content: " ↗"; opacity: 0.6; }
        @media (max-width: 600px) { .panel-\(index) { flex-direction: column; } }
        </style>
        <script type="text/javascript">
        (function () {
          var nodes = document.querySelectorAll('.panel-\(index) .card');
          for (var i = 0; i < nodes.length; i++) {
            if (nodes[i].dataset.state !== 'idle' && i < 10) {
              nodes[i].setAttribute('aria-label', 'card ' + i + ' of ' + nodes.length);
            }
          }
        })();
        </script>

        """
    }
}
