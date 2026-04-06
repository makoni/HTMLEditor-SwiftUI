#if os(macOS)
import AppKit

extension HTMLEditor.Coordinator {
    @MainActor
    @objc func scrollViewDidScroll(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView,
              let scrollView = clipView.enclosingScrollView,
              let textView = scrollView.documentView as? NSTextView else { return }
        scheduleVisibleRangeHighlighting(textView: textView, scrollView: scrollView)
    }

    @MainActor
    func scheduleVisibleRangeHighlighting(
        textView: NSTextView,
        scrollView: NSScrollView,
        forceHighlight: Bool = false,
        allowPrewarm: Bool = true
    ) {
        visibleHighlightDebounceTask?.cancel()

        visibleHighlightDebounceTask = Task { @MainActor [weak self, weak textView, weak scrollView] in
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
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
                allowPrewarm: allowPrewarm
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
        allowPrewarm: Bool = true
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

        lastVisibleRange = visibleRange

        let needsHighlighting = rangeNeedsHighlighting(visibleRange, forceHighlight: forceHighlight)

        if needsHighlighting {
            let budget = HTMLEditor.highlightBudget(forTextLength: textStorage.length)
            let expandedStart = max(0, visibleRange.location - budget.visibleExpansion)
            let expandedEnd = min(textStorage.length, visibleRange.location + visibleRange.length + budget.visibleExpansion)
            let expandedRange = NSRange(location: expandedStart, length: expandedEnd - expandedStart)
            let currentTheme = parent.theme.current(for: NSApp.effectiveAppearance)
            let textSnapshot = textStorage.string
            let textLength = textStorage.length
            let currentVersion = documentVersion

            if let cachedPlan = cachedPlanCovering(expandedRange, version: currentVersion, textLength: textLength) {
                performVisibleRangeHighlighting(plan: cachedPlan, theme: currentTheme, textStorage: textStorage)
                recordHighlightedRange(cachedPlan.coveredRange)
                if allowPrewarm && budget.prewarmEnabled && !forceHighlight {
                    scheduleViewportPrewarm(
                        around: visibleRange,
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
                          currentTextStorage.string == textSnapshot else { return }
                    self.storeCachedPlan(plan, version: currentVersion, textLength: textLength)
                    self.performVisibleRangeHighlighting(plan: plan, theme: currentTheme, textStorage: currentTextStorage)
                    self.recordHighlightedRange(plan.coveredRange)
                    if allowPrewarm && budget.prewarmEnabled && !forceHighlight {
                        self.scheduleViewportPrewarm(
                            around: visibleRange,
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
    func performVisibleRangeHighlighting(plan: HTMLSyntaxHighlighter.HighlightPlan, theme: HTMLEditorColorScheme, textStorage: NSTextStorage) {
        isUpdatingFromHighlighting = true

        if let layoutManager = textStorage.layoutManagers.first {
            HTMLSyntaxHighlighter.applyTemporary(plan: plan, to: layoutManager, theme: theme)
        } else {
            textStorage.beginEditing()
            HTMLSyntaxHighlighter.apply(plan: plan, to: textStorage, theme: theme)
            textStorage.endEditing()
        }

        isUpdatingFromHighlighting = false
    }

    @MainActor
    func recordHighlightedRange(_ range: NSRange) {
        guard range.location != NSNotFound, range.length > 0 else { return }

        var mergedRange = range
        var retainedRanges: [NSRange] = []
        retainedRanges.reserveCapacity(highlightedRanges.count + 1)

        for existingRange in highlightedRanges {
            if shouldMerge(existingRange, with: mergedRange) {
                mergedRange = union(of: existingRange, and: mergedRange)
            } else {
                retainedRanges.append(existingRange)
            }
        }

        retainedRanges.append(mergedRange)
        let limit = HTMLEditor.highlightBudget(forTextLength: parent.html.utf16.count).highlightedRangeLimit
        if retainedRanges.count > limit {
            retainedRanges.removeFirst(retainedRanges.count - limit)
        }

        highlightedRanges = retainedRanges
    }

    @MainActor
    func rangeNeedsHighlighting(_ range: NSRange, forceHighlight: Bool = false) -> Bool {
        forceHighlight || !highlightedRanges.contains { highlightedRange in
            NSIntersectionRange(range, highlightedRange).length > Int(Double(range.length) * 0.8)
        }
    }

    @MainActor
    func scheduleViewportPrewarm(
        around visibleRange: NSRange,
        textSnapshot: String,
        theme: HTMLEditorColorScheme,
        version: Int,
        textLength: Int,
        textView: NSTextView
    ) {
        let budget = HTMLEditor.highlightBudget(forTextLength: textLength)
        guard budget.prewarmEnabled else { return }

        prewarmTask?.cancel()

        let beforeRange = NSRange(location: max(0, visibleRange.location - visibleRange.length), length: visibleRange.length)
        let afterStart = NSMaxRange(visibleRange)
        let maxLength = textSnapshot.utf16.count
        let afterRange = NSRange(
            location: min(afterStart, maxLength),
            length: min(visibleRange.length, max(0, maxLength - min(afterStart, maxLength)))
        )

        let candidates = [beforeRange, afterRange].filter {
            $0.location != NSNotFound && $0.length > 0 && rangeNeedsHighlighting($0)
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
                          currentTextStorage.string == textSnapshot,
                          self.rangeNeedsHighlighting(plan.coveredRange) else { return }
                    self.storeCachedPlan(plan, version: version, textLength: textLength)
                    self.performVisibleRangeHighlighting(plan: plan, theme: theme, textStorage: currentTextStorage)
                    self.recordHighlightedRange(plan.coveredRange)
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

        highlightedRanges.removeAll { highlightedRange in
            NSMaxRange(highlightedRange) > invalidationStart
        }

        if lastVisibleRange.location >= invalidationStart || NSMaxRange(lastVisibleRange) > invalidationStart {
            lastVisibleRange = NSRange(location: 0, length: 0)
        }

        if newTextLength <= invalidationStart {
            cachedRangePlans.removeAll()
            highlightedRanges.removeAll()
            lastVisibleRange = NSRange(location: 0, length: 0)
        }
    }

    @MainActor
    func shouldMerge(_ lhs: NSRange, with rhs: NSRange) -> Bool {
        if NSIntersectionRange(lhs, rhs).length > 0 {
            return true
        }

        let lhsEnd = NSMaxRange(lhs)
        let rhsEnd = NSMaxRange(rhs)
        return abs(lhsEnd - rhs.location) <= 1 || abs(rhsEnd - lhs.location) <= 1
    }

    @MainActor
    func union(of lhs: NSRange, and rhs: NSRange) -> NSRange {
        let start = min(lhs.location, rhs.location)
        let end = max(NSMaxRange(lhs), NSMaxRange(rhs))
        return NSRange(location: start, length: end - start)
    }
}
#endif
