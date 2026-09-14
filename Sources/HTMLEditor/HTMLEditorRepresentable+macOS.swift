//
//  HTMLEditorRepresentable+macOS.swift
//  HTMLEditor-SwiftUI
//

#if os(macOS)
import SwiftUI
import AppKit

@MainActor
extension HTMLEditor: NSViewRepresentable {

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = AppearanceAwareTextView(
            usingTextLayoutManager: HTMLEditorTextKitVersion.preferred
        )
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isRichText = false
        let currentTheme = theme.current(for: HTMLEditorAppearance.resolve(from: textView.effectiveAppearance))
        textView.font = currentTheme.font
        textView.backgroundColor = currentTheme.background
        textView.textColor = currentTheme.foreground

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Only meaningful under TextKit 1, and reading `layoutManager` at all
        // would drop a TextKit 2 view into compatibility mode permanently.
        if textView.textLayoutManager == nil {
            textView.layoutManager?.allowsNonContiguousLayout = HTMLEditorPolicy.shouldUseNonContiguousLayout(
                forTextLength: html.utf16.count,
                currentlyEnabled: false
            )
        }
        textView.usesRuler = false
        textView.isRulerVisible = false
        // Every one of these is wrong for markup, and several of them do work
        // proportional to what you type rather than to how much you typed.
        // Link detection in particular scans as you write a URL — exactly what
        // `href="https://..."` is — which is why typing markup could feel slower
        // than typing the same number of letters.
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isIncrementalSearchingEnabled = false
        textView.drawsBackground = true
        textView.textContainer?.widthTracksTextView = true

        // TextKit 2 pulls paragraph styling from this delegate as it lays the
        // viewport out, so it must be in place before any layout happens.
        textView.textContentStorage?.delegate = context.coordinator
        context.coordinator.usesPulledHighlighting = textView.textLayoutManager != nil

        textView.string = html
        textView.coordinator = context.coordinator
        context.coordinator.appliedColorScheme = currentTheme
        context.coordinator.previousText = html
        context.coordinator.displayedToken = Coordinator.DocumentToken(html)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none

        HTMLSyntaxHighlighter.applyThemeBase(to: textView, theme: currentTheme)
        HTMLEditorTextKitSurface.resolve(for: textView)?.clearHighlights(
            in: NSRange(location: 0, length: html.utf16.count)
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(context.coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        if let container = textView.textContainer {
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 0
        }
        context.coordinator.performFullHighlighting(
            html: html,
            theme: currentTheme,
            textView: textView
        )

        // A single stray TextKit 1 access anywhere in the setup above would have
        // dropped the view back irreversibly, and it would still look like it
        // worked — just slowly.  Fail loudly in debug instead.
        assert(
            !HTMLEditorTextKitVersion.preferred || textView.textLayoutManager != nil,
            "TextKit 2 was requested but the text view fell back to TextKit 1"
        )
        HTMLEditorAutoTypeDiagnostic.startIfRequested(textView: textView, scrollView: scrollView)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        HTMLEditorSignpost.interval("updateNSView") {
            performUpdate(scrollView, context: context)
        }
    }

    private func performUpdate(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // SwiftUI hands over a fresh HTMLEditor value on every update, so without
        // this the coordinator keeps the binding and theme it captured at init:
        // `theme` would be write-once, and edits would keep flowing back into a
        // binding that no longer points at the document on screen.
        context.coordinator.parent = self
        context.coordinator.updateLayoutPolicy(textView: textView, textLength: html.utf16.count)

        // Unconditional, for the same reason as iOS — see the note there. macOS
        // resolves the theme inline below so the repaint itself was right, but
        // `appliedColorScheme` stayed stale, and the paragraph delegate reads
        // it for every paragraph it vends.
        context.coordinator.applyColorSchemeChangeIfNeeded(textView: textView)

        if context.coordinator.shouldApplyExternalUpdate(incomingHTML: html) {
            let currentTheme = theme.current(for: HTMLEditorAppearance.resolve(from: textView.effectiveAppearance))
            context.coordinator.scheduleExternalHighlightUpdate(html: html, theme: currentTheme, textView: textView)
        }
    }

    class AppearanceAwareTextView: NSTextView {
        weak var coordinator: Coordinator?

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            coordinator?.systemAppearanceChanged(textView: self)
        }
    }
}

extension HTMLEditor.Coordinator: NSTextViewDelegate {

    public func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        recordPendingEdit(
            affectedRange: affectedCharRange,
            replacementLength: replacementString?.utf16.count ?? 0
        )
        return true
    }

    public func textDidEndEditing(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.flushPendingBindingSync()
        }
    }

    public func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        handleTextDidChange(textView: textView)
    }
}
#endif
