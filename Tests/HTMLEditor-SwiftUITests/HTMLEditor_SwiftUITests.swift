import Testing
import AppKit
@testable import HTMLEditor

@Test func testHTMLSyntaxHighlighting() async throws {
    let html = "<div class=\"test\">Hello <strong>World</strong></div>"
    let theme = HTMLEditorColorScheme(
        foreground: .black,
        background: .white,
        tag: .red,
        attributeName: .blue,
        attributeValue: .green,
        font: .systemFont(ofSize: 14)
    )
    
    let result = HTMLSyntaxHighlighter.highlight(html: html, theme: theme)
    
    #expect(result.length == html.count)
    #expect(result.string == html)
}

@Test func testEmptyHTML() async throws {
    let html = ""
    let theme = HTMLEditorColorScheme(
        foreground: .black,
        background: .white,
        tag: .red,
        attributeName: .blue,
        attributeValue: .green,
        font: .systemFont(ofSize: 14)
    )
    
    let result = HTMLSyntaxHighlighter.highlight(html: html, theme: theme)
    
    #expect(result.length == 0)
    #expect(result.string == "")
}

@Test func testComplexHTML() async throws {
    let html = """
    <html>
    <head>
        <title id="main-title" class="header">Test Page</title>
    </head>
    <body>
        <p>This is a <em>test</em> paragraph.</p>
    </body>
    </html>
    """
    let theme = HTMLEditorColorScheme(
        foreground: .black,
        background: .white,
        tag: .red,
        attributeName: .blue,
        attributeValue: .green,
        font: .systemFont(ofSize: 14)
    )
    
    let result = HTMLSyntaxHighlighter.highlight(html: html, theme: theme)
    
    #expect(result.length == html.count)
    #expect(result.string == html)
}

@Test func testEmptyTextIncrementalHighlighting() async throws {
    let theme = HTMLEditorColorScheme(
        foreground: .black,
        background: .white,
        tag: .red,
        attributeName: .blue,
        attributeValue: .green,
        font: .systemFont(ofSize: 14)
    )
    
    // Test incremental highlighting with empty text storage
    let textStorage = NSTextStorage(string: "")
    var expandedRange = NSRange(location: 0, length: 0)
    
    // This should not crash
    HTMLSyntaxHighlighter.highlightRange(
        in: textStorage,
        range: NSRange(location: 0, length: 0),
        theme: theme,
        expandedRange: &expandedRange
    )
    
    #expect(expandedRange.location == 0)
    #expect(expandedRange.length == 0)
}

@Test func testInvalidRangeHandling() async throws {
    let theme = HTMLEditorColorScheme(
        foreground: .black,
        background: .white,
        tag: .red,
        attributeName: .blue,
        attributeValue: .green,
        font: .systemFont(ofSize: 14)
    )
    
    let textStorage = NSTextStorage(string: "<div>Test</div>")
    var expandedRange = NSRange(location: 0, length: 0)
    
    // Test with NSNotFound location (which caused the crash)
    HTMLSyntaxHighlighter.highlightRange(
        in: textStorage,
        range: NSRange(location: NSNotFound, length: 0),
        theme: theme,
        expandedRange: &expandedRange
    )
    
    // Should handle gracefully
    #expect(expandedRange.location == 0)
    #expect(expandedRange.length == 0)
}

@Test func testLargeContentHandling() async throws {
    // Test that large content doesn't crash the system
    let largeHTML = String(repeating: "<div class=\"test\">Content</div>\n", count: 1000)
    let theme = HTMLEditorColorScheme(
        foreground: .black,
        background: .white,
        tag: .red,
        attributeName: .blue,
        attributeValue: .green,
        font: .systemFont(ofSize: 14)
    )
    
    // This should handle large content gracefully
    let result = HTMLSyntaxHighlighter.highlight(html: largeHTML, theme: theme)
    
    #expect(result.length == largeHTML.count)
    #expect(result.string == largeHTML)
}

@Test func testSimpleTagHighlighting() async throws {
    // Test the specific case mentioned - typing <b>
    let html = "<b>bold text</b>"
    let theme = HTMLEditorColorScheme(
        foreground: .black,
        background: .white,
        tag: .red,
        attributeName: .blue,
        attributeValue: .green,
        font: .systemFont(ofSize: 14)
    )
    
    let result = HTMLSyntaxHighlighter.highlight(html: html, theme: theme)
    
    #expect(result.length == html.count)
    #expect(result.string == html)
    
    // Verify that opening and closing tags are highlighted
    // The result should contain color attributes for the tag ranges
    let fullRange = NSRange(location: 0, length: result.length)
    var hasTagHighlighting = false
    
    result.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
        if let color = value as? NSColor, color == theme.tag {
            hasTagHighlighting = true
        }
    }
    
    #expect(hasTagHighlighting == true)
}
