#if os(macOS)
import AppKit

extension HTMLEditor.Coordinator {
    @MainActor
    func scheduleDirtyBlockHighlightAfterEdit(
        textView: NSTextView,
        newTextLength: Int
    ) {
        editBurstTask?.cancel()

        refreshImmediateEditHighlightAfterEdit(
            textView: textView,
            newTextLength: newTextLength
        )

        guard let delay = HTMLEditor.editBurstCoalescingDelay(forTextLength: newTextLength) else {
            refreshDirtyBlockHighlightAfterEdit(textView: textView, newTextLength: newTextLength)
            return
        }

        let scheduledVersion = documentVersion
        editBurstTask = Task { @MainActor [weak self, weak textView] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }

            guard let self, let textView, self.documentVersion == scheduledVersion else { return }
            self.refreshDirtyBlockHighlightAfterEdit(textView: textView, newTextLength: newTextLength)
        }
    }

    @MainActor
    func refreshImmediateEditHighlightAfterEdit(
        textView: NSTextView,
        newTextLength: Int
    ) {
        guard let dirtyRange = visibleHighlightState.dirtyRange else {
            return
        }

        let immediateRange: NSRange
        if HTMLEditor.shouldUseTwoPhaseEditing(forTextLength: newTextLength) {
            immediateRange = HTMLEditor.localDirtyHighlightRange(
                around: dirtyRange,
                textLength: newTextLength,
                maxLength: HTMLEditor.immediateEditHighlightLimit(forTextLength: newTextLength)
            )
        } else {
            // Small documents keep full detail while typing, so re-highlight the
            // structural dirty range immediately instead of leaving a brief plain
            // text gap until the delayed visible-range pass catches up.
            immediateRange = dirtyRange
        }

        applyLocalDirtyHighlight(in: immediateRange, textView: textView)
    }

    @MainActor
    func refreshDirtyBlockHighlightAfterEdit(
        textView: NSTextView,
        newTextLength: Int
    ) {
        guard HTMLEditor.shouldUseTwoPhaseEditing(forTextLength: newTextLength),
              let dirtyRange = visibleHighlightState.dirtyRange else {
            return
        }

        let localRange = HTMLEditor.localDirtyHighlightRange(
            around: dirtyRange,
            textLength: newTextLength,
            maxLength: HTMLEditor.localDirtyHighlightLimit(forTextLength: newTextLength)
        )
        applyLocalDirtyHighlight(in: localRange, textView: textView)
    }

    @MainActor
    private func applyLocalDirtyHighlight(
        in localRange: NSRange,
        textView: NSTextView
    ) {
        guard localRange.length > 0,
              let textStorage = textView.textStorage else { return }

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
