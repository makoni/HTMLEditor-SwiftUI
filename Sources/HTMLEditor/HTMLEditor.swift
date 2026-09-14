//
//  HTMLEditor.swift
//  HTMLEditor-SwiftUI
//
//  The editor value and its coordinator. The SwiftUI representable
//  conformances live in HTMLEditorRepresentable+macOS.swift and
//  HTMLEditorRepresentable+iOS.swift.
//

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A SwiftUI HTML source editor with syntax highlighting.
///
/// Backed by `NSTextView` on macOS and `UITextView` on iOS / iPadOS, both on
/// **TextKit 2**. Highlighting is pulled by the framework: the content-storage
/// delegate is asked for each paragraph as it is laid out, so there is no
/// scheduling and the cost of a keystroke does not grow with the document.
public struct HTMLEditor {
    @Binding public var html: String
    public var theme: HTMLEditorTheme
    /// Optional two-way focus, for hosts that drive the editor with
    /// `@FocusState`. `UIViewRepresentable` does not get that for free the way
    /// SwiftUI's own `TextEditor` does.
    var focusBinding: Binding<Bool>?
    #if !os(macOS)
    /// Content to sit above the keyboard while the editor holds it.
    ///
    /// iOS has nowhere else to put an editing accessory. SwiftUI's own
    /// `ToolbarItemGroup(placement: .keyboard)` only reaches SwiftUI's text
    /// inputs: it is installed on the responder SwiftUI owns, and a
    /// `UIViewRepresentable` text view is not one — declaring it gives you a
    /// bar above the keyboard for every `TextField` on the screen and nothing
    /// at all for the editor. So the editor carries its own.
    var keyboardAccessory: (() -> AnyView)?
    #endif

    public init(html: Binding<String>, theme: HTMLEditorTheme = .default) {
        self._html = html
        self.theme = theme
        self.focusBinding = nil
    }

    /// Focus-aware variant: the editor becomes first responder when `isFocused`
    /// turns true, and reports back when the user taps into or out of it.
    public init(html: Binding<String>, isFocused: Binding<Bool>, theme: HTMLEditorTheme = .default) {
        self._html = html
        self.theme = theme
        self.focusBinding = isFocused
    }

    #if !os(macOS)
    /// Puts `content` above the keyboard while the editor is being edited.
    ///
    /// Rebuilt on every SwiftUI update, so the bar can depend on the host's
    /// state — which section is being edited, what is selected — and stay in
    /// step with it.
    public func keyboardAccessory<Content: View>(
        @ViewBuilder _ content: @escaping () -> Content
    ) -> HTMLEditor {
        var copy = self
        copy.keyboardAccessory = { AnyView(content()) }
        return copy
    }
    #endif

    @MainActor
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// Main-actor isolated rather than `@unchecked Sendable`.  Conforming to
    /// NSTextViewDelegate only infers `@MainActor` on the individual delegate
    /// methods, not on the class, so the stored state stayed nonisolated and the
    /// unchecked conformance disabled the checking that would have caught a
    /// `nonisolated` helper touching it.
    @MainActor
    public class Coordinator: NSObject {
        #if !os(macOS)
        /// Retains the keyboard accessory's hosting controller. Nothing else
        /// holds it — an input accessory view has no view-controller parent, so
        /// dropping this leaves SwiftUI content that never updates again.
        var accessoryHost: UIHostingController<AnyView>?
        #endif

        struct CachedRangePlan {
            let range: NSRange
            let version: Int
            let textLength: Int
            let plan: HTMLSyntaxHighlighter.HighlightPlan
        }

        /// A snapshot of a document this editor wrote, for recognising its own
        /// echo coming back through the binding.
        ///
        /// This used to hash 64 sampled code units instead of keeping the
        /// string, and the comment here claimed exactness would cost "hundreds
        /// of milliseconds per keystroke". Both halves were wrong. Measured on
        /// a 10 250-character document, **10 186 of 10 250** single-character
        /// changes collided with the sampled token — and a collision means
        /// `shouldApplyExternalUpdate` returns false, so a host that rewrites
        /// the document to the same length (a find-and-replace,
        /// `class="a"` → `class="b"`) had its change silently dropped, with the
        /// binding and the editor left disagreeing and no way back.
        ///
        /// Comparing exactly is nowhere near that expensive. Measured on a
        /// 1.7 MB document:
        ///
        /// | case | per call |
        /// |---|---|
        /// | our own echo — shared storage | 0.0001 ms |
        /// | same text, different storage | 0.0294 ms |
        /// | a genuinely different document | 0.0144 ms |
        ///
        /// `String ==` short-circuits when both sides share storage, and the
        /// echo *is* shared storage: SwiftUI hands back the very value this
        /// editor wrote. The worst case is a full walk of 1.7 MB at 0.03 ms,
        /// against a 16 ms frame. Holding the string costs nothing either — it
        /// is a reference to storage the binding already owns.
        ///
        /// What the old comment was probably measuring is a different
        /// comparison: `textView.string == html` builds a fresh `String` out of
        /// the text storage every time, so it can never take the shared-storage
        /// path.
        struct DocumentToken {
            private let text: String

            init(_ text: String) {
                self.text = text
            }

            func matches(_ candidate: String) -> Bool {
                text == candidate
            }
        }

        struct PendingEdit {
            let affectedRange: NSRange
            let replacementUTF16Length: Int
        }

        var parent: HTMLEditor
        var isUpdatingFromHighlighting = false
        var previousText = ""
        var visibleHighlightDebounceTask: Task<Void, Never>?
        var scrollIdleTask: Task<Void, Never>?
        var prewarmTask: Task<Void, Never>?
        var bindingSyncTask: Task<Void, Never>?
        var detailRecoveryTask: Task<Void, Never>?
        var editBurstTask: Task<Void, Never>?
        var documentVersion: Int = 0
        /// One planner per editor: caches, caps and lifetime all scoped to this
        /// document rather than shared process-wide.
        let planner = HTMLHighlightPlanner()
        var pendingLocalBindingSyncHTML: String?
        /// Identifies the value most recently written through the binding, so
        /// its echo can be recognised without comparing whole documents.
        var lastBindingWriteToken: DocumentToken?
        /// Identifies what the text view is showing, for the same reason.
        var displayedToken: DocumentToken?
        var pendingEdit: PendingEdit?
        var cachedFullHighlightPlan: HTMLSyntaxHighlighter.HighlightPlan?
        var cachedFullHighlightVersion: Int?
        var cachedRangePlans: [CachedRangePlan] = []
        var lastVisibleRange = NSRange(location: 0, length: 0)
        var highlightCoverage = HTMLEditorHighlightCoverage()
        var visibleHighlightState = HTMLEditorVisibleHighlightState()
        var appliedColorScheme: HTMLEditorColorScheme?
        /// True when highlighting is pulled from the content storage delegate.
        /// The whole push pipeline — scheduled visible-range passes, prewarm,
        /// coverage bookkeeping, the scroll observer — exists to decide *when*
        /// to paint, and under TextKit 2 the framework decides that by asking.
        /// Running it anyway is pure main-thread work competing with drawing.
        var usesPulledHighlighting = false
        /// Per-paragraph plans for the TextKit 2 pull-based path.
        var styledParagraphCache: [ParagraphPlanKey: NSTextParagraph] = [:]

        init(_ parent: HTMLEditor) {
            self.parent = parent
            super.init()
        }

        /// Records what is about to change, so the edit's magnitude is known
        /// before the text view has changed. Called from both platforms'
        /// delegate methods.
        func recordPendingEdit(affectedRange: NSRange, replacementLength: Int) {
            pendingEdit = PendingEdit(
                affectedRange: affectedRange,
                replacementUTF16Length: replacementLength
            )
        }

        /// The one text-changed path. The two platforms' delegate protocols
        /// name their callbacks differently and hand over the view differently;
        /// everything after that is identical.
        func handleTextDidChange(textView: HTMLEditorPlatform.TextView) {
            HTMLEditorSignpost.interval("textDidChange") {
                applyTextDidChange(textView: textView)
            }
        }

        private func applyTextDidChange(textView: HTMLEditorPlatform.TextView) {
            guard !isUpdatingFromHighlighting else { return }

            let newText = textView.htmlEditorText
            let oldLength = previousText.utf16.count
            let newLength = newText.utf16.count
            let magnitude = HTMLEditorPolicy.editMagnitude(
                oldLength: oldLength,
                newLength: newLength,
                editRangeLength: pendingEdit?.affectedRange.length ?? 0,
                replacementLength: pendingEdit?.replacementUTF16Length ?? 0
            )

            previousText = newText
            displayedToken = DocumentToken(newText)
            documentVersion &+= 1
            updateLayoutPolicy(textView: textView, textLength: newLength)
            cachedFullHighlightPlan = nil
            cachedFullHighlightVersion = nil
            prewarmTask?.cancel()
            detailRecoveryTask?.cancel()

            #if os(macOS)
            if let pendingEdit, !usesPulledHighlighting {
                let structuralDirtyRange = HTMLEditorPolicy.structuralDirtyRange(
                    for: pendingEdit.affectedRange,
                    replacementLength: pendingEdit.replacementUTF16Length,
                    in: newText as NSString,
                    expansion: HTMLEditorPolicy.highlightBudget(forTextLength: newLength).visibleExpansion
                )
                highlightCoverage.remapAfterEdit(
                    editRange: pendingEdit.affectedRange,
                    replacementUTF16Length: pendingEdit.replacementUTF16Length,
                    newTextLength: newLength,
                    dirtyRange: structuralDirtyRange
                )
                preserveVisibleHighlightAfterEdit(
                    textView: textView,
                    edit: pendingEdit,
                    newTextLength: newLength,
                    dirtyRange: structuralDirtyRange
                )
                // Mark everything beyond the current visible plan as dirty so the
                // prewarm scheduled after the edit-triggered re-highlight will
                // re-check those blocks.  This prevents stale prewarm highlights
                // (applied for the pre-edit document state) from persisting at
                // positions the edit-triggered re-highlight does not reach.
                if let visiblePlanEnd = visibleHighlightState.plan.map({ NSMaxRange($0.coveredRange) }),
                   visiblePlanEnd < newLength {
                    highlightCoverage.markDirty(
                        NSRange(location: visiblePlanEnd, length: newLength - visiblePlanEnd)
                    )
                }
                scheduleDirtyBlockHighlightAfterEdit(
                    textView: textView,
                    newTextLength: newLength
                )
            }
            #endif

            // Gated on how big the edit was, not how big the document is: a
            // one-character change in a multi-megabyte file is exactly the case
            // the planner's remapping was built for.
            if usesPulledHighlighting {
                // The planner and the coverage map only feed the push pipeline.
                self.pendingEdit = nil
            } else {
                #if os(macOS)
                if let pendingEdit, magnitude == .incremental || magnitude == .medium {
                    invalidateCaches(for: pendingEdit, newTextLength: newLength)
                // Synchronous, so the invalidation is ordered before the plan
                // requests the repaint schedules moments later.  As two
                // unstructured tasks these had no ordering guarantee at all;
                // correctness rested on a debounce being longer than an actor
                // hop.
                    planner.invalidate(
                        editRange: pendingEdit.affectedRange,
                        replacementUTF16Length: pendingEdit.replacementUTF16Length,
                        newTextLength: newLength
                    )
                    self.pendingEdit = nil
                } else {
                    cachedRangePlans.removeAll()
                    lastVisibleRange = NSRange(location: 0, length: 0)
                    planner.clear()
                    self.pendingEdit = nil
                }
                #endif
            }

            scheduleBindingSync(for: newText)

            // Under TextKit 2 the delegate has already re-styled the edited
            // paragraph by the time this runs; there is nothing left to schedule.
            guard !usesPulledHighlighting else {
                self.pendingEdit = nil
                return
            }

            #if os(macOS)
            guard let scrollView = textView.enclosingScrollView else { return }
            let detail = HTMLEditorPolicy.highlightDetail(
                forTextLength: newLength,
                magnitude: magnitude,
                trigger: .edit
            )
            let allowPrewarm = magnitude == .incremental
            scheduleVisibleRangeHighlighting(
                textView: textView,
                scrollView: scrollView,
                forceHighlight: true,
                allowPrewarm: allowPrewarm,
                trigger: .edit,
                detail: detail
            )

            if detail == .tagsOnly {
                scheduleFullDetailRecovery(textView: textView, scrollView: scrollView)
            }
            #endif
        }

        deinit {
            visibleHighlightDebounceTask?.cancel()
            scrollIdleTask?.cancel()
            prewarmTask?.cancel()
            bindingSyncTask?.cancel()
            detailRecoveryTask?.cancel()
            editBurstTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }
    }
}
