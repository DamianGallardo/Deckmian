//
//  TodosView.swift
//  Deckmian
//
//  Created by Deckmian on 2026-10-15.
//

import SwiftUI

struct TodosView: View {
    @ObservedObject var store = TodosStore.shared
    @FocusState private var isFieldFocused: Bool
    @State private var draft = ""

    /// Pending items first, then completed ones, each keeping their insertion order.
    private var sortedItems: [TodoItem] {
        store.items.filter { !$0.isDone } + store.items.filter(\.isDone)
    }

    private var remainingCount: Int {
        store.items.lazy.filter { !$0.isDone }.count
    }

    private var hasCompleted: Bool {
        store.items.contains(where: \.isDone)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)

            if store.items.isEmpty {
                Text("Nothing to do")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.gray.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
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
                    isFieldFocused ? Color.effectiveAccent.opacity(0.6) : Color.white.opacity(0.1),
                    lineWidth: 1
                )
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.gray)

            TextField("Add a to-do…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .notchTextInput(isFocused: $isFieldFocused)
                .onSubmit(addDraft)

            if !store.items.isEmpty {
                Text("\(remainingCount) left")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.gray)
            }

            if hasCompleted {
                Button("Clear completed") {
                    withAnimation(.smooth) {
                        store.clearCompleted()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.effectiveAccent)
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(sortedItems) { item in
                    TodoRow(
                        item: item,
                        onToggle: {
                            withAnimation(.smooth) { store.toggle(item.id) }
                        },
                        onDelete: {
                            withAnimation(.smooth) { store.remove(item.id) }
                        }
                    )
                }
            }
        }
        .scrollIndicators(.never)
    }

    // MARK: - Actions

    private func addDraft() {
        withAnimation(.smooth) {
            store.add(draft)
        }
        draft = ""
        // Keep the field focused for quick successive entries
        isFieldFocused = true
    }
}

private struct TodoRow: View {
    let item: TodoItem
    let onToggle: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(item.isDone ? Color.effectiveAccent : Color.gray)
            }
            .buttonStyle(.plain)

            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(item.isDone ? Color.gray : Color.white)
                .strikethrough(item.isDone, color: .gray)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.gray)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(isHovering ? 0.05 : 0))
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
