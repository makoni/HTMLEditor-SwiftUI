#if os(macOS)
import AppKit
import QuartzCore

extension HTMLEditor.Coordinator {
    @MainActor
    func updateLayoutPolicy(textView: NSTextView, textLength: Int) {
        guard let layoutManager = textView.layoutManager else { return }
        let currentlyEnabled = layoutManager.allowsNonContiguousLayout
        let shouldEnable = HTMLEditor.shouldUseNonContiguousLayout(
            forTextLength: textLength,
            currentlyEnabled: currentlyEnabled
        )
        guard shouldEnable != currentlyEnabled else { return }
        layoutManager.allowsNonContiguousLayout = shouldEnable
    }

    @MainActor
    func scheduleExternalHighlightUpdate(html: String, theme: HTMLEditorColorScheme, textView: NSTextView) {
        bindingSyncTask?.cancel()
        detailRecoveryTask?.cancel()
        updateLayoutPolicy(textView: textView, textLength: html.utf16.count)
        previousText = html
        pendingLocalBindingSyncHTML = nil
        lastBindingWriteHTML = nil
        documentVersion &+= 1
        lastVisibleRange = NSRange(location: 0, length: 0)
        highlightCoverage.clear()
        cachedFullHighlightPlan = nil
        cachedFullHighlightVersion = nil
        cachedRangePlans.removeAll()
        visibleHighlightState.clear()
        visibleHighlightTask?.cancel()
        prewarmTask?.cancel()
        Task { [planner] in
            await planner.clear()
        }
        performFullHighlighting(html: html, theme: theme, textView: textView)
    }

    @MainActor
    func shouldApplyExternalUpdate(incomingHTML: String) -> Bool {
        // `previousText` is what the text view is showing, so an exact match has
        // nothing to apply.  Comparing the text itself matters: this was once a
        // four-sample fingerprint, which is fine as a cache key but not as
        // document equality — any same-length change that missed the sampled
        // offsets, such as a find-and-replace or an equal-length rename, read as
        // "no change" and was silently dropped.
        if incomingHTML == previousText {
            lastBindingWriteHTML = nil
            return false
        }

        // Our own write coming back after the text view has moved on.  For large
        // documents the binding is deliberately behind — bindingSyncDelay defers
        // the write — so a keystroke landing in that window is routine, not an
        // edge case.  Applying it would reset the document to an older state,
        // reflowing the whole text view and dropping the selection.
        //
        // Matching the written string rather than a "waiting for echo" flag is
        // what keeps this from also swallowing a parent that normalises in its
        // setter: a normalised value differs from what was sent, so it still
        // gets applied.
        if let lastBindingWriteHTML, incomingHTML == lastBindingWriteHTML {
            return false
        }

        lastBindingWriteHTML = nil
        return true
    }

    @MainActor
    func scheduleBindingSync(for html: String) {
        pendingLocalBindingSyncHTML = html
        bindingSyncTask?.cancel()

        guard let delay = HTMLEditor.bindingSyncDelay(forTextLength: html.utf16.count) else {
            pendingLocalBindingSyncHTML = nil
            lastBindingWriteHTML = html
            parent.html = html
            return
        }

        let scheduledVersion = documentVersion
        bindingSyncTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }

            guard let self,
                  self.documentVersion == scheduledVersion,
                  self.pendingLocalBindingSyncHTML != nil else { return }
            self.pendingLocalBindingSyncHTML = nil
            self.lastBindingWriteHTML = html
            self.parent.html = html
        }
    }

    @MainActor
    func flushPendingBindingSync() {
        bindingSyncTask?.cancel()
        bindingSyncTask = nil

        guard let pendingLocalBindingSyncHTML else { return }
        self.pendingLocalBindingSyncHTML = nil
        lastBindingWriteHTML = pendingLocalBindingSyncHTML
        parent.html = pendingLocalBindingSyncHTML
    }

    @MainActor
    func performFullHighlighting(html: String, theme: HTMLEditorColorScheme, textView: NSTextView) {
        guard let scrollView = textView.enclosingScrollView else { return }

        let currentVersion = documentVersion
        fullHighlightTask?.cancel()

        if html.utf16.count > HTMLSyntaxHighlighter.maxHighlightLength {
            cachedFullHighlightPlan = nil
            cachedFullHighlightVersion = nil
            applyPlainTextResult(html: html, to: textView, in: scrollView)
            // applyPlainTextResult strips every temporary attribute and resets
            // the coverage bookkeeping, so without this the document is left
            // plain.  Nothing else would come along to fix it: a light/dark
            // switch changes no bounds, so no scroll notification fires, and
            // updateNSView short-circuits because the html is unchanged.  Large
            // documents lost their colours on an appearance change and only got
            // them back once the user scrolled or typed.
            scheduleVisibleRangeHighlighting(
                textView: textView,
                scrollView: scrollView,
                forceHighlight: true,
                trigger: .scroll,
                detail: .full
            )
            return
        }

        fullHighlightTask = Task { [weak self, weak textView, weak scrollView] in
            guard let self else { return }
            let plan = await self.planner.fullPlan(for: html)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let textView,
                      let scrollView,
                      self.documentVersion == currentVersion else { return }
                self.cachedFullHighlightPlan = plan
                self.cachedFullHighlightVersion = currentVersion
                self.applyFullHighlightPlan(plan, html: html, theme: theme, to: textView, in: scrollView)
            }
        }
    }

    @MainActor
    func applyFullHighlightPlan(
        _ plan: HTMLSyntaxHighlighter.HighlightPlan?,
        html: String,
        theme: HTMLEditorColorScheme,
        to textView: NSTextView,
        in scrollView: NSScrollView
    ) {
        let selectedRange = textView.selectedRange()
        let visibleRect = scrollView.documentVisibleRect

        isUpdatingFromHighlighting = true

        if textView.string != html {
            textView.string = html
        }
        HTMLSyntaxHighlighter.applyThemeBase(to: textView, theme: theme)
        if let layoutManager = textView.layoutManager {
            let fullRange = NSRange(location: 0, length: textView.string.utf16.count)
            HTMLSyntaxHighlighter.clearTemporaryHighlights(in: layoutManager, range: fullRange)
            if let plan {
                let budget = HTMLEditor.highlightBudget(forTextLength: textView.string.utf16.count)
                let visibleWindow = visibleHighlightWindow(
                    for: textView,
                    scrollView: scrollView,
                    textLength: textView.string.utf16.count,
                    expansion: budget.fullPlanVisibleExpansion
                )
                let clippedPlan = HTMLSyntaxHighlighter.clippedPlan(plan, to: visibleWindow)
                HTMLSyntaxHighlighter.applyTemporary(plan: clippedPlan, to: layoutManager, theme: theme)
                visibleHighlightState.replace(with: clippedPlan)
                recordHighlightedRange(clippedPlan.coveredRange, text: textView.string as NSString)
                if budget.prewarmEnabled {
                    scheduleViewportPrewarm(
                        around: visibleWindow,
                        direction: 0,
                        textSnapshot: html,
                        theme: theme,
                        version: documentVersion,
                        textLength: textView.string.utf16.count,
                        textView: textView
                    )
                }
            }
        }

        let maxLocation = textView.string.utf16.count
        let clampedLocation = min(selectedRange.location, maxLocation)
        let clampedLength = min(selectedRange.length, maxLocation - clampedLocation)
        textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollView.contentView.setBoundsOrigin(visibleRect.origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        CATransaction.commit()

        isUpdatingFromHighlighting = false
    }

    @MainActor
    func applyPlainTextResult(html: String, to textView: NSTextView, in scrollView: NSScrollView) {
        let selectedRange = textView.selectedRange()
        let visibleRect = scrollView.documentVisibleRect

        isUpdatingFromHighlighting = true

        if let layoutManager = textView.layoutManager {
            HTMLSyntaxHighlighter.clearTemporaryHighlights(
                in: layoutManager,
                range: NSRange(location: 0, length: textView.string.utf16.count)
            )
        }

        // Reassigning identical text relays out the whole document and drops the
        // undo stack; on an appearance change the text has not moved at all.
        if textView.string != html {
            textView.string = html
        }
        highlightCoverage.clear()
        visibleHighlightState.clear()

        let maxLocation = textView.string.utf16.count
        let clampedLocation = min(selectedRange.location, maxLocation)
        let clampedLength = min(selectedRange.length, maxLocation - clampedLocation)
        textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollView.contentView.setBoundsOrigin(visibleRect.origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        CATransaction.commit()

        isUpdatingFromHighlighting = false
    }

    @MainActor
    func visibleHighlightWindow(
        for textView: NSTextView,
        scrollView: NSScrollView,
        textLength: Int,
        expansion: Int
    ) -> NSRange {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              textLength > 0 else {
            return NSRange(location: 0, length: 0)
        }

        let visibleRect = scrollView.documentVisibleRect
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
        let expandedStart = max(0, visibleRange.location - expansion)
        let expandedEnd = min(textLength, NSMaxRange(visibleRange) + expansion)
        return NSRange(location: expandedStart, length: max(0, expandedEnd - expandedStart))
    }

    /// Re-applies the theme when the `theme` parameter itself changed.
    /// Appearance switches arrive through `systemAppearanceChanged`; this covers
    /// a caller swapping the theme while the appearance stays put.
    @MainActor
    func applyColorSchemeChangeIfNeeded(textView: NSTextView) {
        let currentScheme = parent.theme.current(for: NSApp.effectiveAppearance)
        guard currentScheme != appliedColorScheme else { return }
        systemAppearanceChanged(textView: textView)
    }

    @MainActor
    func systemAppearanceChanged(textView: NSTextView) {
        let currentTheme = parent.theme.current(for: NSApp.effectiveAppearance)
        appliedColorScheme = currentTheme
        textView.font = currentTheme.font
        textView.backgroundColor = currentTheme.background
        textView.textColor = currentTheme.foreground
        // The knob was pinned to .light, which is near-invisible over a light
        // background; follow the appearance instead.
        textView.enclosingScrollView?.scrollerKnobStyle =
            NSApp.effectiveAppearance.name == .darkAqua ? .light : .default

        let currentHTML = textView.string
        if let cachedFullHighlightPlan,
           cachedFullHighlightVersion == documentVersion,
           let scrollView = textView.enclosingScrollView {
            applyFullHighlightPlan(cachedFullHighlightPlan, html: currentHTML, theme: currentTheme, to: textView, in: scrollView)
        } else {
            performFullHighlighting(html: currentHTML, theme: currentTheme, textView: textView)
        }
    }
}
#endif
