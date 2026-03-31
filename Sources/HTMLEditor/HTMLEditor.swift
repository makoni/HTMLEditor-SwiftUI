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
		if html.utf16.count <= HTMLSyntaxHighlighter.maxHighlightLength {
			textView.textStorage?.setAttributedString(HTMLSyntaxHighlighter.highlight(html: html, theme: currentTheme))
		}
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
		if context.coordinator.shouldApplyExternalUpdate(incomingHTML: html, currentText: textView.string) {
			let currentTheme = theme.current(for: NSApp.effectiveAppearance)
			context.coordinator.scheduleExternalHighlightUpdate(html: html, theme: currentTheme, textView: textView)
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

	public class Coordinator: NSObject, NSTextViewDelegate, @unchecked Sendable {
		var parent: HTMLEditor
		// Removed range-based highlighting, now using visible area only
		private var isUpdatingFromHighlighting = false
		var previousText = ""
		private var visibleHighlightDebounceTask: Task<Void, Never>?
		private var visibleHighlightTask: Task<Void, Never>?
		private var prewarmTask: Task<Void, Never>?
		private var fullHighlightTask: Task<Void, Never>?
		private var documentVersion: Int = 0
		private var pendingLocalBindingSyncHTML: String?
		private var cachedFullHighlightPlan: HTMLSyntaxHighlighter.HighlightPlan?
		private var cachedFullHighlightVersion: Int?
		private var lastVisibleRange = NSRange(location: 0, length: 0)
		var highlightedRanges: [NSRange] = []

		init(_ parent: HTMLEditor) {
			self.parent = parent
			super.init()
		}

		@MainActor
		func scheduleExternalHighlightUpdate(html: String, theme: HTMLEditorColorScheme, textView: NSTextView) {
			previousText = html
			pendingLocalBindingSyncHTML = nil
			documentVersion &+= 1
			lastVisibleRange = NSRange(location: 0, length: 0)
			highlightedRanges.removeAll()
			highlightedRanges.append(NSRange(location: 0, length: html.utf16.count))
			cachedFullHighlightPlan = nil
			cachedFullHighlightVersion = nil
			visibleHighlightTask?.cancel()
			prewarmTask?.cancel()
			performFullHighlighting(html: html, theme: theme, textView: textView)
		}

		@MainActor
		func shouldApplyExternalUpdate(incomingHTML: String, currentText: String) -> Bool {
			if let pendingLocalBindingSyncHTML {
				if incomingHTML == pendingLocalBindingSyncHTML {
					self.pendingLocalBindingSyncHTML = nil
					return false
				}

				// Ignore stale SwiftUI binding snapshots while local edits are still propagating.
				return false
			}

			return currentText != incomingHTML
		}

		public func textDidChange(_ notification: Notification) {
			guard !isUpdatingFromHighlighting,
				  let textView = notification.object as? NSTextView else { return }
			
			let newText = textView.string
			if parent.html != newText {
				let oldLength = previousText.utf16.count
				let newLength = newText.utf16.count
				
				previousText = newText
				pendingLocalBindingSyncHTML = newText
				parent.html = newText
				documentVersion &+= 1
				cachedFullHighlightPlan = nil
				cachedFullHighlightVersion = nil
				fullHighlightTask?.cancel()
				prewarmTask?.cancel()
				
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
			
			let currentVersion = documentVersion
			fullHighlightTask?.cancel()

			if html.utf16.count > 50_000 {
				cachedFullHighlightPlan = nil
				cachedFullHighlightVersion = nil
				applyPlainTextResult(html: html, to: textView, in: scrollView)
				return
			}
			
			fullHighlightTask = Task { [weak self, weak textView, weak scrollView] in
				guard let self else { return }
				let plan = await HTMLSyntaxHighlighter.plannedFullHighlight(html: html)
				guard !Task.isCancelled else { return }

				await MainActor.run {
					guard let textView,
						  let scrollView,
						  self.documentVersion == currentVersion else { return }
					self.cachedFullHighlightPlan = plan
					self.cachedFullHighlightVersion = currentVersion
					let highlighted = HTMLSyntaxHighlighter.attributedString(html: html, theme: theme, plan: plan)
					self.applyFullHighlightResult(highlighted, to: textView, in: scrollView)
				}
			}
		}

		@MainActor
		private func applyFullHighlightResult(
			_ highlighted: NSAttributedString,
			to textView: NSTextView,
			in scrollView: NSScrollView
		) {
			let selectedRange = textView.selectedRange()
			let visibleRect = scrollView.documentVisibleRect

			// Prevent recursive updates
			isUpdatingFromHighlighting = true
			
			textView.textStorage?.beginEditing()
			textView.textStorage?.setAttributedString(highlighted)
			textView.textStorage?.endEditing()
			
			// Restore selection with bounds checking
			let maxLocation = textView.string.utf16.count
			let clampedLocation = min(selectedRange.location, maxLocation)
			let clampedLength = min(selectedRange.length, maxLocation - clampedLocation)
			textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
			
			// Restore scroll position without animation
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			scrollView.contentView.setBoundsOrigin(visibleRect.origin)
			scrollView.reflectScrolledClipView(scrollView.contentView)
			CATransaction.commit()
			
			isUpdatingFromHighlighting = false
		}

		@MainActor
		private func applyPlainTextResult(html: String, to textView: NSTextView, in scrollView: NSScrollView) {
			let selectedRange = textView.selectedRange()
			let visibleRect = scrollView.documentVisibleRect

			isUpdatingFromHighlighting = true

			if let layoutManager = textView.layoutManager {
				HTMLSyntaxHighlighter.clearTemporaryHighlights(
					in: layoutManager,
					range: NSRange(location: 0, length: textView.string.utf16.count)
				)
			}

			textView.string = html

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

		// Appearance change handler
		@MainActor
		func systemAppearanceChanged(textView: NSTextView) {
			let currentTheme = parent.theme.current(for: NSApp.effectiveAppearance)
			textView.font = currentTheme.font
			textView.backgroundColor = currentTheme.background
			textView.textColor = currentTheme.foreground
			
			if let cachedFullHighlightPlan,
			   cachedFullHighlightVersion == documentVersion,
			   let scrollView = textView.enclosingScrollView {
				let highlighted = HTMLSyntaxHighlighter.attributedString(html: parent.html, theme: currentTheme, plan: cachedFullHighlightPlan)
				applyFullHighlightResult(highlighted, to: textView, in: scrollView)
			} else {
				// Apply highlighting immediately for appearance changes
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
		
		@MainActor
		private func scheduleVisibleRangeHighlighting(textView: NSTextView, scrollView: NSScrollView, forceHighlight: Bool = false) {
			visibleHighlightDebounceTask?.cancel()

			visibleHighlightDebounceTask = Task { @MainActor [weak self, weak textView, weak scrollView] in
				do {
					try await Task.sleep(nanoseconds: 10_000_000) // 0.01 s
				} catch {
					return // Task was cancelled — a newer schedule superseded this one
				}
				guard let self, let textView, let scrollView else { return }
				let visibleRect = scrollView.documentVisibleRect
				guard let layoutManager = textView.layoutManager,
					  let textContainer = textView.textContainer,
					  let textStorage = textView.textStorage else { return }

				let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
				let visibleRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
				self.highlightVisibleRange(
					textView: textView,
					scrollView: scrollView,
					textStorage: textStorage,
					visibleRange: visibleRange,
					forceHighlight: forceHighlight
				)
			}
		}
		
		@MainActor
		private func highlightVisibleRange(
			textView: NSTextView,
			scrollView: NSScrollView,
			textStorage: NSTextStorage,
			visibleRange: NSRange,
			forceHighlight: Bool = false
		) {
			// Early return for empty text to prevent crashes
			if textStorage.length == 0 {
				return
			}

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
			let needsHighlighting = rangeNeedsHighlighting(visibleRange, forceHighlight: forceHighlight)
			
			if needsHighlighting {
				// Expand visible range slightly for smoother scrolling
				let expandedStart = max(0, visibleRange.location - 200)
				let expandedEnd = min(textStorage.length, visibleRange.location + visibleRange.length + 200)
				let expandedRange = NSRange(location: expandedStart, length: expandedEnd - expandedStart)
				let currentTheme = parent.theme.current(for: NSApp.effectiveAppearance)
				let textSnapshot = textStorage.string
				let currentVersion = documentVersion

				visibleHighlightTask?.cancel()
				visibleHighlightTask = Task { [weak self, weak textView] in
					guard let self else { return }
					let plan = await HTMLSyntaxHighlighter.plannedRangeHighlight(text: textSnapshot, requestedRange: expandedRange)
					guard !Task.isCancelled else { return }

					await MainActor.run {
						guard let textView,
							  let currentTextStorage = textView.textStorage,
							  self.documentVersion == currentVersion,
							  currentTextStorage.string == textSnapshot else { return }
						self.performVisibleRangeHighlighting(plan: plan, theme: currentTheme, textStorage: currentTextStorage)
						self.recordHighlightedRange(plan.coveredRange)
						if !forceHighlight {
							self.scheduleViewportPrewarm(
								around: visibleRange,
								textSnapshot: textSnapshot,
								theme: currentTheme,
								version: currentVersion,
								textView: textView
							)
						}
					}
				}
			}
		}
		
		@MainActor
		private func performVisibleRangeHighlighting(plan: HTMLSyntaxHighlighter.HighlightPlan, theme: HTMLEditorColorScheme, textStorage: NSTextStorage) {
			// Prevent recursive updates during visible range highlighting
			isUpdatingFromHighlighting = true

			if let layoutManager = textStorage.layoutManagers.first {
				HTMLSyntaxHighlighter.applyTemporary(plan: plan, to: layoutManager, theme: theme)
			} else {
				textStorage.beginEditing()
				HTMLSyntaxHighlighter.apply(plan: plan, to: textStorage, theme: theme)
				textStorage.endEditing()
			}
			
			isUpdatingFromHighlighting = false
		}

		@MainActor
		private func recordHighlightedRange(_ range: NSRange) {
			guard range.location != NSNotFound, range.length > 0 else { return }

			var mergedRange = range
			var retainedRanges: [NSRange] = []
			retainedRanges.reserveCapacity(highlightedRanges.count + 1)

			for existingRange in highlightedRanges {
				if shouldMerge(existingRange, with: mergedRange) {
					mergedRange = union(of: existingRange, and: mergedRange)
				} else {
					retainedRanges.append(existingRange)
				}
			}

			retainedRanges.append(mergedRange)
			if retainedRanges.count > 10 {
				retainedRanges.removeFirst(retainedRanges.count - 10)
			}

			highlightedRanges = retainedRanges
		}

		@MainActor
		private func rangeNeedsHighlighting(_ range: NSRange, forceHighlight: Bool = false) -> Bool {
			forceHighlight || !highlightedRanges.contains { highlightedRange in
				NSIntersectionRange(range, highlightedRange).length > Int(Double(range.length) * 0.8)
			}
		}

		@MainActor
		private func scheduleViewportPrewarm(
			around visibleRange: NSRange,
			textSnapshot: String,
			theme: HTMLEditorColorScheme,
			version: Int,
			textView: NSTextView
		) {
			prewarmTask?.cancel()

			let beforeRange = NSRange(location: max(0, visibleRange.location - visibleRange.length), length: visibleRange.length)
			let afterStart = NSMaxRange(visibleRange)
			let maxLength = textSnapshot.utf16.count
			let afterRange = NSRange(
				location: min(afterStart, maxLength),
				length: min(visibleRange.length, max(0, maxLength - min(afterStart, maxLength)))
			)

			let candidates = [beforeRange, afterRange].filter {
				$0.location != NSNotFound && $0.length > 0 && rangeNeedsHighlighting($0)
			}
			guard !candidates.isEmpty else { return }

			prewarmTask = Task { [weak self, weak textView] in
				guard let self else { return }

				do {
					try await Task.sleep(nanoseconds: 75_000_000)
				} catch {
					return
				}

				for candidate in candidates {
					guard !Task.isCancelled else { return }
					let plan = await HTMLSyntaxHighlighter.plannedRangeHighlight(text: textSnapshot, requestedRange: candidate)
					guard !Task.isCancelled else { return }

					await MainActor.run {
						guard let textView,
							  let currentTextStorage = textView.textStorage,
							  self.documentVersion == version,
							  currentTextStorage.string == textSnapshot,
							  self.rangeNeedsHighlighting(plan.coveredRange) else { return }
						self.performVisibleRangeHighlighting(plan: plan, theme: theme, textStorage: currentTextStorage)
						self.recordHighlightedRange(plan.coveredRange)
					}
				}
			}
		}

		@MainActor
		private func shouldMerge(_ lhs: NSRange, with rhs: NSRange) -> Bool {
			if NSIntersectionRange(lhs, rhs).length > 0 {
				return true
			}

			let lhsEnd = NSMaxRange(lhs)
			let rhsEnd = NSMaxRange(rhs)
			return abs(lhsEnd - rhs.location) <= 1 || abs(rhsEnd - lhs.location) <= 1
		}

		@MainActor
		private func union(of lhs: NSRange, and rhs: NSRange) -> NSRange {
			let start = min(lhs.location, rhs.location)
			let end = max(NSMaxRange(lhs), NSMaxRange(rhs))
			return NSRange(location: start, length: end - start)
		}
		
		deinit {
			visibleHighlightDebounceTask?.cancel()
			visibleHighlightTask?.cancel()
			prewarmTask?.cancel()
			fullHighlightTask?.cancel()
			NotificationCenter.default.removeObserver(self)
		}
	}
}
#endif
