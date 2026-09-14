//
//  HTMLEditorColorScheme.swift
//  HTMLEditor-SwiftUI
//
//  Created by Sergei Armodin on 07.07.2025.
//

import Foundation

/// One resolved set of colours plus the editor font.
///
/// Stores platform colours rather than SwiftUI `Color`: `colour(for:theme:)` is
/// called once per highlight span inside `styledParagraph`, so resolving a
/// `Color` there would put a conversion on the hot path.
public struct HTMLEditorColorScheme: Equatable, @unchecked Sendable {
    public init(
        foreground: HTMLEditorPlatform.Colour,
        background: HTMLEditorPlatform.Colour,
        tag: HTMLEditorPlatform.Colour,
        attributeName: HTMLEditorPlatform.Colour,
        attributeValue: HTMLEditorPlatform.Colour,
        font: HTMLEditorPlatform.Font
    ) {
        self.foreground = foreground
        self.background = background
        self.tag = tag
        self.attributeName = attributeName
        self.attributeValue = attributeValue
        self.font = font
    }

    public let foreground: HTMLEditorPlatform.Colour
    public let background: HTMLEditorPlatform.Colour
    public let tag: HTMLEditorPlatform.Colour
    public let attributeName: HTMLEditorPlatform.Colour
    public let attributeValue: HTMLEditorPlatform.Colour
    public let font: HTMLEditorPlatform.Font
}
