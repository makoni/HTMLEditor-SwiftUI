#if os(macOS)
import SwiftUI

public struct HTMLEditor: NSViewRepresentable {
    @Binding public var html: String
    public var theme: HTMLEditorTheme

    public init(html: Binding<String>, theme: HTMLEditorTheme = .default) {
        self._html = html
        self.theme = theme
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = AppearanceAwareTextView(
            usingTextLayoutManager: HTMLEditorTextKitVersion.preferred
        )
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isRichText = false
        let currentTheme = theme.current(for: NSApp.effectiveAppearance)
        textView.font = currentTheme.font
        textView.backgroundColor = currentTheme.background
        textView.textColor = currentTheme.foreground

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Only meaningful under TextKit 1, and reading `layoutManager` at all
        // would drop a TextKit 2 view into compatibility mode permanently.
        if textView.textLayoutManager == nil {
            textView.layoutManager?.allowsNonContiguousLayout = HTMLEditor.shouldUseNonContiguousLayout(
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
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // SwiftUI hands over a fresh HTMLEditor value on every update, so without
        // this the coordinator keeps the binding and theme it captured at init:
        // `theme` would be write-once, and edits would keep flowing back into a
        // binding that no longer points at the document on screen.
        context.coordinator.parent = self
        context.coordinator.updateLayoutPolicy(textView: textView, textLength: html.utf16.count)

        if context.coordinator.shouldApplyExternalUpdate(incomingHTML: html) {
            let currentTheme = theme.current(for: NSApp.effectiveAppearance)
            context.coordinator.scheduleExternalHighlightUpdate(html: html, theme: currentTheme, textView: textView)
        } else {
            context.coordinator.applyColorSchemeChangeIfNeeded(textView: textView)
        }
    }

    class AppearanceAwareTextView: NSTextView {
        weak var coordinator: Coordinator?

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            coordinator?.systemAppearanceChanged(textView: self)
        }
    }

    /// Main-actor isolated rather than `@unchecked Sendable`.  Conforming to
    /// NSTextViewDelegate only infers `@MainActor` on the individual delegate
    /// methods, not on the class, so the stored state stayed nonisolated and the
    /// unchecked conformance disabled the checking that would have caught a
    /// `nonisolated` helper touching it.
    @MainActor
    public class Coordinator: NSObject, NSTextViewDelegate {
        struct CachedRangePlan {
            let range: NSRange
            let version: Int
            let textLength: Int
            let plan: HTMLSyntaxHighlighter.HighlightPlan
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
        /// The exact string most recently written through the binding, kept so
        /// its echo can be recognised even after the text view has moved on.
        var lastBindingWriteHTML: String?
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

        public func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            pendingEdit = PendingEdit(
                affectedRange: affectedCharRange,
                replacementUTF16Length: replacementString?.utf16.count ?? 0
            )
            return true
        }

        public func textDidEndEditing(_ notification: Notification) {
            Task { @MainActor [weak self] in
                self?.flushPendingBindingSync()
            }
        }

        public func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromHighlighting,
                  let textView = notification.object as? NSTextView else { return }

            let newText = textView.string
            let oldLength = previousText.utf16.count
            let newLength = newText.utf16.count
            let magnitude = HTMLEditor.editMagnitude(
                oldLength: oldLength,
                newLength: newLength,
                editRangeLength: pendingEdit?.affectedRange.length ?? 0,
                replacementLength: pendingEdit?.replacementUTF16Length ?? 0
            )

            previousText = newText
            documentVersion &+= 1
            updateLayoutPolicy(textView: textView, textLength: newLength)
            cachedFullHighlightPlan = nil
            cachedFullHighlightVersion = nil
            prewarmTask?.cancel()
            detailRecoveryTask?.cancel()

            if let pendingEdit, !usesPulledHighlighting {
                let structuralDirtyRange = HTMLEditor.structuralDirtyRange(
                    for: pendingEdit.affectedRange,
                    replacementLength: pendingEdit.replacementUTF16Length,
                    in: newText as NSString,
                    expansion: HTMLEditor.highlightBudget(forTextLength: newLength).visibleExpansion
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

            // Gated on how big the edit was, not how big the document is: a
            // one-character change in a multi-megabyte file is exactly the case
            // the planner's remapping was built for.
            if usesPulledHighlighting {
                // The planner and the coverage map only feed the push pipeline.
                self.pendingEdit = nil
            } else if let pendingEdit, magnitude == .incremental || magnitude == .medium {
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

            scheduleBindingSync(for: newText)

            // Under TextKit 2 the delegate has already re-styled the edited
            // paragraph by the time this runs; there is nothing left to schedule.
            guard !usesPulledHighlighting else {
                self.pendingEdit = nil
                return
            }

            guard let scrollView = textView.enclosingScrollView else { return }
            let detail = HTMLEditor.highlightDetail(
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
#endif
