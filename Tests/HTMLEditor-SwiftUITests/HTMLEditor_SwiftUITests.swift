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

@Test func testUTF16RangeHandling() async throws {
    let theme = HTMLEditorColorScheme(
        foreground: .black,
        background: .white,
        tag: .red,
        attributeName: .blue,
        attributeValue: .green,
        font: .systemFont(ofSize: 14)
    )

    let html = #"<div title="emoji 😀">Привет 😀</div>"#
    let textStorage = NSTextStorage(string: html)
    var expandedRange = NSRange(location: 0, length: 0)

    let utf16Location = (html as NSString).range(of: "😀").location
    HTMLSyntaxHighlighter.highlightRange(
        in: textStorage,
        range: NSRange(location: utf16Location, length: 2),
        theme: theme,
        expandedRange: &expandedRange
    )

    #expect(expandedRange.location != NSNotFound)
    #expect(NSMaxRange(expandedRange) <= textStorage.length)
}

@Test func testPartialAnchorTagDoesNotBreakHighlighting() async throws {
    let theme = HTMLEditorColorScheme(
        foreground: .black,
        background: .white,
        tag: .red,
        attributeName: .blue,
        attributeValue: .green,
        font: .systemFont(ofSize: 14)
    )

    let html = "<div>prefix <a href suffix</div>"
    let result = HTMLSyntaxHighlighter.highlight(html: html, theme: theme)

    #expect(result.string == html)

    let textStorage = NSTextStorage(string: html)
    var expandedRange = NSRange(location: 0, length: 0)
    let location = (html as NSString).range(of: "<a href").location
    HTMLSyntaxHighlighter.highlightRange(
        in: textStorage,
        range: NSRange(location: location, length: 7),
        theme: theme,
        expandedRange: &expandedRange
    )

    #expect(expandedRange.location != NSNotFound)
    #expect(NSMaxRange(expandedRange) <= textStorage.length)
}

@Test func testUnquotedAttributeValueHighlighting() async throws {
    let theme = HTMLEditorColorScheme(
        foreground: .black,
        background: .white,
        tag: .red,
        attributeName: .blue,
        attributeValue: .green,
        font: .systemFont(ofSize: 14)
    )

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
    let theme = HTMLEditorColorScheme(
        foreground: .black,
        background: .white,
        tag: .red,
        attributeName: .blue,
        attributeValue: .green,
        font: .systemFont(ofSize: 14)
    )

    let repeated = String(repeating: "<p>section</p>\n", count: 2000)
    let insertion = "<a href"
    let largeHTML = repeated + insertion + repeated

    let textStorage = NSTextStorage(string: largeHTML)
    var expandedRange = NSRange(location: 0, length: 0)
    let insertionRange = (largeHTML as NSString).range(of: insertion)

    HTMLSyntaxHighlighter.highlightRange(
        in: textStorage,
        range: insertionRange,
        theme: theme,
        expandedRange: &expandedRange
    )

    #expect(expandedRange.location != NSNotFound)
    #expect(NSMaxRange(expandedRange) <= textStorage.length)
    #expect(expandedRange.length <= 2000)
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

@Test func testQuotedAttributeValueAcrossChunkBoundary() async throws {
    let theme = HTMLEditorColorScheme(
        foreground: .black,
        background: .white,
        tag: .red,
        attributeName: .blue,
        attributeValue: .green,
        font: .systemFont(ofSize: 14)
    )

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

@Test func testPlannerCacheSupportsDocumentScopedInvalidation() async throws {
    let documentA = UUID()
    let documentB = UUID()
    let html = "<div class=\"alpha\" data-id=\"123\">content</div>"
    let targetRange = (html as NSString).range(of: "class=\"alpha\"")

    let planA1 = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: documentA,
        text: html,
        requestedRange: targetRange
    )
    let planB1 = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: documentB,
        text: html,
        requestedRange: targetRange
    )

    await HTMLSyntaxHighlighter.invalidatePlannerCache(
        documentID: documentA,
        editRange: targetRange,
        replacementUTF16Length: targetRange.length + 4,
        newTextLength: html.utf16.count + 4
    )

    let planA2 = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: documentA,
        text: html,
        requestedRange: targetRange
    )
    let planB2 = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: documentB,
        text: html,
        requestedRange: targetRange
    )

    #expect(planA1.coveredRange == planA2.coveredRange)
    #expect(planB1.coveredRange == planB2.coveredRange)
    #expect(planA1.spans.map(\.range) == planA2.spans.map(\.range))
    #expect(planB1.spans.map(\.range) == planB2.spans.map(\.range))
}

@Test func testPlannerSameLengthEditPreservesDownstreamChunkCache() async throws {
    let documentID = UUID()
    let repeated = String(repeating: "<div class=\"item\" data-id=\"123\">value</div>\n", count: 200)
    let targetRange = NSRange(location: 3_600, length: 1_400)
    let editRange = NSRange(location: 3_620, length: 5)

    _ = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: documentID,
        text: repeated,
        requestedRange: targetRange
    )

    let beforeCounts = await HTMLSyntaxHighlighter.debugPlannerCacheCounts(documentID: documentID)
    await HTMLSyntaxHighlighter.invalidatePlannerCache(
        documentID: documentID,
        editRange: editRange,
        replacementUTF16Length: editRange.length,
        newTextLength: repeated.utf16.count
    )
    let afterInvalidationCounts = await HTMLSyntaxHighlighter.debugPlannerCacheCounts(documentID: documentID)

    #expect(beforeCounts.chunks > 0)
    #expect(afterInvalidationCounts.chunks > 0)
    #expect(afterInvalidationCounts.chunks <= beforeCounts.chunks)
    #expect(afterInvalidationCounts.chunks < beforeCounts.chunks || afterInvalidationCounts.plans == 0)
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
