//
//  HTMLEditorView.swift
//  HTMLEditor-Demo
//
//  Created by Sergei Armodin on 10.07.2025.
//

import SwiftUI
import HTMLEditor

struct HTMLEditorView: View {
    @Binding var html: String

    var body: some View {
        VStack {
            Text("HTML Editor Demo")
                .font(.title)
                .padding()

            HTMLEditor(html: $html)
                .frame(minWidth: 400, minHeight: 300)
                .padding()
        }
    }
}
