#if os(macOS)
import AppKit

extension HTMLEditor.Coordinator {
    @MainActor
    @objc func scrollViewDidScroll(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView,
              let scrollView = clipView.enclosingScrollView,
              let textView = scrollView.documentView as? NSTextView else { return }
        if HTMLEditor.shouldUseScrollIdleMode(forTextLength: textView.textStorage?.length ?? 0) {
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
                    forTextLength: textView?.textStorage?.length ?? 0,
                    trigger: trigger
                )
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self, let textView, let scrollView else { return }
            let visibleRect = scrollView.documentVisibleRect
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let textStorage = textView.textStorage else { return }

            let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            let visibleRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
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
                if !preserveExistingOverlay {
                    performVisibleRangeHighlighting(
                        plan: displayPlan,
                        theme: currentTheme,
                        textStorage: textStorage,
                        replacesVisibleOverlay: true
                    )
                }
                recordHighlightedRange(cachedPlan.coveredRange, text: textSnapshot as NSString)
                if allowPrewarm && budget.prewarmEnabled && !forceHighlight {
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

            visibleHighlightTask?.cancel()
            visibleHighlightTask = Task { [weak self, weak textView] in
                guard let self else { return }
                let plan = await HTMLSyntaxHighlighter.plannedRangeHighlight(
                    documentID: self.plannerDocumentID,
                    text: textSnapshot,
                    requestedRange: expandedRange
                )
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let textView,
                          let currentTextStorage = textView.textStorage,
                          self.documentVersion == currentVersion,
                          currentTextStorage.length == textLength else { return }
                    self.storeCachedPlan(plan, version: currentVersion, textLength: textLength)
                    let displayPlan = HTMLSyntaxHighlighter.filteredPlan(plan, detail: detail)
                    if !preserveExistingOverlay {
                        self.performVisibleRangeHighlighting(
                            plan: displayPlan,
                            theme: currentTheme,
                            textStorage: currentTextStorage,
                            replacesVisibleOverlay: true
                        )
                    }
                    self.recordHighlightedRange(plan.coveredRange, text: currentTextStorage.string as NSString)
                    if allowPrewarm && budget.prewarmEnabled && !forceHighlight {
                        self.scheduleViewportPrewarm(
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
        }
    }

    @MainActor
    func scheduleScrollIdleHighlighting(textView: NSTextView, scrollView: NSScrollView) {
        visibleHighlightDebounceTask?.cancel()
        visibleHighlightTask?.cancel()
        prewarmTask?.cancel()
        scrollIdleTask?.cancel()

        let scheduledVersion = documentVersion
        let delay = HTMLEditor.semanticHighlightDelay(
            forTextLength: textView.textStorage?.length ?? 0,
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
        textStorage: NSTextStorage,
        replacesVisibleOverlay: Bool,
        clearsDirtyRange: Bool = true,
        previousVisiblePlan: HTMLSyntaxHighlighter.HighlightPlan? = nil
    ) {
        isUpdatingFromHighlighting = true

        if let layoutManager = textStorage.layoutManagers.first {
            if replacesVisibleOverlay {
                HTMLSyntaxHighlighter.applyTemporary(
                    plan: plan,
                    replacing: previousVisiblePlan ?? visibleHighlightState.plan,
                    to: layoutManager,
                    theme: theme
                )
                if clearsDirtyRange {
                    visibleHighlightState.replace(with: plan)
                } else {
                    visibleHighlightState.storeOverlayPlan(plan)
                }
            } else {
                HTMLSyntaxHighlighter.applyTemporary(plan: plan, to: layoutManager, theme: theme)
            }
        } else {
            textStorage.beginEditing()
            HTMLSyntaxHighlighter.apply(plan: plan, to: textStorage, theme: theme)
            textStorage.endEditing()
            if replacesVisibleOverlay {
                if clearsDirtyRange {
                    visibleHighlightState.replace(with: plan)
                } else {
                    visibleHighlightState.storeOverlayPlan(plan)
                }
            }
        }

        isUpdatingFromHighlighting = false
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

        let primaryForward = max(visibleRange.length * 2, visibleRange.length)
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
                guard !Task.isCancelled else { return }
                let plan = await HTMLSyntaxHighlighter.plannedRangeHighlight(
                    documentID: self.plannerDocumentID,
                    text: textSnapshot,
                    requestedRange: candidate
                )
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let textView,
                          let currentTextStorage = textView.textStorage,
                          self.documentVersion == version,
                          currentTextStorage.length == textLength,
                          self.rangeNeedsHighlighting(plan.coveredRange, text: currentTextStorage.string as NSString) else { return }
                    self.storeCachedPlan(plan, version: version, textLength: textLength)
                    self.performVisibleRangeHighlighting(
                        plan: plan,
                        theme: theme,
                        textStorage: currentTextStorage,
                        replacesVisibleOverlay: false
                    )
                    self.recordHighlightedRange(plan.coveredRange, text: currentTextStorage.string as NSString)
                }
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
        let invalidationStart = max(0, edit.affectedRange.location - 256)

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
        guard let textStorage = textView.textStorage,
              let preservedPlan = visibleHighlightState.remapAfterEdit(
                  editRange: edit.affectedRange,
                  replacementUTF16Length: edit.replacementUTF16Length,
                  newTextLength: newTextLength,
                  dirtyRange: dirtyRange
              ) else {
            return
        }

        performVisibleRangeHighlighting(
            plan: preservedPlan,
            theme: parent.theme.current(for: NSApp.effectiveAppearance),
            textStorage: textStorage,
            replacesVisibleOverlay: true,
            clearsDirtyRange: false,
            previousVisiblePlan: previousVisiblePlan
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
                        forTextLength: textView?.textStorage?.length ?? 0,
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
