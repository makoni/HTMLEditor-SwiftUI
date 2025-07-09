//
//  HTMLEditor.swift
//  HTMLEditor-SwiftUI
//
//  Created by Sergei Armodin on 07.07.2025.
//  Copyright © 2025 Sergey Armodin. All rights reserved.
//

#if os(macOS)
import SwiftUI
import SwiftSoup
import os.log

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
		let textView = AppearanceAwareTextView()
		textView.delegate = context.coordinator
		textView.isEditable = true
		textView.isRichText = false
		let currentTheme = theme.current(for: NSApp.effectiveAppearance)
		textView.font = currentTheme.font
		textView.backgroundColor = currentTheme.background
		textView.textColor = currentTheme.foreground

		textView.isVerticallyResizable = true
		textView.isHorizontallyResizable = true
		textView.autoresizingMask = [.width, .height]

        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

		// Set text container and background drawing to allow background color
		textView.drawsBackground = true
		if let container = textView.textContainer {
			container.widthTracksTextView = true
		}

		textView.string = html
		textView.textStorage?.setAttributedString(HTMLSyntaxHighlighter.highlight(html: html, theme: currentTheme))
		textView.coordinator = context.coordinator

		let scrollView = NSScrollView()
		scrollView.documentView = textView
		scrollView.hasVerticalScroller = true
		scrollView.hasHorizontalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.borderType = .bezelBorder
		scrollView.translatesAutoresizingMaskIntoConstraints = false
		return scrollView
	}

	public func updateNSView(_ scrollView: NSScrollView, context: Context) {
		guard let textView = scrollView.documentView as? NSTextView else { return }
		if textView.string != html {
			let currentTheme = theme.current(for: NSApp.effectiveAppearance)
			textView.textStorage?.setAttributedString(HTMLSyntaxHighlighter.highlight(html: html, theme: currentTheme))
		}
	}

	// Custom NSTextView to handle appearance changes
	class AppearanceAwareTextView: NSTextView {
		weak var coordinator: Coordinator?
		override func viewDidChangeEffectiveAppearance() {
			super.viewDidChangeEffectiveAppearance()
			coordinator?.systemAppearanceChanged(textView: self)
		}
	}

	public class Coordinator: NSObject, NSTextViewDelegate {
		var parent: HTMLEditor

		init(_ parent: HTMLEditor) {
			self.parent = parent
		}

		public func textDidChange(_ notification: Notification) {
			guard let textView = notification.object as? NSTextView else { return }
			let newText = textView.string
			if parent.html != newText {
				parent.html = newText
				let selectedRange = textView.selectedRange()  // Save cursor position
				let currentTheme = parent.theme.current(for: NSApp.effectiveAppearance)
				textView.textStorage?.setAttributedString(HTMLSyntaxHighlighter.highlight(html: newText, theme: currentTheme))
				textView.setSelectedRange(selectedRange)  // Restore cursor position
			}
		}

		// Appearance change handler
		@MainActor
		func systemAppearanceChanged(textView: NSTextView) {
			let currentTheme = parent.theme.current(for: NSApp.effectiveAppearance)
			textView.font = currentTheme.font
			textView.backgroundColor = currentTheme.background
			textView.textColor = currentTheme.foreground
			textView.textStorage?.setAttributedString(HTMLSyntaxHighlighter.highlight(html: parent.html, theme: currentTheme))
		}

		// No longer needed: parentScrollView/findScrollView
	}
}
#endif
