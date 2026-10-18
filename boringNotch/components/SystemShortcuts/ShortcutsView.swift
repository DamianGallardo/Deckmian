//
//  ShortcutsView.swift
//  boringNotch
//
//  Created by Deckmian on 2026-10-15.
//

import SwiftUI

struct ShortcutsView: View {
    @ObservedObject var store = ShortcutsStore.shared

    private static let tileSize = CGSize(width: 128, height: 50)
    private static let gridSpacing: CGFloat = 8

    private var rows: [GridItem] {
        Array(repeating: GridItem(.fixed(Self.tileSize.height), spacing: Self.gridSpacing), count: 2)
    }

    var body: some View {
        Group {
            if store.pinned.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        }
        .onAppear {
            store.refresh()
        }
    }

    // MARK: - Subviews

    private var grid: some View {
        ScrollView(.horizontal) {
            LazyHGrid(rows: rows, spacing: Self.gridSpacing) {
                ForEach(store.pinned) { shortcut in
                    ShortcutTile(
                        shortcut: shortcut,
                        state: store.runStates[shortcut.id],
                        size: Self.tileSize
                    ) {
                        store.run(shortcut)
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(store.isLoading && !store.pinnedIDs.isEmpty ? "Loading shortcuts…" : "No shortcuts selected")
                .font(.system(size: 12))
                .foregroundStyle(Color.gray.opacity(0.7))

            Button {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow(page: SystemShortcutsSettings.pageID)
                }
            } label: {
                Text("Choose Shortcuts…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background {
                        Capsule()
                            .fill(Color.effectiveAccent.opacity(0.35))
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ShortcutTile: View {
    let shortcut: ShortcutInfo
    let state: ShortcutsStore.RunState?
    let size: CGSize
    let action: () -> Void
    @State private var isHovering = false

    /// Symbols assigned deterministically per shortcut so each tile keeps the same icon across launches.
    private static let symbols = [
        "bolt.fill", "sparkles", "wand.and.stars", "paperplane.fill", "star.fill",
        "flame.fill", "leaf.fill", "moon.fill", "command", "wand.and.rays"
    ]

    private var symbol: String {
        // `hashValue` is seeded per launch, so derive a stable index from the scalars instead
        let seed = shortcut.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        return Self.symbols[seed % Self.symbols.count]
    }

    private var isRunning: Bool {
        state == .running
    }

    private var helpText: String {
        if case .failed(let message) = state {
            return "\(shortcut.name) failed: \(message)"
        }
        return "Run \(shortcut.name)"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                badge
                    .frame(width: 28, height: 28)

                Text(shortcut.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(width: size.width, height: size.height)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(isHovering && !isRunning ? 0.1 : 0.06))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .help(helpText)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.smooth, value: state)
    }

    private var borderColor: Color {
        switch state {
        case .running: Color.effectiveAccent.opacity(0.6)
        case .failed: Color.orange.opacity(0.6)
        default: Color.white.opacity(0.1)
        }
    }

    @ViewBuilder
    private var badge: some View {
        ZStack {
            Circle()
                .fill(Color.effectiveAccent.opacity(0.25))

            switch state {
            case .running:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            case .succeeded:
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            case .failed:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.orange)
                    .transition(.scale.combined(with: .opacity))
            case nil:
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.effectiveAccent)
            }
        }
    }
}
