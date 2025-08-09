import Testing
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
