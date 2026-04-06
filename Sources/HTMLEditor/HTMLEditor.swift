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
        let textView = AppearanceAwareTextView()
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
        textView.layoutManager?.allowsNonContiguousLayout = HTMLEditor.shouldUseNonContiguousLayout(
            forTextLength: html.utf16.count
        )
        textView.usesRuler = false
        textView.isRulerVisible = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.drawsBackground = true
        textView.textContainer?.widthTracksTextView = true

        textView.string = html
        textView.coordinator = context.coordinator
        context.coordinator.previousText = html
        context.coordinator.displayedTextIdentity = HTMLEditor.textIdentity(for: html)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.scrollerKnobStyle = .light
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none

        HTMLSyntaxHighlighter.applyThemeBase(to: textView, theme: currentTheme)
        if html.utf16.count <= HTMLSyntaxHighlighter.maxHighlightLength,
           let layoutManager = textView.layoutManager {
            let highlighted = HTMLSyntaxHighlighter.highlight(html: html, theme: currentTheme)
            textView.textStorage?.setAttributedString(highlighted)
            HTMLSyntaxHighlighter.clearTemporaryHighlights(
                in: layoutManager,
                range: NSRange(location: 0, length: html.utf16.count)
            )
        }
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
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.updateLayoutPolicy(textView: textView, textLength: html.utf16.count)
        if context.coordinator.shouldApplyExternalUpdate(incomingHTML: html) {
            let currentTheme = theme.current(for: NSApp.effectiveAppearance)
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

    public class Coordinator: NSObject, NSTextViewDelegate, @unchecked Sendable {
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
        var visibleHighlightTask: Task<Void, Never>?
        var scrollIdleTask: Task<Void, Never>?
        var prewarmTask: Task<Void, Never>?
        var fullHighlightTask: Task<Void, Never>?
        var bindingSyncTask: Task<Void, Never>?
        var detailRecoveryTask: Task<Void, Never>?
        var editBurstTask: Task<Void, Never>?
        var documentVersion: Int = 0
        let plannerDocumentID = UUID()
        var pendingLocalBindingSyncHTML: String?
        var awaitingLocalBindingEcho = false
        var pendingEdit: PendingEdit?
        var cachedFullHighlightPlan: HTMLSyntaxHighlighter.HighlightPlan?
        var cachedFullHighlightVersion: Int?
        var cachedRangePlans: [CachedRangePlan] = []
        var lastVisibleRange = NSRange(location: 0, length: 0)
        var highlightCoverage = HTMLEditorHighlightCoverage()
        var visibleHighlightState = HTMLEditorVisibleHighlightState()
        var displayedTextIdentity: Int = 0

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
            let strategy = HTMLEditor.refreshStrategy(
                oldLength: oldLength,
                newLength: newLength,
                editRangeLength: pendingEdit?.affectedRange.length ?? 0,
                replacementLength: pendingEdit?.replacementUTF16Length ?? 0
            )

            previousText = newText
            displayedTextIdentity = HTMLEditor.textIdentity(for: newText)
            documentVersion &+= 1
            updateLayoutPolicy(textView: textView, textLength: newLength)
            cachedFullHighlightPlan = nil
            cachedFullHighlightVersion = nil
            fullHighlightTask?.cancel()
            prewarmTask?.cancel()
            detailRecoveryTask?.cancel()

            if let pendingEdit {
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
                scheduleDirtyBlockHighlightAfterEdit(
                    textView: textView,
                    newTextLength: newLength
                )
            }

            if let pendingEdit, strategy == .incremental || strategy == .mediumChange {
                invalidateCaches(for: pendingEdit, newTextLength: newLength)
                Task {
                    await HTMLSyntaxHighlighter.invalidatePlannerCache(
                        documentID: self.plannerDocumentID,
                        editRange: pendingEdit.affectedRange,
                        replacementUTF16Length: pendingEdit.replacementUTF16Length,
                        newTextLength: newLength
                    )
                }
                self.pendingEdit = nil
            } else {
                cachedRangePlans.removeAll()
                lastVisibleRange = NSRange(location: 0, length: 0)
                Task {
                    await HTMLSyntaxHighlighter.clearPlannerCache(documentID: self.plannerDocumentID)
                }
                self.pendingEdit = nil
            }

            if strategy == .majorChange || strategy == .largeDocument {
                cachedRangePlans.removeAll()
                lastVisibleRange = NSRange(location: 0, length: 0)
                Task {
                    await HTMLSyntaxHighlighter.clearPlannerCache(documentID: self.plannerDocumentID)
                }
            }

            scheduleBindingSync(for: newText)

            guard let scrollView = textView.enclosingScrollView else { return }
            let detail = HTMLEditor.highlightDetail(
                forTextLength: newLength,
                strategy: strategy,
                trigger: .edit
            )
            let allowPrewarm = strategy == .incremental
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
            visibleHighlightTask?.cancel()
            scrollIdleTask?.cancel()
            prewarmTask?.cancel()
            fullHighlightTask?.cancel()
            bindingSyncTask?.cancel()
            detailRecoveryTask?.cancel()
            editBurstTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }
    }
}
#endif
