//
//  HTMLEditorKeyboardAccessory.swift
//  HTMLEditor-SwiftUI
//
//  The bar above the keyboard, on iOS and iPadOS.
//

#if !os(macOS)
import SwiftUI
import UIKit

/// Hosts SwiftUI content as a `UITextView.inputAccessoryView`.
///
/// Plain autoresizing rather than Auto Layout: an input accessory view is
/// positioned by the keyboard, not by a parent's constraints, and giving it a
/// frame plus `.flexibleWidth` is the arrangement UIKit has always sized
/// correctly there. It is also the reason the height is fixed — a self-sizing
/// accessory needs `UIInputView.allowsSelfSizing` and an Auto Layout chain that
/// reaches the hosting controller's view, and that buys nothing for a single
/// row of buttons.
@MainActor
final class HTMLEditorAccessoryView: UIInputView {
    /// One row of controls, the same height UIKit gives its own shortcut bar.
    static let height: CGFloat = 44

    init(content: UIView) {
        super.init(
            // The width is a placeholder: UIKit resizes an input accessory
            // view to the keyboard's width, and `.flexibleWidth` below is what
            // lets it. Asking `UIScreen.main` for a real number would be both
            // wrong on iPad — where the keyboard is not the screen's width —
            // and deprecated.
            frame: CGRect(x: 0, y: 0, width: 320, height: Self.height),
            inputViewStyle: .keyboard
        )
        // `.keyboard` is what draws the material behind the row. A plain
        // `UIView` here left the buttons floating over the page with nothing
        // behind them — and when no software keyboard is up, iOS docks the
        // accessory at the bottom of the screen, where that looked like stray
        // controls lying on the content.
        autoresizingMask = .flexibleWidth
        content.frame = bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.backgroundColor = .clear
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

extension HTMLEditor.Coordinator {

    /// Installs, refreshes or removes the accessory to match the current value.
    ///
    /// Called from both `makeUIView` and `updateUIView`: the host rebuilds its
    /// bar on every SwiftUI update, and a bar that kept the closure captured at
    /// creation would act on stale state — tapping "bold" after switching
    /// sections would edit the section you left.
    func syncKeyboardAccessory(on textView: UITextView) {
        guard let accessory = parent.keyboardAccessory else {
            if accessoryHost != nil {
                accessoryHost = nil
                textView.inputAccessoryView = nil
                textView.reloadInputViews()
            }
            return
        }

        if let host = accessoryHost {
            host.rootView = accessory()
            return
        }

        let host = UIHostingController(rootView: accessory())
        host.view.backgroundColor = .clear
        // Without this the hosting view keeps the safe-area inset of the
        // window it is measured against and the row sits visibly low. The
        // package's floor is iOS 16, so this stays conditional.
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = []
        }
        accessoryHost = host
        textView.inputAccessoryView = HTMLEditorAccessoryView(content: host.view)

        // Only matters if the view is already first responder — assigning the
        // accessory after the keyboard is up does nothing on its own.
        if textView.isFirstResponder {
            textView.reloadInputViews()
        }
    }
}
#endif
