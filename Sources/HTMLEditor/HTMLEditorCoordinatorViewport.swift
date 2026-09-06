#if os(macOS)
import AppKit

extension HTMLEditor.Coordinator {
    @MainActor
    @objc func scrollViewDidScroll(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView,
              let scrollView = clipView.enclosingScrollView,
              let textView = scrollView.documentView as? NSTextView else { return }
        if HTMLEditor.shouldUseScrollIdleMode(
            forTextLength: HTMLEditorTextKitSurface.textStorage(for: textView)?.length ?? 0
        ) {
            scheduleScrollIdleHighlighting(textView: textView, scrollView: scrollView)
            return
        }
        scheduleVisibleRangeHighlighting(
            textView: textView,
            scrollView: scrollView,
            trigger: .scroll,
            detail: .full
        )
    }

    @MainActor
    func scheduleVisibleRangeHighlighting(
        textView: NSTextView,
        scrollView: NSScrollView,
        forceHighlight: Bool = false,
        allowPrewarm: Bool = true,
        trigger: HTMLEditorHighlightTrigger = .scroll,
        detail: HTMLEditorHighlightDetail = .full,
        overrideDelay: UInt64? = nil
    ) {
        visibleHighlightDebounceTask?.cancel()

        visibleHighlightDebounceTask = Task { @MainActor [weak self, weak textView, weak scrollView] in
            do {
                let delay = overrideDelay ?? HTMLEditor.semanticHighlightDelay(
                    forTextLength: textView.map { HTMLEditorTextKitSurface.textStorage(for: $0)?.length ?? 0 } ?? 0,
                    trigger: trigger
                )
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            // No documentVersion check here, unlike the other scheduled tasks:
            // this one reads the live text storage and viewport after waking, so
            // it works from current state by construction rather than from a
            // snapshot that could have gone stale.
            guard let self, let textView, let scrollView else { return }
            guard let surface = HTMLEditorTextKitSurface.resolve(for: textView),
                  let textStorage = HTMLEditorTextKitSurface.textStorage(for: textView),
                  let visibleRange = surface.visibleCharacterRange(
                      in: scrollView.documentVisibleRect,
                      textContainer: textView.textContainer
                  ) else { return }

            self.highlightVisibleRange(
                textView: textView,
                scrollView: scrollView,
                textStorage: textStorage,
                visibleRange: visibleRange,
                forceHighlight: forceHighlight,
                allowPrewarm: allowPrewarm,
                trigger: trigger,
                detail: detail
            )
        }
    }

    @MainActor
    func highlightVisibleRange(
        textView: NSTextView,
        scrollView: NSScrollView,
        textStorage: NSTextStorage,
        visibleRange: NSRange,
        forceHighlight: Bool = false,
        allowPrewarm: Bool = true,
        trigger: HTMLEditorHighlightTrigger,
        detail: HTMLEditorHighlightDetail
    ) {
        if textStorage.length == 0 {
            return
        }

        guard visibleRange.location != NSNotFound,
              visibleRange.location < textStorage.length,
              visibleRange.location + visibleRange.length <= textStorage.length else {
            return
        }

        if !forceHighlight &&
            abs(visibleRange.location - lastVisibleRange.location) < 100 &&
            abs(visibleRange.length - lastVisibleRange.length) < 100 {
            return
        }

        let scrollDirection = visibleRange.location - lastVisibleRange.location
        lastVisibleRange = visibleRange

        let surface = HTMLEditorTextKitSurface.resolve(for: textView)
        let textSnapshot = textStorage.string
        let textNSString = textSnapshot as NSString
        let needsHighlighting = rangeNeedsHighlighting(visibleRange, text: textNSString, forceHighlight: forceHighlight)

        if needsHighlighting {
            let budget = HTMLEditor.highlightBudget(forTextLength: textStorage.length)
            let expandedRange = expandedHighlightRange(
                for: visibleRange,
                textLength: textStorage.length,
                direction: scrollDirection,
                trigger: trigger,
                budget: budget
            )
            let currentTheme = parent.theme.current(for: NSApp.effectiveAppearance)
            let textLength = textStorage.length
            let currentVersion = documentVersion
            let preserveExistingOverlay = HTMLEditor.shouldPreserveVisibleHighlight(
                detail: detail,
                trigger: trigger,
                hasExistingOverlay: visibleHighlightState.hasOverlay
            )

            if let cachedPlan = cachedPlanCovering(expandedRange, version: currentVersion, textLength: textLength) {
                let displayPlan = HTMLSyntaxHighlighter.filteredPlan(cachedPlan, detail: detail)
                if !preserveExistingOverlay, let surface {
                    performVisibleRangeHighlighting(
                        plan: displayPlan,
                        theme: currentTheme,
                        surface: surface,
                        replacesVisibleOverlay: true
                    )
                    // Only claim coverage for text that was actually repainted;
                    // marking a deliberately-stale region clean would stop it
                    // ever being revisited.
                    recordHighlightedRange(cachedPlan.coveredRange, text: textSnapshot as NSString)
                }
                // Allow prewarm regardless of forceHighlight: an edit-triggered forced
                // re-highlight marks the prewarm zone dirty (see textDidChange), so
                // prewarm must run to re-apply correct highlights there.
                if allowPrewarm && budget.prewarmEnabled {
                    scheduleViewportPrewarm(
                        around: visibleRange,
                        direction: scrollDirection,
                        textSnapshot: textSnapshot,
                        theme: currentTheme,
                        version: currentVersion,
                        textLength: textLength,
                        textView: textView
                    )
                }
                return
            }

            let plan = planner.rangePlan(for: textSnapshot, requestedRange: expandedRange)
            storeCachedPlan(plan, version: currentVersion, textLength: textLength)
            let displayPlan = HTMLSyntaxHighlighter.filteredPlan(plan, detail: detail)
            if !preserveExistingOverlay, let surface {
                performVisibleRangeHighlighting(
                    plan: displayPlan,
                    theme: currentTheme,
                    surface: surface,
                    replacesVisibleOverlay: true
                )
                recordHighlightedRange(plan.coveredRange, text: textNSString)
            }
            // Allow prewarm regardless of forceHighlight (see comment above).
            if allowPrewarm && budget.prewarmEnabled {
                scheduleViewportPrewarm(
                    around: visibleRange,
                    direction: scrollDirection,
                    textSnapshot: textSnapshot,
                    theme: currentTheme,
                    version: currentVersion,
                    textLength: textLength,
                    textView: textView
                )
            }
        }
    }

    @MainActor
    func scheduleScrollIdleHighlighting(textView: NSTextView, scrollView: NSScrollView) {
        visibleHighlightDebounceTask?.cancel()
        prewarmTask?.cancel()
        scrollIdleTask?.cancel()

        let scheduledVersion = documentVersion
        let delay = HTMLEditor.semanticHighlightDelay(
            forTextLength: HTMLEditorTextKitSurface.textStorage(for: textView)?.length ?? 0,
            trigger: .scroll
        )

        scrollIdleTask = Task { @MainActor [weak self, weak textView, weak scrollView] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }

            guard let self, let textView, let scrollView, self.documentVersion == scheduledVersion else { return }
            self.scheduleVisibleRangeHighlighting(
                textView: textView,
                scrollView: scrollView,
                forceHighlight: true,
                allowPrewarm: true,
                trigger: .scroll,
                detail: .full,
                overrideDelay: 0
            )
        }
    }

    @MainActor
    func performVisibleRangeHighlighting(
        plan: HTMLSyntaxHighlighter.HighlightPlan,
        theme: HTMLEditorColorScheme,
        surface: HTMLEditorTextKitSurface,
        replacesVisibleOverlay: Bool,
        clearsDirtyRange: Bool = true,
        previousVisiblePlan: HTMLSyntaxHighlighter.HighlightPlan? = nil
    ) {
        isUpdatingFromHighlighting = true
        defer { isUpdatingFromHighlighting = false }

        guard replacesVisibleOverlay else {
            HTMLSyntaxHighlighter.apply(plan: plan, to: surface, theme: theme)
            return
        }

        HTMLSyntaxHighlighter.apply(
            plan: plan,
            replacing: previousVisiblePlan ?? visibleHighlightState.plan,
            to: surface,
            theme: theme
        )

        if clearsDirtyRange {
            visibleHighlightState.replace(with: plan)
        } else {
            visibleHighlightState.storeOverlayPlan(plan)
        }
    }

    /// Paints `plan` while recording `visiblePlan` as the state of the viewport.
    ///
    /// For a full pass those are the same value.  For a repaint around the caret
    /// they are not: the painted range is the few hundred units that actually
    /// changed, while the tracked plan still describes the whole viewport.
    /// Everything outside the painted range keeps the temporary attributes it
    /// already has — the layout manager shifts those across an edit — so
    /// repainting the viewport for a single character is redundant work, and it
    /// is not cheap: `addTemporaryAttributes` invalidates display, which is
    /// where most of the coordinator's main-thread time per keystroke went.
    @MainActor
    func applyHighlight(
        _ plan: HTMLSyntaxHighlighter.HighlightPlan,
        recordingVisiblePlan visiblePlan: HTMLSyntaxHighlighter.HighlightPlan,
        theme: HTMLEditorColorScheme,
        surface: HTMLEditorTextKitSurface
    ) {
        isUpdatingFromHighlighting = true
        defer { isUpdatingFromHighlighting = false }

        HTMLSyntaxHighlighter.apply(plan: plan, to: surface, theme: theme)
        visibleHighlightState.storeOverlayPlan(visiblePlan)
    }

    @MainActor
    func recordHighlightedRange(_ range: NSRange, text: NSString) {
        highlightCoverage.markHighlighted(HTMLEditor.alignedHighlightRange(range, in: text))
    }

    @MainActor
    func rangeNeedsHighlighting(_ range: NSRange, text: NSString, forceHighlight: Bool = false) -> Bool {
        let alignedRange = HTMLEditor.alignedHighlightRange(range, in: text)

        if let dirtyRange = visibleHighlightState.dirtyRange,
           NSIntersectionRange(alignedRange, dirtyRange).length > 0 {
            return true
        }

        return highlightCoverage.needsHighlighting(alignedRange, force: forceHighlight)
    }

    @MainActor
    func scheduleViewportPrewarm(
        around visibleRange: NSRange,
        direction: Int,
        textSnapshot: String,
        theme: HTMLEditorColorScheme,
        version: Int,
        textLength: Int,
        textView: NSTextView
    ) {
        let budget = HTMLEditor.highlightBudget(forTextLength: textLength)
        guard budget.prewarmEnabled else { return }

        prewarmTask?.cancel()

        let primaryForward = visibleRange.length * 2
        let secondaryBackward = max(visibleRange.length / 2, 1)
        let maxLength = textSnapshot.utf16.count
        let beforeRange = NSRange(
            location: max(0, visibleRange.location - primaryForward),
            length: min(primaryForward, visibleRange.location)
        )
        let afterStart = NSMaxRange(visibleRange)
        let afterRange = NSRange(
            location: min(afterStart, maxLength),
            length: min(primaryForward, max(0, maxLength - min(afterStart, maxLength)))
        )
        let nearbyBeforeRange = NSRange(
            location: max(0, visibleRange.location - secondaryBackward),
            length: min(secondaryBackward, visibleRange.location)
        )
        let nearbyAfterRange = NSRange(
            location: min(afterStart, maxLength),
            length: min(secondaryBackward, max(0, maxLength - min(afterStart, maxLength)))
        )

        let orderedCandidates = direction >= 0
            ? [afterRange, nearbyBeforeRange]
            : [beforeRange, nearbyAfterRange]
        let candidates = orderedCandidates.filter {
            $0.location != NSNotFound && $0.length > 0 && rangeNeedsHighlighting($0, text: textSnapshot as NSString)
        }
        guard !candidates.isEmpty else { return }

        prewarmTask = Task { [weak self, weak textView] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: budget.prewarmDelayNanoseconds)
            } catch {
                return
            }

            for candidate in candidates {
                guard !Task.isCancelled,
                      let textView,
                      let currentTextStorage = HTMLEditorTextKitSurface.textStorage(for: textView),
                      let surface = HTMLEditorTextKitSurface.resolve(for: textView),
                      self.documentVersion == version,
                      currentTextStorage.length == textLength else { return }

                let plan = self.planner.rangePlan(for: textSnapshot, requestedRange: candidate)
                let currentText = currentTextStorage.string as NSString
                guard self.rangeNeedsHighlighting(plan.coveredRange, text: currentText) else { continue }

                self.storeCachedPlan(plan, version: version, textLength: textLength)
                self.performVisibleRangeHighlighting(
                    plan: plan,
                    theme: theme,
                    surface: surface,
                    replacesVisibleOverlay: false
                )
                self.recordHighlightedRange(plan.coveredRange, text: currentText)
            }
        }
    }

    @MainActor
    func cachedPlanCovering(_ range: NSRange, version: Int, textLength: Int) -> HTMLSyntaxHighlighter.HighlightPlan? {
        guard let index = cachedRangePlans.firstIndex(where: {
            $0.version == version &&
            $0.textLength == textLength &&
            NSIntersectionRange(range, $0.range).length > Int(Double(range.length) * 0.8)
        }) else {
            return nil
        }

        let hit = cachedRangePlans.remove(at: index)
        cachedRangePlans.append(hit)
        return hit.plan
    }

    @MainActor
    func storeCachedPlan(_ plan: HTMLSyntaxHighlighter.HighlightPlan, version: Int, textLength: Int) {
        guard plan.coveredRange.location != NSNotFound, plan.coveredRange.length > 0 else { return }

        cachedRangePlans.removeAll {
            $0.version == version &&
            $0.textLength == textLength &&
            NSIntersectionRange($0.range, plan.coveredRange).length > 0
        }

        cachedRangePlans.append(
            CachedRangePlan(
                range: plan.coveredRange,
                version: version,
                textLength: textLength,
                plan: plan
            )
        )

        let limit = HTMLEditor.highlightBudget(forTextLength: textLength).cachedRangePlanLimit
        if cachedRangePlans.count > limit {
            cachedRangePlans.removeFirst(cachedRangePlans.count - limit)
        }
    }

    @MainActor
    func invalidateCaches(for edit: PendingEdit, newTextLength: Int) {
        let invalidationStart = max(0, edit.affectedRange.location - HTMLEditorDocumentSize.editInvalidationRadius)

        cachedRangePlans.removeAll { cachedPlan in
            NSMaxRange(cachedPlan.range) > invalidationStart
        }

        if lastVisibleRange.location >= invalidationStart || NSMaxRange(lastVisibleRange) > invalidationStart {
            lastVisibleRange = NSRange(location: 0, length: 0)
        }

        if newTextLength <= invalidationStart {
            cachedRangePlans.removeAll()
            highlightCoverage.clear()
            lastVisibleRange = NSRange(location: 0, length: 0)
        }
    }

    @MainActor
    func preserveVisibleHighlightAfterEdit(
        textView: NSTextView,
        edit: PendingEdit,
        newTextLength: Int,
        dirtyRange: NSRange
    ) {
        let previousVisiblePlan = visibleHighlightState.plan
        guard let preservedPlan = visibleHighlightState.remapAfterEdit(
                  editRange: edit.affectedRange,
                  replacementUTF16Length: edit.replacementUTF16Length,
                  newTextLength: newTextLength,
                  dirtyRange: dirtyRange
              ) else {
            return
        }

        // Deliberately no repaint here.  refreshImmediateEditHighlightAfterEdit
        // runs in this same runloop turn and applies a plan merged from exactly
        // this remapped plan, over the same region, so painting twice only
        // doubled the temporary-attribute work.  That is cheap in isolation but
        // not once the view is in a window: measured on a 13 MB document, the
        // second apply cost ~1.9 ms of the ~4.6 ms textDidChange spends on the
        // main thread per keystroke.  Nothing is drawn between the two calls, so
        // dropping this one is invisible.
        //
        // The stale-prewarm hazard that makes this region delicate does not
        // apply: prewarm is disabled above the conservative threshold, and below
        // it the immediate pass covers the same range either way.
        _ = (preservedPlan, previousVisiblePlan)
    }

    /// Paints whatever plan is currently tracked as visible.  Used as the
    /// fallback when the immediate local pass has no range to work with, so the
    /// remapped plan still reaches the screen.
    @MainActor
    func repaintVisiblePlan(textView: NSTextView) {
        guard let plan = visibleHighlightState.plan,
              let surface = HTMLEditorTextKitSurface.resolve(for: textView) else { return }

        performVisibleRangeHighlighting(
            plan: plan,
            theme: parent.theme.current(for: NSApp.effectiveAppearance),
            surface: surface,
            replacesVisibleOverlay: true,
            clearsDirtyRange: false
        )
    }

    @MainActor
    func scheduleFullDetailRecovery(textView: NSTextView, scrollView: NSScrollView) {
        detailRecoveryTask?.cancel()
        let recoveryVersion = documentVersion

        detailRecoveryTask = Task { @MainActor [weak self, weak textView, weak scrollView] in
            do {
                try await Task.sleep(
                    nanoseconds: HTMLEditor.semanticHighlightDelay(
                        forTextLength: textView.map { HTMLEditorTextKitSurface.textStorage(for: $0)?.length ?? 0 } ?? 0,
                        trigger: .recovery
                    )
                )
            } catch {
                return
            }

            guard let self, let textView, let scrollView, self.documentVersion == recoveryVersion else { return }
            self.scheduleVisibleRangeHighlighting(
                textView: textView,
                scrollView: scrollView,
                forceHighlight: true,
                allowPrewarm: false,
                trigger: .recovery,
                detail: .full
            )
        }
    }

    @MainActor
    func expandedHighlightRange(
        for visibleRange: NSRange,
        textLength: Int,
        direction: Int,
        trigger: HTMLEditorHighlightTrigger,
        budget: HTMLEditorHighlightBudget
    ) -> NSRange {
        let baseExpansion = max(budget.visibleExpansion, max(visibleRange.length, 1))
        let backwardExpansion: Int
        let forwardExpansion: Int

        switch trigger {
        case .scroll:
            if direction >= 0 {
                backwardExpansion = max(budget.visibleExpansion, visibleRange.length / 2)
                forwardExpansion = max(baseExpansion, visibleRange.length * 2)
            } else {
                backwardExpansion = max(baseExpansion, visibleRange.length * 2)
                forwardExpansion = max(budget.visibleExpansion, visibleRange.length / 2)
            }
        case .edit:
            backwardExpansion = baseExpansion
            forwardExpansion = baseExpansion
        case .recovery:
            backwardExpansion = max(baseExpansion, visibleRange.length * 2)
            forwardExpansion = max(baseExpansion, visibleRange.length * 2)
        }

        let expandedStart = max(0, visibleRange.location - backwardExpansion)
        let expandedEnd = min(textLength, NSMaxRange(visibleRange) + forwardExpansion)
        return NSRange(location: expandedStart, length: max(0, expandedEnd - expandedStart))
    }
}
#endif
