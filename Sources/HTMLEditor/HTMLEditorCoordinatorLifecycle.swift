#if os(macOS)
import AppKit
import QuartzCore

extension HTMLEditor.Coordinator {
    /// Non-contiguous layout exists only in TextKit 1.  TextKit 2 lays out the
    /// viewport by design, so there is nothing to switch — and reaching for
    /// `layoutManager` to do it would drop the view out of TextKit 2 for good.
    @MainActor
    func updateLayoutPolicy(textView: NSTextView, textLength: Int) {
        guard textView.textLayoutManager == nil else { return }
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
        displayedToken = DocumentToken(html)
        pendingLocalBindingSyncHTML = nil
        lastBindingWriteToken = nil
        documentVersion &+= 1
        lastVisibleRange = NSRange(location: 0, length: 0)
        highlightCoverage.clear()
        cachedFullHighlightPlan = nil
        cachedFullHighlightVersion = nil
        cachedRangePlans.removeAll()
        visibleHighlightState.clear()
        prewarmTask?.cancel()
        planner.clear()
        performFullHighlighting(html: html, theme: theme, textView: textView)
    }

    @MainActor
    func shouldApplyExternalUpdate(incomingHTML: String) -> Bool {
        // Deliberately never compares the documents.
        //
        // Comparing them is what made typing slow: `String ==` tests canonical
        // equivalence, normalising both sides through NFD and NFC and walking
        // them scalar by scalar, which on the lazily bridged NSBigMutableString
        // a live NSTextStorage hands back costs ~570 ms for 13 MB. Literal
        // NSString equality is better and still ~66 ms. Neither belongs on a
        // path SwiftUI runs after every keystroke.
        //
        // Worse, there is nothing to compare against: `previousText` holds that
        // same live string, so it reports the *current* text rather than what
        // was displayed when it was assigned. The comparison could never have
        // been the cheap identity check it looked like.
        //
        // So recognise our own echo by a token taken when the write was made:
        // length plus sampled code units, O(1) to build and to check.
        // Already on screen: nothing to do. SwiftUI calls back with the same
        // value after the initial makeNSView, and re-applying it would rebuild
        // the whole document for nothing.
        if displayedToken?.matches(incomingHTML) == true {
            lastBindingWriteToken = nil
            return false
        }

        guard let token = lastBindingWriteToken else { return true }

        if token.matches(incomingHTML) {
            // Our own value coming back. Keep the token while the text view has
            // moved on, because more echoes of it may still arrive.
            return false
        }

        // Something else — a genuine external change, or a parent that
        // normalises what it stores. Either way it has to be applied.
        lastBindingWriteToken = nil
        return true
    }

    @MainActor
    func scheduleBindingSync(for html: String) {
        pendingLocalBindingSyncHTML = html
        bindingSyncTask?.cancel()

        guard let delay = HTMLEditor.bindingSyncDelay(forTextLength: html.utf16.count) else {
            pendingLocalBindingSyncHTML = nil
            lastBindingWriteToken = DocumentToken(html)
            HTMLEditorSignpost.interval("binding-write-immediate") { parent.html = html }
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
            self.lastBindingWriteToken = DocumentToken(html)
            HTMLEditorSignpost.interval("binding-write-deferred") { self.parent.html = html }
        }
    }

    @MainActor
    func flushPendingBindingSync() {
        bindingSyncTask?.cancel()
        bindingSyncTask = nil

        guard let pendingLocalBindingSyncHTML else { return }
        self.pendingLocalBindingSyncHTML = nil
        lastBindingWriteToken = DocumentToken(pendingLocalBindingSyncHTML)
        HTMLEditorSignpost.interval("binding-write-flush") {
            parent.html = pendingLocalBindingSyncHTML
        }
    }

    @MainActor
    func performFullHighlighting(html: String, theme: HTMLEditorColorScheme, textView: NSTextView) {
        guard let scrollView = textView.enclosingScrollView else { return }

        let currentVersion = documentVersion

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

        let plan = planner.fullPlan(for: html)
        // Nothing suspends between capturing the version and this check any
        // more, but the guard is kept so a future re-introduction of async work
        // here cannot silently apply a stale plan.
        guard documentVersion == currentVersion else { return }
        cachedFullHighlightPlan = plan
        cachedFullHighlightVersion = currentVersion
        applyFullHighlightPlan(plan, html: html, theme: theme, to: textView, in: scrollView)
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
        if let surface = HTMLEditorTextKitSurface.resolve(for: textView) {
            let fullRange = NSRange(location: 0, length: textView.string.utf16.count)
            surface.clearHighlights(in: fullRange)
            if let plan {
                let budget = HTMLEditor.highlightBudget(forTextLength: textView.string.utf16.count)
                let visibleWindow = visibleHighlightWindow(
                    for: textView,
                    scrollView: scrollView,
                    textLength: textView.string.utf16.count,
                    expansion: budget.fullPlanVisibleExpansion
                )
                let clippedPlan = HTMLSyntaxHighlighter.clippedPlan(plan, to: visibleWindow)
                HTMLSyntaxHighlighter.apply(plan: clippedPlan, to: surface, theme: theme)
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

        HTMLEditorTextKitSurface.resolve(for: textView)?.clearHighlights(
            in: NSRange(location: 0, length: textView.string.utf16.count)
        )

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
        guard textLength > 0,
              let surface = HTMLEditorTextKitSurface.resolve(for: textView),
              let visibleRange = surface.visibleCharacterRange(
                  in: scrollView.documentVisibleRect,
                  textContainer: textView.textContainer
              ) else {
            return NSRange(location: 0, length: 0)
        }

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
        // Under TextKit 2 the colours are display attributes on vended
        // paragraphs, so a theme change reaches the screen by making TextKit
        // re-ask for them.
        invalidateParagraphHighlighting(in: textView)
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
