//
//  HTMLEditorTheme.swift
//  HTMLEditor-SwiftUI
//
//  Created by Sergei Armodin on 07.07.2025.
//

#if os(macOS)
import AppKit

// MARK: - Theme & ColorScheme
@MainActor
public struct HTMLEditorTheme: Sendable {
    public init(light: HTMLEditorColorScheme, dark: HTMLEditorColorScheme) {
        self.light = light
        self.dark = dark
    }
    
	public let light: HTMLEditorColorScheme
	public let dark: HTMLEditorColorScheme

    public static let `default` = HTMLEditorTheme(
		light: HTMLEditorColorScheme(
			foreground: NSColor.black,
			background: NSColor.white,
			tag: NSColor(red: 0.50, green: 0.09, blue: 0.56, alpha: 1.0),
			attributeName: NSColor(red: 0.80, green: 0.38, blue: 0.00, alpha: 1.0),
			attributeValue: NSColor(red: 0.00, green: 0.34, blue: 0.60, alpha: 1.0),
			font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
		),
		dark: HTMLEditorColorScheme(
			foreground: NSColor(red: 0.78, green: 0.83, blue: 0.89, alpha: 1.0),
			background: NSColor(red: 0.16, green: 0.18, blue: 0.20, alpha: 1.0),
			tag: NSColor(red: 0.86, green: 0.58, blue: 0.98, alpha: 1.0),
			attributeName: NSColor(red: 0.97, green: 0.75, blue: 0.49, alpha: 1.0),
			attributeValue: NSColor(red: 0.49, green: 0.84, blue: 0.98, alpha: 1.0),
			font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
		)
	)

	public func current(for appearance: NSAppearance) -> HTMLEditorColorScheme {
		appearance.name == .darkAqua ? dark : light
	}
}
#endif
