import Testing
import Foundation
@testable import HTMLEditor

@Test func testVisibleHighlightRemapShiftsTrailingSpansAfterInsertion() async throws {
    let html = "<div><span class=\"value\">text</span></div>"
    let originalPlan = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: UUID(),
        text: html,
        requestedRange: NSRange(location: 0, length: html.utf16.count)
    )
    let insertionLocation = (html as NSString).range(of: "<span").location
    let replacement = " data-id=\"123\""
    let updatedHTML = (html as NSString).replacingCharacters(
        in: NSRange(location: insertionLocation + 5, length: 0),
        with: replacement
    )
    let dirtyRange = HTMLEditorVisibleHighlightState.dirtyRange(
        for: NSRange(location: insertionLocation + 5, length: 0),
        replacementLength: replacement.utf16.count,
        newTextLength: updatedHTML.utf16.count,
        expansion: 8
    )

    let remappedPlan = try #require(
        HTMLEditorVisibleHighlightState.remapPlan(
            originalPlan,
            editRange: NSRange(location: insertionLocation + 5, length: 0),
            replacementLength: replacement.utf16.count,
            newTextLength: updatedHTML.utf16.count,
            dirtyRange: dirtyRange
        )
    )

    let closingTagLocation = (updatedHTML as NSString).range(of: "</span>").location
    #expect(remappedPlan.spans.contains {
        $0.role == .tag && $0.range.location == closingTagLocation
    })
}

@Test func testVisibleHighlightRemapDropsDirtySpansButKeepsOutsideHighlight() async throws {
    let html = "<div class=\"one\"><span id=\"two\">text</span></div>"
    let originalPlan = await HTMLSyntaxHighlighter.plannedRangeHighlight(
        documentID: UUID(),
        text: html,
        requestedRange: NSRange(location: 0, length: html.utf16.count)
    )
    let classRange = (html as NSString).range(of: "class")
    let replacement = "data-class"
    let updatedHTML = (html as NSString).replacingCharacters(in: classRange, with: replacement)
    let dirtyRange = HTMLEditorVisibleHighlightState.dirtyRange(
        for: classRange,
        replacementLength: replacement.utf16.count,
        newTextLength: updatedHTML.utf16.count,
        expansion: 2
    )

    let remappedPlan = try #require(
        HTMLEditorVisibleHighlightState.remapPlan(
            originalPlan,
            editRange: classRange,
            replacementLength: replacement.utf16.count,
            newTextLength: updatedHTML.utf16.count,
            dirtyRange: dirtyRange
        )
    )

    #expect(remappedPlan.spans.contains { $0.role == .tag })
    #expect(remappedPlan.spans.allSatisfy {
        NSIntersectionRange($0.range, dirtyRange).length == 0
    })
}

@Test func testVisibleHighlightStateTracksDirtyRangeAcrossEdits() async throws {
    var state = HTMLEditorVisibleHighlightState()
    state.replace(
        with: HTMLSyntaxHighlighter.HighlightPlan(
            coveredRange: NSRange(location: 100, length: 80),
            spans: [
                .init(range: NSRange(location: 100, length: 5), role: .tag),
                .init(range: NSRange(location: 150, length: 6), role: .tag)
            ]
        )
    )

    let remappedPlan = state.remapAfterEdit(
        editRange: NSRange(location: 120, length: 0),
        replacementUTF16Length: 4,
        newTextLength: 220,
        dirtyExpansion: 6
    )

    #expect(remappedPlan != nil)
    #expect(state.dirtyRange != nil)
    #expect(state.plan != nil)
    #expect(state.plan?.spans.contains { $0.range.location >= 154 } == true)
}
