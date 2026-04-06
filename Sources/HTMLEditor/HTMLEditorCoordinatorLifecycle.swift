#if os(macOS)
import AppKit
import QuartzCore

extension HTMLEditor.Coordinator {
    @MainActor
    func updateLayoutPolicy(textView: NSTextView, textLength: Int) {
        textView.layoutManager?.allowsNonContiguousLayout = HTMLEditor.shouldUseNonContiguousLayout(
            forTextLength: textLength
        )
    }

    @MainActor
    func scheduleExternalHighlightUpdate(html: String, theme: HTMLEditorColorScheme, textView: NSTextView) {
        bindingSyncTask?.cancel()
        detailRecoveryTask?.cancel()
        updateLayoutPolicy(textView: textView, textLength: html.utf16.count)
        previousText = html
        displayedTextIdentity = HTMLEditor.textIdentity(for: html)
        pendingLocalBindingSyncHTML = nil
        awaitingLocalBindingEcho = false
        documentVersion &+= 1
        lastVisibleRange = NSRange(location: 0, length: 0)
        highlightCoverage.clear()
        cachedFullHighlightPlan = nil
        cachedFullHighlightVersion = nil
        cachedRangePlans.removeAll()
        visibleHighlightState.clear()
        visibleHighlightTask?.cancel()
        prewarmTask?.cancel()
        Task {
            await HTMLSyntaxHighlighter.clearPlannerCache(documentID: plannerDocumentID)
        }
        performFullHighlighting(html: html, theme: theme, textView: textView)
    }

    @MainActor
    func shouldApplyExternalUpdate(incomingHTML: String) -> Bool {
        if awaitingLocalBindingEcho {
            awaitingLocalBindingEcho = false
            return false
        }

        return HTMLEditor.textIdentity(for: incomingHTML) != displayedTextIdentity
    }

    @MainActor
    func scheduleBindingSync(for html: String) {
        pendingLocalBindingSyncHTML = html
        bindingSyncTask?.cancel()

        guard let delay = HTMLEditor.bindingSyncDelay(forTextLength: html.utf16.count) else {
            pendingLocalBindingSyncHTML = nil
            awaitingLocalBindingEcho = true
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
            self.awaitingLocalBindingEcho = true
            self.parent.html = html
        }
    }

    @MainActor
    func flushPendingBindingSync() {
        bindingSyncTask?.cancel()
        bindingSyncTask = nil

        guard let pendingLocalBindingSyncHTML else { return }
        self.pendingLocalBindingSyncHTML = nil
        awaitingLocalBindingEcho = true
        parent.html = pendingLocalBindingSyncHTML
    }

    @MainActor
    func performFullHighlighting(html: String, theme: HTMLEditorColorScheme, textView: NSTextView) {
        guard let scrollView = textView.enclosingScrollView else { return }

        let currentVersion = documentVersion
        fullHighlightTask?.cancel()

        if html.utf16.count > 50_000 {
            cachedFullHighlightPlan = nil
            cachedFullHighlightVersion = nil
            applyPlainTextResult(html: html, to: textView, in: scrollView)
            return
        }

        fullHighlightTask = Task { [weak self, weak textView, weak scrollView] in
            guard let self else { return }
            let plan = await HTMLSyntaxHighlighter.plannedFullHighlight(documentID: self.plannerDocumentID, html: html)
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

        textView.string = html
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

    @MainActor
    func systemAppearanceChanged(textView: NSTextView) {
        let currentTheme = parent.theme.current(for: NSApp.effectiveAppearance)
        textView.font = currentTheme.font
        textView.backgroundColor = currentTheme.background
        textView.textColor = currentTheme.foreground

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
