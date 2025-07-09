//
//  HTMLEditorView.swift
//  HTMLEditor-Demo
//
//  Created by Sergei Armodin on 10.07.2025.
//

import SwiftUI
import HTMLEditor

struct HTMLEditorDemoView: View {
    @Binding var html: String

    private let customTheme = HTMLEditorTheme(
        light: HTMLEditorColorScheme(
            foreground: NSColor.blue,
            background: NSColor.yellow,
            tag: NSColor.purple,
            attributeName: NSColor.orange,
            attributeValue: NSColor.green,
            font: NSFont.monospacedSystemFont(ofSize: 16, weight: .bold)
        ),
        dark: HTMLEditorColorScheme(
            foreground: NSColor.white,
            background: NSColor.black,
            tag: NSColor.red,
            attributeName: NSColor.cyan,
            attributeValue: NSColor.magenta,
            font: NSFont.monospacedSystemFont(ofSize: 16, weight: .bold)
        )
    )

    var body: some View {
        VStack {
            Text("HTML Editor Demo")
                .font(.title)
                .padding()

            HTMLEditor(html: $html)
                .frame(minWidth: 400, minHeight: 300)
                .padding()

            /*
             // A custom theme example
             HTMLEditor(html: $html, theme: customTheme)
                 .frame(minWidth: 400, minHeight: 300)
                 .padding()
             */
        }
    }
}
