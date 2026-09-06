# HTMLEditor-SwiftUI

<img src="https://arm1.ru/img/uploaded/html-editor-for-swiftui-1-1-0.webp" alt="SwiftUI text editor for macOS with HTML syntax highlighting">

`HTMLEditor-SwiftUI` is a macOS Swift package that provides a SwiftUI HTML editor with syntax highlighting, theme support, and an adaptive large-document runtime designed to keep typing and scrolling responsive.

## Requirements

- macOS 13+
- Swift 6 toolchain
- Compatible with Swift 6.3

## Features

- SwiftUI `HTMLEditor` backed by AppKit for macOS editing behavior.
- HTML syntax highlighting for tags, attribute names, and attribute values.
- Custom light and dark themes with configurable fonts and colors.
- Built on **TextKit 2**, which lays out only the visible portion of the
  document. Highlighting is pulled from an `NSTextContentStorageDelegate`:
  TextKit asks for each paragraph as it lays it out, so there is no scheduling,
  no prewarming and no visible range to keep in step with the viewport.
- Colours are display attributes, never written into the text storage, so undo
  stays intact.
- Tuned against multi-megabyte documents, including the very long single lines
  minified HTML is made of.
- Benchmark target for repeatable performance measurements.

## Installation

### Xcode

1. Open your project in Xcode.
2. Choose **File > Add Packages...**
3. Enter:

   ```text
   https://github.com/makoni/HTMLEditor-SwiftUI.git
   ```

4. Add the library product **HTMLEditor-SwiftUI**.
5. Import the module in Swift code:

   ```swift
   import HTMLEditor
   ```

### Swift Package Manager

```swift
.package(url: "https://github.com/makoni/HTMLEditor-SwiftUI.git", from: "1.2.0")
```

## Basic Usage

```swift
import SwiftUI
import HTMLEditor

struct ContentView: View {
    @State private var htmlContent = "<p>Hello, World!</p>"

    var body: some View {
        HTMLEditor(html: $htmlContent)
            .frame(minWidth: 400, minHeight: 300)
            .padding()
    }
}
```

## Custom Theme Example

```swift
import SwiftUI
import AppKit
import HTMLEditor

struct CustomThemeView: View {
    @State private var htmlContent = "<p>Custom Theme Example</p>"

    private let customTheme = HTMLEditorTheme(
        light: HTMLEditorColorScheme(
            foreground: .blue,
            background: .yellow,
            tag: .purple,
            attributeName: .orange,
            attributeValue: .green,
            font: .monospacedSystemFont(ofSize: 16, weight: .bold)
        ),
        dark: HTMLEditorColorScheme(
            foreground: .white,
            background: .black,
            tag: .red,
            attributeName: .cyan,
            attributeValue: .magenta,
            font: .monospacedSystemFont(ofSize: 16, weight: .bold)
        )
    )

    var body: some View {
        HTMLEditor(html: $htmlContent, theme: customTheme)
            .frame(minWidth: 400, minHeight: 300)
            .padding()
    }
}
```

## Large HTML Behavior

The editor is meant for both short snippets and multi-megabyte files. Two
things behave differently once a document gets large, and both are visible from
the outside, so they are worth knowing about.

**Very long lines are not coloured.** A paragraph longer than 6 000 UTF-16 units
is left at the base colour. That is far above anything hand-written — a
formatted HTML line is rarely past a few hundred units — and below the minified
runs that make typing slow: a paragraph carrying a thousand attribute runs costs
TextKit roughly seven times more to lay out than uniform text, which measured
27.5 ms per keystroke against 4.0 ms on a 28 000-character line.

**The binding lags on large documents.** Publishing through `html` makes SwiftUI
compare the old and new value, which for a multi-megabyte string costs about
200 ms on the main thread. The editor therefore waits for a pause in typing
before publishing, and the wait grows with the document:

| Document size (UTF-16 units) | Delay before publishing |
| --- | --- |
| up to 50 000 | immediate |
| 50 000 – 150 000 | 125 ms |
| 150 000 – 1 000 000 | 800 ms |
| over 1 000 000 | 2 s |

The text view itself is always current; it is the value a host reads back that
lags. Ending editing — moving focus away — flushes immediately.

Setting `HTMLEDITOR_TEXTKIT=1` in the environment creates the text view with
TextKit 1 instead. It is markedly slower on large documents and exists only as
an escape hatch.

## Benchmarks

The package includes an executable benchmark target:

```bash
swift run HTMLEditorBenchmarks
```

To benchmark a specific HTML file:

```bash
HTML_EDITOR_BENCHMARK_HTML=/path/to/file.html swift run HTMLEditorBenchmarks
```

Without a file, input is generated with the shapes that stress the pipeline —
long lines, non-ASCII text, inline `<style>` and `<script>`. `HTML_EDITOR_BENCHMARK_LENGTH`
sets its size in UTF-16 units, and `HTML_EDITOR_BENCHMARK_KEYSTROKE=1` adds a
measurement of the real per-keystroke edit path.

## Demo App

The repository includes a demo app in `HTMLEditorDemoApp/`.

```bash
xcodebuild -project HTMLEditorDemoApp/HTMLEditor-Demo.xcodeproj \
  -scheme HTMLEditor-Demo \
  -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO
```

## Development

Build the package:

```bash
swift build
```

Run tests:

```bash
swift test
```

## License

MIT. See [LICENSE](LICENSE).
