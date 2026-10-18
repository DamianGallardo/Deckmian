//
//  NotesView.swift
//  boringNotch
//
//  Created by Deckmian on 2026-10-15.
//

import SwiftUI

struct NotesView: View {
    @ObservedObject var store = NotesStore.shared
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $store.text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .notchTextInput(isFocused: $isEditorFocused)

            if store.text.isEmpty {
                Text("Write something…")
                    .font(.system(size: 13))
                    .foregroundStyle(.gray)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isEditorFocused ? Color.effectiveAccent.opacity(0.6) : Color.white.opacity(0.1),
                    lineWidth: 1
                )
        }
    }
}
