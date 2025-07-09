# HTMLEditor-SwiftUI

HTMLEditor-SwiftUI is a Swift package designed for macOS (v13 and above) that provides a SwiftUI-based text editor with HTML syntax highlighting. It leverages the powerful [SwiftSoup](https://github.com/scinfu/SwiftSoup) library to parse HTML into an Abstract Syntax Tree (AST), enabling developers to work with HTML content programmatically.

## Features
- Built-in syntax highlighting for HTML content.
- Customizable themes and color schemes for the editor.
- Parsing HTML into an AST for highlighting.

## Package Dependency
This package depends on the [SwiftSoup](https://github.com/scinfu/SwiftSoup) library (version 2.6.0 or later).

## Adding HTMLEditor-SwiftUI to Your Project
To add HTMLEditor-SwiftUI to your Swift project, follow these steps:

1. Open your project in Xcode.
2. Go to `File > Add Packages...`.
3. Enter the following URL in the search bar:
   ```
   https://github.com/your-repo/HTMLEditor-SwiftUI.git
   ```
4. Select the version rule (e.g., "Up to Next Major Version") and click "Add Package".
5. Import the package in your Swift files where needed:
   ```swift
   import HTMLEditor
   ```

## Demo App
This repository includes a demo app located in the `HTMLEditorDemoApp/` directory. The demo app showcases the capabilities of the HTMLEditor-SwiftUI package, including syntax highlighting and theme customization. To try it out:

1. Open the `HTMLEditor-Demo.xcodeproj` file in Xcode.
2. Build and run the app on your macOS system.

## License
This project is licensed under the MIT License. See the LICENSE file for details.

## Contributions
Contributions are welcome! Feel free to open issues or submit pull requests to improve the package.

## Usage Example
Here is a simple example demonstrating the usage of `HTMLEditorView` in a SwiftUI view:

```swift
import SwiftUI
import HTMLEditor

struct ContentView: View {
    @State private var htmlContent: String = "<p>Hello, World!</p>"

    var body: some View {
        HTMLEditorView(html: $htmlContent)
    }
}
```
