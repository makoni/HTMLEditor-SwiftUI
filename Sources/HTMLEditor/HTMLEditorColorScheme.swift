//
//  HTMLEditorColorScheme.swift
//  HTMLEditor-SwiftUI
//
//  Created by Sergei Armodin on 07.07.2025.
//

#if os(macOS)
import AppKit

public struct HTMLEditorColorScheme {
    public init(foreground: NSColor, background: NSColor, tag: NSColor, attributeName: NSColor, attributeValue: NSColor, font: NSFont) {
        self.foreground = foreground
        self.background = background
        self.tag = tag
        self.attributeName = attributeName
        self.attributeValue = attributeValue
        self.font = font
    }
    
	public let foreground: NSColor
	public let background: NSColor
	public let tag: NSColor
	public let attributeName: NSColor
	public let attributeValue: NSColor
	public let font: NSFont
}
#endif
