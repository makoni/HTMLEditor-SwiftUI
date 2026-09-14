//
//  HTMLEditorPlatform.swift
//  HTMLEditor-SwiftUI
//
//  The handful of types that differ between AppKit and UIKit.
//

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Platform spellings for the few types this package cannot avoid naming.
///
/// A namespace rather than top-level aliases: the package would otherwise
/// export `PlatformColor` and friends into every file that imports it, and
/// those are poor names to put in someone else's scope.
///
/// Deliberately **not** a protocol over the text view. `NSTextViewDelegate` and
/// `UITextViewDelegate` are different protocols with different method names,
/// appearance arrives through different channels, and scroll ownership differs
/// — a protocol would end up half no-ops on each platform, which is the thing
/// it would exist to avoid.
public enum HTMLEditorPlatform {
	#if os(macOS)
	public typealias Colour = NSColor
	public typealias Font = NSFont
	public typealias TextView = NSTextView
	#else
	public typealias Colour = UIColor
	public typealias Font = UIFont
	public typealias TextView = UITextView
	#endif
}

/// Which of the two colour schemes a theme should hand back.
///
/// Its own type rather than `NSAppearance` / `UIUserInterfaceStyle`, so
/// `HTMLEditorTheme.current(for:)` has one signature on every platform. It also
/// removes a macOS bug in passing: the editor used to resolve the theme from
/// `NSApp.effectiveAppearance` — the *application's* appearance — while
/// reacting to `viewDidChangeEffectiveAppearance`, which fires for the
/// **view's**. Inside a container with its own appearance the two disagree.
public enum HTMLEditorAppearance: Sendable {
	case light
	case dark

	#if os(macOS)
	/// Resolved from a view, never from `NSApp`.
	public static func resolve(from appearance: NSAppearance) -> HTMLEditorAppearance {
		let match = appearance.bestMatch(from: [.aqua, .darkAqua])
		return match == .darkAqua ? .dark : .light
	}
	#else
	public static func resolve(from traits: UITraitCollection) -> HTMLEditorAppearance {
		traits.userInterfaceStyle == .dark ? .dark : .light
	}
	#endif
}

extension HTMLEditorPlatform.Font {
	static var htmlEditorDefault: HTMLEditorPlatform.Font {
		#if os(macOS)
		NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
		#else
		UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
		#endif
	}
}

extension HTMLEditorPlatform.TextView {
	/// The document, as a plain string.
	///
	/// `NSTextView.string` and `UITextView.text` name the same lazy accessor;
	/// both are cheap (~0.2 µs). **Never** reach for `attributedText` on iOS:
	/// assigning it costs 5.4× more on a 1.7 MB document (8.01 ms against
	/// 1.49 ms), and handing over a *highlighted* attributed string would write
	/// the colours into the storage as real attributes instead of vending them
	/// per paragraph — which breaks undo and can re-enter `textDidChange`.
	var htmlEditorText: String {
		get {
			#if os(macOS)
			return string
			#else
			return text ?? ""
			#endif
		}
		set {
			#if os(macOS)
			string = newValue
			#else
			text = newValue
			#endif
		}
	}

	/// `NSTextView.textContainer` is optional, `UITextView`'s is not — this
	/// hands back the optional spelling on both so call sites do not fork.
	var htmlEditorTextContainer: NSTextContainer? {
		#if os(macOS)
		return textContainer
		#else
		return Optional(textContainer)
		#endif
	}
}
