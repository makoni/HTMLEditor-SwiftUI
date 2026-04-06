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
- Adaptive highlighting pipeline:
  - full semantic highlighting for smaller HTML documents
  - viewport-first highlighting for large documents
  - performance-oriented large-file mode for very large HTML inputs
- Large-document optimizations including:
  - visible-range plan caching
  - document-scoped invalidation
  - structural dirty-range alignment
  - burst-coalesced edit repainting
  - scroll-idle semantic refresh
  - automatic non-contiguous layout in large-file mode
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
.package(url: "https://github.com/makoni/HTMLEditor-SwiftUI.git", from: "1.1.0")
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

The editor uses different runtime strategies depending on document size.

- **Smaller documents** use fuller semantic highlighting.
- **Large documents** switch to viewport-first highlighting and stronger cache reuse.
- **Very large documents** use a more conservative editing mode with localized repaint, delayed wider recovery, and scroll-idle semantic work to keep interaction responsive.

This means the editor is optimized for both short snippets and multi-megabyte HTML files, but the very-large-file mode intentionally prioritizes responsiveness over immediate full-detail recoloring.

## Benchmarks

The package includes an executable benchmark target:

```bash
swift run HTMLEditorBenchmarks
```

To benchmark a specific HTML file:

```bash
HTML_EDITOR_BENCHMARK_HTML=/path/to/file.html swift run HTMLEditorBenchmarks
```

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
