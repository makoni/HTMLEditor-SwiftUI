//
//  HTMLEditor_DemoApp.swift
//  HTMLEditor-Demo
//
//  Created by Sergei Armodin on 10.07.2025.
//

import SwiftUI

@main
struct HTMLEditorDemoApp: App {
    @State private var htmlContent: String = """
    <h1>Welcome to <b>HTMLEditor</b></h1>
        
    <p>
        This is a <u>simple</u> SwiftUI view text editor with <b>HTML</b> highlighting.
    </p>
    
    <p>
        It supports dark and light mode with automatic adjusting. And you can provide your own color theme.
    </p>
    
    <p style="text-align: center;">
        <img src="/images/smile.webp" alt="smile">
        I hope you'll like it.
    </p>
    """

    var body: some Scene {
        WindowGroup {
            HTMLEditorView(html: $htmlContent)
        }
    }
}
