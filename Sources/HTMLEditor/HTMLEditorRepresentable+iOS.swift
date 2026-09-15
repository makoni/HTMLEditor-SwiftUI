//
//  HTMLEditorRepresentable+iOS.swift
//  HTMLEditor-SwiftUI
//

#if !os(macOS)
import SwiftUI
import UIKit

@MainActor
extension HTMLEditor: UIViewRepresentable {

    public func makeUIView(context: Context) -> HTMLEditorTextView {
        // TextKit 2 explicitly, even though it is the default from iOS 16 —
        // the default is a default, and one stray TextKit 1 access anywhere
        // below would drop the view irreversibly and still look like it worked,
        // just slowly.
        let textView = HTMLEditorTextView(usingTextLayoutManager: true)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator

        let currentTheme = theme.current(
            for: HTMLEditorAppearance.resolve(from: textView.traitCollection)
        )
        textView.font = currentTheme.font
        textView.backgroundColor = currentTheme.background
        textView.textColor = currentTheme.foreground

        // Every one of these is wrong for markup, and several do work
        // proportional to *what* you type rather than to how much. Link
        // detection scans as you write a URL — which is exactly what
        // `href="https://…"` is — and the three prediction traits run models
        // over the same text.
        textView.dataDetectorTypes = []
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocapitalizationType = .none
        textView.allowsEditingTextAttributes = false
        textView.inlinePredictionType = .no
        if #available(iOS 18.0, *) {
            textView.mathExpressionCompletionType = .no
            textView.writingToolsBehavior = .none
        }

        textView.isEditable = true
        // Left scrolling **on**. Turning it off and relying on intrinsic
        // content size makes UITextView lay out the whole document just to
        // report its height — the exact work TextKit 2's viewport layout
        // exists to avoid, and it would make open time a function of document
        // size again. The host gives the editor a frame instead.
        textView.isScrollEnabled = true
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.widthTracksTextView = true

        // TextKit 2 pulls paragraph styling from this delegate as it lays the
        // viewport out, so it must be in place before any layout happens.
        let contentStorage = textView.textLayoutManager?.textContentManager as? NSTextContentStorage
        contentStorage?.delegate = context.coordinator
        context.coordinator.usesPulledHighlighting = contentStorage != nil

        textView.text = html
        context.coordinator.appliedColorScheme = currentTheme
        context.coordinator.previousText = html
        context.coordinator.displayedToken = Coordinator.DocumentToken(html)

        HTMLSyntaxHighlighter.applyThemeBase(to: textView, theme: currentTheme)
        context.coordinator.syncKeyboardAccessory(on: textView)

        assert(
            textView.textLayoutManager != nil,
            "TextKit 2 was requested but the text view fell back to TextKit 1"
        )
        assert(
            context.coordinator.usesPulledHighlighting,
            "The content-storage delegate is not attached: highlighting would silently do nothing"
        )
        return textView
    }

    public func updateUIView(_ textView: HTMLEditorTextView, context: Context) {
        HTMLEditorSignpost.interval("updateUIView") {
            // SwiftUI hands over a fresh HTMLEditor value on every update, so
            // without this the coordinator keeps the binding and theme it
            // captured at init.
            context.coordinator.parent = self

            context.coordinator.syncKeyboardAccessory(on: textView)

            // Theme first, and unconditionally. These used to be the two arms
            // of one `if`, but the conditions are independent: a host that
            // changes `html` **and** the theme in the same update took the
            // document arm, and `applyExternalDocument` paints from
            // `appliedColorScheme`, which the theme arm is what updates. The
            // result was a freshly replaced document — cache cleared, every
            // paragraph re-vended — wearing the previous theme's colours, with
            // nothing to correct it until some later update happened to carry
            // no document change. The guard inside makes this free when the
            // theme has not moved.
            context.coordinator.applyColorSchemeChangeIfNeeded(textView: textView)

            if context.coordinator.shouldApplyExternalUpdate(incomingHTML: html) {
                context.coordinator.applyExternalDocument(html, to: textView)
            }

            // Focus is not free in a representable the way it is in SwiftUI's
            // own TextEditor: `@FocusState` alone will not make a UITextView
            // first responder.
            if let focusBinding, focusBinding.wrappedValue, !textView.isFirstResponder {
                textView.becomeFirstResponder()
            } else if let focusBinding, !focusBinding.wrappedValue, textView.isFirstResponder {
                textView.resignFirstResponder()
            }
        }
    }

    public static func dismantleUIView(_ textView: HTMLEditorTextView, coordinator: Coordinator) {
        textView.coordinator = nil
        textView.delegate = nil
        textView.inputAccessoryView = nil
        coordinator.accessoryHost = nil
    }
}

/// A `UITextView` that reports trait changes to the coordinator.
///
/// Appearance has to come from the **view's** trait collection:
/// `UITraitCollection.current` is only valid inside a trait-propagating
/// context, and the content-storage delegate callback is not one.
public final class HTMLEditorTextView: UITextView {
    weak var coordinator: HTMLEditor.Coordinator?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        observeTraitChanges()
    }

    convenience init(usingTextLayoutManager: Bool) {
        // `textViewUsingTextLayoutManager(_:)` is unavailable in Swift; the
        // initialiser is the symmetric counterpart of
        // `NSTextView(usingTextLayoutManager:)`.
        self.init(usingTextLayoutManager: usingTextLayoutManager, frame: .zero)
    }

    private convenience init(usingTextLayoutManager: Bool, frame: CGRect) {
        let container: NSTextContainer?
        if usingTextLayoutManager {
            let contentStorage = NSTextContentStorage()
            let layoutManager = NSTextLayoutManager()
            let textContainer = NSTextContainer(size: .zero)
            layoutManager.textContainer = textContainer
            contentStorage.addTextLayoutManager(layoutManager)
            container = textContainer
        } else {
            container = nil
        }
        self.init(frame: frame, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The view-as-parameter closure form: it hands the observer back the view
    /// rather than capturing it, so there is no cycle and no `[weak self]`.
    ///
    /// The `traitCollectionDidChange` override that used to sit beside this is
    /// gone with the iOS 16 floor. It was not an alternative but a fallback,
    /// and it early-returned on 17 and above — which is now every supported
    /// version.
    private func observeTraitChanges() {
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (view: HTMLEditorTextView, _: UITraitCollection) in
            view.coordinator?.systemAppearanceChanged(textView: view)
        }
    }
}

extension HTMLEditor.Coordinator: UITextViewDelegate {

    public func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        recordPendingEdit(affectedRange: range, replacementLength: text.utf16.count)
        return true
    }

    public func textViewDidChange(_ textView: UITextView) {
        handleTextDidChange(textView: textView)
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        parent.focusBinding?.wrappedValue = false
        Task { @MainActor [weak self] in
            self?.flushPendingBindingSync()
        }
    }

    public func textViewDidBeginEditing(_ textView: UITextView) {
        parent.focusBinding?.wrappedValue = true
    }
}
#endif
