import Testing
import AppKit
import SwiftUI
@testable import HTMLEditor

@MainActor
@Test func testSmallDocumentEditImmediatelyRehighlightsDirtyRange() throws {
    _ = NSApplication.shared

    let theme = makeTestTheme()
    let oldHTML = "<div clas"
    let insertedText = "s"
    let newHTML = oldHTML + insertedText
    let insertedLocation = oldHTML.utf16.count

    let editor = HTMLEditor(
        html: .constant(newHTML),
        theme: HTMLEditorTheme(light: theme, dark: theme)
    )
    let coordinator = HTMLEditor.Coordinator(editor)
    let textView = NSTextView()
    textView.string = newHTML

    let oldPlan = HTMLHighlightPlanBuilder.fullPlan(for: oldHTML)
    coordinator.visibleHighlightState.replace(with: oldPlan)
    if let layoutManager = textView.layoutManager {
        HTMLSyntaxHighlighter.applyTemporary(plan: oldPlan, to: layoutManager, theme: theme)
    }

    let editRange = NSRange(location: insertedLocation, length: 0)
    let dirtyRange = HTMLEditor.structuralDirtyRange(
        for: editRange,
        replacementLength: insertedText.utf16.count,
        in: newHTML as NSString,
        expansion: HTMLEditor.highlightBudget(forTextLength: newHTML.utf16.count).visibleExpansion
    )
    let edit = HTMLEditor.Coordinator.PendingEdit(
        affectedRange: editRange,
        replacementUTF16Length: insertedText.utf16.count
    )

    coordinator.preserveVisibleHighlightAfterEdit(
        textView: textView,
        edit: edit,
        newTextLength: newHTML.utf16.count,
        dirtyRange: dirtyRange
    )

    let colorBeforeImmediatePass = textView.layoutManager?.temporaryAttribute(
        .foregroundColor,
        atCharacterIndex: insertedLocation,
        effectiveRange: nil
    ) as? NSColor
    #expect(colorBeforeImmediatePass != theme.attributeName)

    coordinator.scheduleDirtyBlockHighlightAfterEdit(
        textView: textView,
        newTextLength: newHTML.utf16.count
    )

    let colorAfterImmediatePass = textView.layoutManager?.temporaryAttribute(
        .foregroundColor,
        atCharacterIndex: insertedLocation,
        effectiveRange: nil
    ) as? NSColor
    #expect(colorAfterImmediatePass == theme.attributeName)
}
