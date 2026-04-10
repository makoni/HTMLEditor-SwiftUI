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

@MainActor
@Test func testApplyFullHighlightPlanKeepsPermanentTextStorageColorAtBaseTheme() async throws {
    let html = "<p>Hello</p>"
    let theme = makeTestTheme()
    let editor = HTMLEditor(
        html: .constant(html),
        theme: HTMLEditorTheme(light: theme, dark: theme)
    )
    let coordinator = HTMLEditor.Coordinator(editor)
    let scrollView = NSScrollView()
    let textView = NSTextView()
    scrollView.documentView = textView
    textView.string = html

    let plan = HTMLHighlightPlanBuilder.fullPlan(for: html)
    coordinator.applyFullHighlightPlan(plan, html: html, theme: theme, to: textView, in: scrollView)

    let tagRange = (html as NSString).range(of: "<p>")
    let plainTextRange = (html as NSString).range(of: "Hello")

    let permanentTagColor = textView.textStorage?.attribute(
        .foregroundColor,
        at: tagRange.location,
        effectiveRange: nil
    ) as? NSColor
    let permanentPlainTextColor = textView.textStorage?.attribute(
        .foregroundColor,
        at: plainTextRange.location,
        effectiveRange: nil
    ) as? NSColor
    let temporaryTagColor = textView.layoutManager?.temporaryAttribute(
        .foregroundColor,
        atCharacterIndex: tagRange.location,
        effectiveRange: nil
    ) as? NSColor

    #expect(permanentTagColor == theme.foreground)
    #expect(permanentPlainTextColor == theme.foreground)
    #expect(temporaryTagColor == theme.tag)
}

@Test func testMergedPlanReplacesOverlayRangeWithoutDroppingOutsideSpans() async throws {
    let basePlan = HTMLSyntaxHighlighter.HighlightPlan(
        coveredRange: NSRange(location: 0, length: 30),
        spans: [
            .init(range: NSRange(location: 0, length: 5), role: .tag),
            .init(range: NSRange(location: 20, length: 5), role: .tag)
        ]
    )
    let overlayPlan = HTMLSyntaxHighlighter.HighlightPlan(
        coveredRange: NSRange(location: 8, length: 10),
        spans: [
            .init(range: NSRange(location: 10, length: 4), role: .attributeName)
        ]
    )

    let merged = HTMLSyntaxHighlighter.mergedPlan(base: basePlan, overlay: overlayPlan)

    #expect(merged.spans.contains { $0.range == NSRange(location: 0, length: 5) })
    #expect(merged.spans.contains { $0.range == NSRange(location: 20, length: 5) })
    #expect(merged.spans.contains { $0.range == NSRange(location: 10, length: 4) })
}

/// Regression test for Bug 1: applyTemporary(plan:replacing:) must clear the
/// full overlap region, not just positions listed in previousPlan.spans.
///
/// A prewarm can paint temporary `attributeName` colour on characters that the
/// tracked visible plan never recorded as spans (e.g. plain-text runs).  When a
/// subsequent "replacing" apply arrives for the same region, those untracked
/// highlights must be erased even though previousPlan.spans is empty for that
/// position.
@MainActor
@Test func testApplyTemporaryReplacingClearsUntrackedPrewarmHighlights() {
    let html = "<ul>\nCreate, rename\n</ul>"
    let textStorage = NSTextStorage(string: html)
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(size: CGSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
    layoutManager.addTextContainer(textContainer)
    textStorage.addLayoutManager(layoutManager)
    let theme = makeTestTheme()

    // 1. Prewarm applies attributeName (blue) to "Create, rename" at position 5.
    //    This simulates a prewarm run that saw a preceding unclosed tag, making
    //    the plain-text run look like an attribute value.
    let stalePrewarmSpan = HTMLSyntaxHighlighter.HighlightSpan(
        range: NSRange(location: 5, length: 14),
        role: .attributeName
    )
    let prewarmPlan = HTMLSyntaxHighlighter.HighlightPlan(
        coveredRange: NSRange(location: 0, length: html.utf16.count),
        spans: [stalePrewarmSpan]
    )
    HTMLSyntaxHighlighter.applyTemporary(plan: prewarmPlan, to: layoutManager, theme: theme)

    var effectiveRange = NSRange(location: NSNotFound, length: 0)
    let colorAfterPrewarm = layoutManager.temporaryAttribute(
        .foregroundColor, atCharacterIndex: 5, effectiveRange: &effectiveRange
    ) as? NSColor
    #expect(colorAfterPrewarm == theme.attributeName, "Precondition: prewarm should have set attributeName")

    // 2. The user fixes the HTML. The new visible plan correctly treats position 5
    //    as plain foreground — there is NO span there.  The previous visible plan
    //    also had no span at position 5 (it was prewarm-applied, not tracked).
    let previousPlan = HTMLSyntaxHighlighter.HighlightPlan(
        coveredRange: NSRange(location: 0, length: html.utf16.count),
        spans: []   // no tracked span at position 5
    )
    let correctedPlan = HTMLSyntaxHighlighter.HighlightPlan(
        coveredRange: NSRange(location: 0, length: html.utf16.count),
        spans: []   // position 5 is plain text — no attributeName span
    )

    HTMLSyntaxHighlighter.applyTemporary(
        plan: correctedPlan,
        replacing: previousPlan,
        to: layoutManager,
        theme: theme
    )

    // 3. The stale prewarm attributeName colour must have been cleared by the
    //    full-overlap clear introduced by the Bug 1 fix.
    let colorAfterFix = layoutManager.temporaryAttribute(
        .foregroundColor, atCharacterIndex: 5, effectiveRange: nil
    ) as? NSColor
    #expect(
        colorAfterFix != theme.attributeName,
        "Stale prewarm attributeName highlight must be cleared by the replacing plan"
    )
}
