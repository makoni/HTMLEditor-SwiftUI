#if os(macOS)
import AppKit

extension HTMLEditor.Coordinator {
    @MainActor
    func refreshDirtyBlockHighlightAfterEdit(
        textView: NSTextView,
        newTextLength: Int
    ) {
        guard HTMLEditor.shouldUseTwoPhaseEditing(forTextLength: newTextLength),
              let textStorage = textView.textStorage,
              let dirtyRange = visibleHighlightState.dirtyRange,
              dirtyRange.length > 0 else {
            return
        }

        let localRange = HTMLEditor.localDirtyHighlightRange(
            around: dirtyRange,
            textLength: newTextLength,
            maxLength: HTMLEditor.localDirtyHighlightLimit(forTextLength: newTextLength)
        )
        guard localRange.length > 0 else { return }

        let localPlan = HTMLHighlightPlanBuilder.rangePlan(
            for: textStorage.string,
            requestedRange: localRange
        )
        let clippedLocalPlan = HTMLSyntaxHighlighter.clippedPlan(localPlan, to: localRange)
        let previousVisiblePlan = visibleHighlightState.plan
        let mergedPlan = previousVisiblePlan.map {
            HTMLSyntaxHighlighter.mergedPlan(base: $0, overlay: clippedLocalPlan)
        } ?? clippedLocalPlan

        performVisibleRangeHighlighting(
            plan: mergedPlan,
            theme: parent.theme.current(for: NSApp.effectiveAppearance),
            textStorage: textStorage,
            replacesVisibleOverlay: true,
            clearsDirtyRange: false,
            previousVisiblePlan: previousVisiblePlan
        )
    }
}
#endif
