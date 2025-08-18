//
//  HTMLEditor.swift
//  HTMLEditor-SwiftUI
//
//  Created by Sergei Armodin on 07.07.2025.
//  Copyright © 2025 Sergey Armodin. All rights reserved.
//

#if os(macOS)
import SwiftUI
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
		textView.isHorizontallyResizable = false
		textView.autoresizingMask = [.width]
		
		// Prevent empty line artifacts and improve performance
		textView.layoutManager?.allowsNonContiguousLayout = false
		textView.usesRuler = false
		textView.isRulerVisible = false

        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
		textView.isAutomaticQuoteSubstitutionEnabled = false

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
		
		// Set up scroll monitoring via content view
		scrollView.contentView.postsBoundsChangedNotifications = true
		NotificationCenter.default.addObserver(
			context.coordinator,
			selector: #selector(context.coordinator.scrollViewDidScroll(_:)),
			name: NSView.boundsDidChangeNotification,
			object: scrollView.contentView
		)
		scrollView.hasHorizontalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.borderType = .bezelBorder
		scrollView.translatesAutoresizingMaskIntoConstraints = false
		
		// Performance optimizations for large content
		scrollView.scrollerKnobStyle = .light
		scrollView.verticalScrollElasticity = .allowed
		scrollView.horizontalScrollElasticity = .none
		
		// Optimize text container for better performance
		if let container = textView.textContainer {
			container.lineFragmentPadding = 0
			container.maximumNumberOfLines = 0
		}
		return scrollView
	}

	public func updateNSView(_ scrollView: NSScrollView, context: Context) {
		guard let textView = scrollView.documentView as? NSTextView else { return }
		if textView.string != html {
			// Update coordinator's tracking
			context.coordinator.previousText = html
			context.coordinator.highlightedRanges.removeAll()
			context.coordinator.highlightedRanges.insert(NSRange(location: 0, length: html.count))
			
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
		// Removed range-based highlighting, now using visible area only
		private var isUpdatingFromHighlighting = false
		var previousText = ""
		private var visibleHighlightingTimer: Timer?
		private var lastVisibleRange = NSRange(location: 0, length: 0)
		var highlightedRanges = Set<NSRange>()

		init(_ parent: HTMLEditor) {
			self.parent = parent
			super.init()
		}

		public func textDidChange(_ notification: Notification) {
			guard !isUpdatingFromHighlighting,
				  let textView = notification.object as? NSTextView else { return }
			
			let newText = textView.string
			if parent.html != newText {
				let oldLength = previousText.count
				let newLength = newText.count
				
				previousText = newText
				parent.html = newText
				
				// For major changes (paste, large inserts), clear all highlighted ranges
				let isMajorChange = abs(newLength - oldLength) > 50 || oldLength == 0
				if isMajorChange {
					highlightedRanges.removeAll()
				}
				
				// Always highlight visible area on text changes (force highlighting for edits)
				guard let scrollView = textView.enclosingScrollView else { return }
				scheduleVisibleRangeHighlighting(textView: textView, scrollView: scrollView, forceHighlight: true)
			}
		}
		
		// Removed complex change range calculation - now using visible area highlighting
		
		// Removed range-based scheduling - now using visible area only
		
		// Removed incremental highlighting - now using visible area highlighting for all changes
		
		@MainActor
		private func performFullHighlighting(html: String, theme: HTMLEditorColorScheme, textView: NSTextView) {
			guard let scrollView = textView.enclosingScrollView else { return }
			
			// Save cursor position and scroll state for full replacement
			let selectedRange = textView.selectedRange()
			let visibleRect = scrollView.documentVisibleRect
			
			// Perform highlighting on background queue
			DispatchQueue.global(qos: .userInitiated).async { [weak self] in
				let highlighted = HTMLSyntaxHighlighter.highlight(html: html, theme: theme)
				
				Task { @MainActor [weak self] in
					guard let self = self else { return }
					
					// Prevent recursive updates
					self.isUpdatingFromHighlighting = true
					
					// Apply full highlighting replacement
					textView.textStorage?.beginEditing()
					textView.textStorage?.setAttributedString(highlighted)
					textView.textStorage?.endEditing()
					
					// Restore selection with bounds checking
					let maxLocation = textView.string.count
					let clampedLocation = min(selectedRange.location, maxLocation)
					let clampedLength = min(selectedRange.length, maxLocation - clampedLocation)
					textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
					
					// Restore scroll position without animation
					CATransaction.begin()
					CATransaction.setDisableActions(true)
					scrollView.contentView.setBoundsOrigin(visibleRect.origin)
					scrollView.reflectScrolledClipView(scrollView.contentView)
					CATransaction.commit()
					
					self.isUpdatingFromHighlighting = false
				}
			}
		}

		// Appearance change handler
		@MainActor
		func systemAppearanceChanged(textView: NSTextView) {
			let currentTheme = parent.theme.current(for: NSApp.effectiveAppearance)
			textView.font = currentTheme.font
			textView.backgroundColor = currentTheme.background
			textView.textColor = currentTheme.foreground
			
			// Apply highlighting immediately for appearance changes
			Task { @MainActor in
				performFullHighlighting(html: parent.html, theme: currentTheme, textView: textView)
			}
		}
		
		// MARK: - Scroll Detection
		@MainActor
		@objc func scrollViewDidScroll(_ notification: Notification) {
			guard let clipView = notification.object as? NSClipView,
				  let scrollView = clipView.enclosingScrollView,
				  let textView = scrollView.documentView as? NSTextView else { return }
			scheduleVisibleRangeHighlighting(textView: textView, scrollView: scrollView)
		}
		
		private func scheduleVisibleRangeHighlighting(textView: NSTextView, scrollView: NSScrollView, forceHighlight: Bool = false) {
			visibleHighlightingTimer?.invalidate()
			
			visibleHighlightingTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { [weak self, weak textView, weak scrollView] _ in
				guard let self = self,
					  let textView = textView,
					  let scrollView = scrollView else { return }
				
				Task { @MainActor in
					self.highlightVisibleRange(textView: textView, scrollView: scrollView, forceHighlight: forceHighlight)
				}
			}
		}
		
		@MainActor
		private func highlightVisibleRange(textView: NSTextView, scrollView: NSScrollView, forceHighlight: Bool = false) {
			guard let textStorage = textView.textStorage else { return }
			
			// Early return for empty text to prevent crashes
			if textStorage.length == 0 {
				return
			}
			
			// Calculate visible range using layout manager
			let visibleRect = scrollView.documentVisibleRect
			guard let layoutManager = textView.layoutManager,
				  let textContainer = textView.textContainer else { return }
			
			let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
			let visibleRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
			
			// Validate the visible range
			guard visibleRange.location != NSNotFound && 
				  visibleRange.location < textStorage.length &&
				  visibleRange.location + visibleRange.length <= textStorage.length else {
				return
			}
			
			// Skip if visible range hasn't changed significantly (unless forced)
			if !forceHighlight && 
			   abs(visibleRange.location - lastVisibleRange.location) < 100 &&
			   abs(visibleRange.length - lastVisibleRange.length) < 100 {
				return
			}
			
			lastVisibleRange = visibleRange
			
			// Check if this range is already highlighted (unless forced)
			let needsHighlighting = forceHighlight || !highlightedRanges.contains { highlightedRange in
				NSIntersectionRange(visibleRange, highlightedRange).length > Int(Double(visibleRange.length) * 0.8)
			}
			
			if needsHighlighting {
				// Expand visible range slightly for smoother scrolling
				let expandedStart = max(0, visibleRange.location - 200)
				let expandedEnd = min(textStorage.length, visibleRange.location + visibleRange.length + 200)
				let expandedRange = NSRange(location: expandedStart, length: expandedEnd - expandedStart)
				
				// Perform highlighting
				let currentTheme = parent.theme.current(for: NSApp.effectiveAppearance)
				performVisibleRangeHighlighting(range: expandedRange, theme: currentTheme, textStorage: textStorage)
				
				// Track highlighted range
				highlightedRanges.insert(expandedRange)
				
				// Limit tracked ranges to prevent memory growth
				if highlightedRanges.count > 10 {
					highlightedRanges.removeFirst()
				}
			}
		}
		
		private func performVisibleRangeHighlighting(range: NSRange, theme: HTMLEditorColorScheme, textStorage: NSTextStorage) {
			DispatchQueue.global(qos: .userInitiated).async {
				Task { @MainActor in
					// Prevent recursive updates during visible range highlighting
					self.isUpdatingFromHighlighting = true
					
					textStorage.beginEditing()
					
					var expandedRange = NSRange()
					HTMLSyntaxHighlighter.highlightRange(
						in: textStorage,
						range: range,
						theme: theme,
						expandedRange: &expandedRange
					)
					
					textStorage.endEditing()
					
					self.isUpdatingFromHighlighting = false
				}
			}
		}
		
		deinit {
			visibleHighlightingTimer?.invalidate()
			NotificationCenter.default.removeObserver(self)
		}
	}
}
#endif
