//
//  ShortcutsStore.swift
//  Deckmian
//
//  Created by Deckmian on 2026-10-15.
//

import Defaults
import Foundation

/// A shortcut from the macOS Shortcuts app.
struct ShortcutInfo: Identifiable, Codable, Hashable, Defaults.Serializable {
    /// The shortcut's identifier (UUID), or its name when identifiers are unavailable.
    let id: String
    let name: String
}

/// Lists the user's macOS shortcuts, keeps the pinned selection and runs them through the XPC helper
/// (the sandboxed app cannot spawn `/usr/bin/shortcuts` itself).
@MainActor
final class ShortcutsStore: ObservableObject {
    static let shared = ShortcutsStore()

    enum RunState: Equatable {
        case running
        case succeeded
        case failed(String)
    }

    /// How long the success / failure badge stays on a tile.
    private static let feedbackDuration: Duration = .seconds(1.5)

    @Published private(set) var available: [ShortcutInfo]
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var pinnedIDs: [String] {
        didSet { Defaults[.pinnedShortcuts] = pinnedIDs }
    }
    @Published private(set) var runStates: [String: RunState] = [:]

    private var feedbackTasks: [String: Task<Void, Never>] = [:]

    private init() {
        available = Defaults[.cachedShortcuts]
        pinnedIDs = Defaults[.pinnedShortcuts]
    }

    /// Pinned shortcuts that are still available, in pinned order.
    var pinned: [ShortcutInfo] {
        let byID = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return pinnedIDs.compactMap { byID[$0] }
    }

    func isPinned(_ shortcut: ShortcutInfo) -> Bool {
        pinnedIDs.contains(shortcut.id)
    }

    // MARK: - Listing

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            let result = await XPCHelperClient.shared.listShortcuts()
            isLoading = false

            if let error = result.error {
                errorMessage = error
                return
            }
            errorMessage = nil

            var seen = Set<String>()
            let shortcuts = result.items.compactMap { entry -> ShortcutInfo? in
                guard let name = entry[SystemShortcutKeys.name], !name.isEmpty else { return nil }
                let id = entry[SystemShortcutKeys.identifier].flatMap { $0.isEmpty ? nil : $0 } ?? name
                guard seen.insert(id).inserted else { return nil }
                return ShortcutInfo(id: id, name: name)
            }
            available = shortcuts
            Defaults[.cachedShortcuts] = shortcuts

            // Forget shortcuts that were deleted from the Shortcuts app. An empty result is
            // ambiguous (e.g. iCloud still syncing), so the selection is kept in that case.
            if !shortcuts.isEmpty {
                let ids = Set(shortcuts.map(\.id))
                let remaining = pinnedIDs.filter(ids.contains)
                if remaining != pinnedIDs {
                    pinnedIDs = remaining
                }
            }
        }
    }

    // MARK: - Pinning

    func setPinned(_ pinned: Bool, for shortcut: ShortcutInfo) {
        if pinned {
            guard !pinnedIDs.contains(shortcut.id) else { return }
            pinnedIDs.append(shortcut.id)
        } else {
            pinnedIDs.removeAll { $0 == shortcut.id }
        }
    }

    /// Moves a pinned shortcut by `offset` positions within the visible pinned order (negative moves it up).
    func movePinned(_ shortcut: ShortcutInfo, by offset: Int) {
        let visible = pinned
        guard let index = visible.firstIndex(of: shortcut), visible.indices.contains(index + offset) else { return }
        let neighbor = visible[index + offset]
        guard let from = pinnedIDs.firstIndex(of: shortcut.id),
              let to = pinnedIDs.firstIndex(of: neighbor.id) else { return }
        pinnedIDs.swapAt(from, to)
    }

    // MARK: - Running

    func run(_ shortcut: ShortcutInfo) {
        let id = shortcut.id
        guard runStates[id] != .running else { return }

        feedbackTasks[id]?.cancel()
        feedbackTasks[id] = nil
        runStates[id] = .running

        Task {
            let result = await XPCHelperClient.shared.runShortcut(id)
            runStates[id] = result.success ? .succeeded : .failed(result.error ?? "The shortcut failed.")

            feedbackTasks[id] = Task {
                try? await Task.sleep(for: Self.feedbackDuration)
                guard !Task.isCancelled else { return }
                runStates[id] = nil
                feedbackTasks[id] = nil
            }
        }
    }
}
