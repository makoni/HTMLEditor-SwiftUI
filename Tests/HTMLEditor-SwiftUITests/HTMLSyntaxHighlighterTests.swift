import Testing
import AppKit
@testable import HTMLEditor

@Test func testHTMLSyntaxHighlighting() async throws {
    let html = "<div class=\"test\">Hello <strong>World</strong></div>"
    let result = HTMLSyntaxHighlighter.highlight(html: html, theme: makeTestTheme())

    #expect(result.length == html.count)
    #expect(result.string == html)
}

@Test func testEmptyHTML() async throws {
    let html = ""
    let result = HTMLSyntaxHighlighter.highlight(html: html, theme: makeTestTheme())

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
    let result = HTMLSyntaxHighlighter.highlight(html: html, theme: makeTestTheme())

    #expect(result.length == html.count)
    #expect(result.string == html)
}

@Test func testEmptyTextIncrementalHighlighting() async throws {
    let textStorage = NSTextStorage(string: "")
    var expandedRange = NSRange(location: 0, length: 0)

    HTMLSyntaxHighlighter.highlightRange(
        in: textStorage,
        range: NSRange(location: 0, length: 0),
        theme: makeTestTheme(),
        expandedRange: &expandedRange
    )

    #expect(expandedRange.location == 0)
    #expect(expandedRange.length == 0)
}

@Test func testInvalidRangeHandling() async throws {
    let textStorage = NSTextStorage(string: "<div>Test</div>")
    var expandedRange = NSRange(location: 0, length: 0)

    HTMLSyntaxHighlighter.highlightRange(
        in: textStorage,
        range: NSRange(location: NSNotFound, length: 0),
        theme: makeTestTheme(),
        expandedRange: &expandedRange
    )

    #expect(expandedRange.location == 0)
    #expect(expandedRange.length == 0)
}

@Test func testUTF16RangeHandling() async throws {
    let html = #"<div title="emoji 😀">Привет 😀</div>"#
    let textStorage = NSTextStorage(string: html)
    var expandedRange = NSRange(location: 0, length: 0)

    let utf16Location = (html as NSString).range(of: "😀").location
    HTMLSyntaxHighlighter.highlightRange(
        in: textStorage,
        range: NSRange(location: utf16Location, length: 2),
        theme: makeTestTheme(),
        expandedRange: &expandedRange
    )

    #expect(expandedRange.location != NSNotFound)
    #expect(NSMaxRange(expandedRange) <= textStorage.length)
}

@Test func testPartialAnchorTagDoesNotBreakHighlighting() async throws {
    let html = "<div>prefix <a href suffix</div>"
    let result = HTMLSyntaxHighlighter.highlight(html: html, theme: makeTestTheme())

    #expect(result.string == html)

    let textStorage = NSTextStorage(string: html)
    var expandedRange = NSRange(location: 0, length: 0)
    let location = (html as NSString).range(of: "<a href").location
    HTMLSyntaxHighlighter.highlightRange(
        in: textStorage,
        range: NSRange(location: location, length: 7),
        theme: makeTestTheme(),
        expandedRange: &expandedRange
    )

    #expect(expandedRange.location != NSNotFound)
    #expect(NSMaxRange(expandedRange) <= textStorage.length)
}

@Test func testUnquotedAttributeValueHighlighting() async throws {
    let theme = makeTestTheme()
    let html = "<a href=https://example.com target=_blank>link</a>"
    let result = HTMLSyntaxHighlighter.highlight(html: html, theme: theme)

    #expect(result.string == html)

    let hrefRange = (html as NSString).range(of: "href")
    let valueRange = (html as NSString).range(of: "https://example.com")

    let hrefColor = result.attribute(.foregroundColor, at: hrefRange.location, effectiveRange: nil) as? NSColor
    let valueColor = result.attribute(.foregroundColor, at: valueRange.location, effectiveRange: nil) as? NSColor

    #expect(hrefColor == theme.attributeName)
    #expect(valueColor == theme.attributeValue)
}

@Test func testLargeDocumentMidEditRangeHighlighting() async throws {
    let repeated = String(repeating: "<p>section</p>\n", count: 2000)
    let insertion = "<a href"
    let largeHTML = repeated + insertion + repeated

    let textStorage = NSTextStorage(string: largeHTML)
    var expandedRange = NSRange(location: 0, length: 0)
    let insertionRange = (largeHTML as NSString).range(of: insertion)

    HTMLSyntaxHighlighter.highlightRange(
        in: textStorage,
        range: insertionRange,
        theme: makeTestTheme(),
        expandedRange: &expandedRange
    )

    #expect(expandedRange.location != NSNotFound)
    #expect(NSMaxRange(expandedRange) <= textStorage.length)
    #expect(expandedRange.length <= 2000)
}

@Test func testLargeContentHandling() async throws {
    let largeHTML = String(repeating: "<div class=\"test\">Content</div>\n", count: 1000)
    let result = HTMLSyntaxHighlighter.highlight(html: largeHTML, theme: makeTestTheme())

    #expect(result.length == largeHTML.count)
    #expect(result.string == largeHTML)
}

@Test func testQuotedAttributeValueAcrossChunkBoundary() async throws {
    let theme = makeTestTheme()
    let padding = String(repeating: "x", count: 505)
    let html = "<div data-value=\"\(padding)tail\">body</div>"
    let result = HTMLSyntaxHighlighter.highlight(html: html, theme: theme)

    let leadingValueRange = (html as NSString).range(of: "\"\(String(repeating: "x", count: 20))")
    let trailingValueRange = (html as NSString).range(of: "tail\"")

    let leadingValueColor = result.attribute(.foregroundColor, at: leadingValueRange.location, effectiveRange: nil) as? NSColor
    let trailingValueColor = result.attribute(.foregroundColor, at: trailingValueRange.location, effectiveRange: nil) as? NSColor

    #expect(leadingValueColor == theme.attributeValue)
    #expect(trailingValueColor == theme.attributeValue)
    #expect(result.string == html)
}

@Test func testSimpleTagHighlighting() async throws {
    let html = "<b>bold text</b>"
    let theme = makeTestTheme()
    let result = HTMLSyntaxHighlighter.highlight(html: html, theme: theme)

    #expect(result.length == html.count)
    #expect(result.string == html)

    let fullRange = NSRange(location: 0, length: result.length)
    var hasTagHighlighting = false

    result.enumerateAttribute(.foregroundColor, in: fullRange) { value, _, _ in
        if let color = value as? NSColor, color == theme.tag {
            hasTagHighlighting = true
        }
    }

    #expect(hasTagHighlighting == true)
}
