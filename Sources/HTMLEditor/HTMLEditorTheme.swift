//
//  HTMLEditorTheme.swift
//  HTMLEditor-SwiftUI
//
//  Created by Sergei Armodin on 07.07.2025.
//

import Foundation

// MARK: - Theme & ColorScheme
/// Deliberately not `@MainActor`: the type is two immutable colour schemes and
/// a pure lookup, and isolating it forced `.default` — the default argument of
/// `HTMLEditor.init` — onto the main actor for no benefit.
public struct HTMLEditorTheme: Sendable {
    public init(light: HTMLEditorColorScheme, dark: HTMLEditorColorScheme) {
        self.light = light
        self.dark = dark
    }

    public let light: HTMLEditorColorScheme
    public let dark: HTMLEditorColorScheme

    public static let `default` = HTMLEditorTheme(
        light: HTMLEditorColorScheme(
            foreground: .htmlEditorBlack,
            background: .htmlEditorWhite,
            tag: HTMLEditorPlatform.Colour(red: 0.50, green: 0.09, blue: 0.56, alpha: 1.0),
            attributeName: HTMLEditorPlatform.Colour(red: 0.80, green: 0.38, blue: 0.00, alpha: 1.0),
            attributeValue: HTMLEditorPlatform.Colour(red: 0.00, green: 0.34, blue: 0.60, alpha: 1.0),
            font: .htmlEditorDefault
        ),
        dark: HTMLEditorColorScheme(
            foreground: HTMLEditorPlatform.Colour(red: 0.78, green: 0.83, blue: 0.89, alpha: 1.0),
            background: HTMLEditorPlatform.Colour(red: 0.16, green: 0.18, blue: 0.20, alpha: 1.0),
            tag: HTMLEditorPlatform.Colour(red: 0.86, green: 0.58, blue: 0.98, alpha: 1.0),
            attributeName: HTMLEditorPlatform.Colour(red: 0.97, green: 0.75, blue: 0.49, alpha: 1.0),
            attributeValue: HTMLEditorPlatform.Colour(red: 0.49, green: 0.84, blue: 0.98, alpha: 1.0),
            font: .htmlEditorDefault
        )
    )

    /// One signature on every platform — see ``HTMLEditorAppearance``.
    public func current(for appearance: HTMLEditorAppearance) -> HTMLEditorColorScheme {
        appearance == .dark ? dark : light
    }
}

extension HTMLEditorPlatform.Colour {
    static var htmlEditorBlack: HTMLEditorPlatform.Colour {
        HTMLEditorPlatform.Colour(red: 0, green: 0, blue: 0, alpha: 1)
    }

    static var htmlEditorWhite: HTMLEditorPlatform.Colour {
        HTMLEditorPlatform.Colour(red: 1, green: 1, blue: 1, alpha: 1)
    }
}
