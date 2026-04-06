import Testing
import AppKit
@testable import HTMLEditor

func makeTestTheme() -> HTMLEditorColorScheme {
    HTMLEditorColorScheme(
        foreground: .black,
        background: .white,
        tag: .red,
        attributeName: .blue,
        attributeValue: .green,
        font: .systemFont(ofSize: 14)
    )
}
