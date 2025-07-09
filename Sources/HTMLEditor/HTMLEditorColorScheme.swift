//
//  HTMLEditorColorScheme.swift
//  HTMLEditor-SwiftUI
//
//  Created by Sergei Armodin on 07.07.2025.
//

#if os(macOS)
import AppKit

public struct HTMLEditorColorScheme {
	public let foreground: NSColor
	public let background: NSColor
	public let tag: NSColor
	public let attributeName: NSColor
	public let attributeValue: NSColor
	public let font: NSFont
}
#endif
