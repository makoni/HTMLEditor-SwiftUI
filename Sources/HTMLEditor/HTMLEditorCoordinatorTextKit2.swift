//
//  HTMLEditorCoordinatorTextKit2.swift
//  HTMLEditor-SwiftUI
//
//  The lifecycle a TextKit 2 editor actually needs.
//

import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Document lifecycle for the pull-based path.
///
/// Under TextKit 2 opening a document is: set the text, have the delegate in
/// place, invalidate. Nothing else. The push pipeline's
/// `performFullHighlighting` did far more — a whole-document
/// `planner.fullPlan`, then `clearHighlights` and `applyHighlights`, **both of
/// which are `break` on the `textKit2` case**, then coverage bookkeeping
/// nothing reads, then a viewport prewarm whose painting is also a no-op. That
/// ran on every open, every external update and every theme change, and threw
/// all of it away. This is that path, without the waste — which is why macOS
/// uses it too.
@MainActor
extension HTMLEditor.Coordinator {

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

        guard let delay = HTMLEditorPolicy.bindingSyncDelay(forTextLength: html.utf16.count) else {
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


    /// Replaces the document from outside the editor.
    ///
    /// Setting the text is itself the thing that makes TextKit re-ask the
    /// delegate for every paragraph it lays out, so there is nothing to
    /// schedule afterwards.
    func applyExternalDocument(_ html: String, to textView: HTMLEditorPlatform.TextView) {
        HTMLEditorSignpost.interval("external-document") {
            isUpdatingFromHighlighting = true
            defer { isUpdatingFromHighlighting = false }

            styledParagraphCache.removeAll(keepingCapacity: true)
            textView.htmlEditorText = html
            previousText = html
            displayedToken = DocumentToken(html)
            documentVersion &+= 1

            if let theme = appliedColorScheme {
                HTMLSyntaxHighlighter.applyThemeBase(to: textView, theme: theme)
            }
        }
    }

    /// Repaints after a theme or appearance change.
    ///
    /// Order matters and is not obvious: dropping the paragraph cache alone
    /// changes nothing on screen, and `invalidateLayout` alone does **not**
    /// re-ask the delegate — measured at +0 delegate calls on both platforms.
    /// What re-asks is an edit to the text storage, which is exactly what
    /// `applyThemeBase`'s `beginEditing`/`endEditing` performs. So: clear the
    /// cache first, then let `applyThemeBase` trigger the re-ask.
    func applyThemeChange(_ theme: HTMLEditorColorScheme, to textView: HTMLEditorPlatform.TextView) {
        appliedColorScheme = theme
        styledParagraphCache.removeAll(keepingCapacity: true)
        HTMLSyntaxHighlighter.applyThemeBase(to: textView, theme: theme)
    }
}

#if !os(macOS)
@MainActor
extension HTMLEditor.Coordinator {

    func currentTheme(for textView: HTMLEditorPlatform.TextView) -> HTMLEditorColorScheme {
        parent.theme.current(for: HTMLEditorAppearance.resolve(from: textView.traitCollection))
    }

    func applyColorSchemeChangeIfNeeded(textView: HTMLEditorPlatform.TextView) {
        let scheme = currentTheme(for: textView)
        guard scheme != appliedColorScheme else { return }
        systemAppearanceChanged(textView: textView)
    }

    func systemAppearanceChanged(textView: HTMLEditorPlatform.TextView) {
        let theme = currentTheme(for: textView)
        applyThemeChange(theme, to: textView)
        textView.font = theme.font
        textView.backgroundColor = theme.background
        textView.textColor = theme.foreground
        textView.indicatorStyle = HTMLEditorAppearance.resolve(from: textView.traitCollection) == .dark
            ? .white
            : .black
    }

    /// No-op on iOS: non-contiguous layout is a TextKit 1 knob, and there is no
    /// TextKit 1 path here.
    func updateLayoutPolicy(textView: HTMLEditorPlatform.TextView, textLength: Int) {}
}
#endif
