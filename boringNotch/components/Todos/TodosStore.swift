//
//  TodosStore.swift
//  boringNotch
//
//  Created by Deckmian on 2026-10-15.
//

import AppKit
import Combine
import Foundation

/// Holds the to-do list and persists it as JSON in Application Support
/// (`boringNotch/Todos/todos.json`).
@MainActor
final class TodosStore: ObservableObject {
    static let shared = TodosStore()

    @Published private(set) var items: [TodoItem]

    private let fileURL: URL
    private var cancellables = Set<AnyCancellable>()
    private var lastSavedItems: [TodoItem]

    private init() {
        let fm = FileManager.default
        let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = (support ?? fm.temporaryDirectory).appendingPathComponent("boringNotch", isDirectory: true).appendingPathComponent("Todos", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("todos.json")

        let initialItems = Self.load(from: fileURL)
        items = initialItems
        lastSavedItems = initialItems

        // Batch quick successive edits into a single write
        $items
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.save()
            }
            .store(in: &cancellables)

        // Flush any pending changes before the app quits
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.save()
            }
            .store(in: &cancellables)
    }

    // MARK: - Editing

    func add(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(TodoItem(title: trimmed))
    }

    func toggle(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isDone.toggle()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    func clearCompleted() {
        items.removeAll { $0.isDone }
    }

    // MARK: - Persistence

    func save() {
        guard items != lastSavedItems else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: .atomic)
            lastSavedItems = items
        } catch {
            print("Failed to save to-dos: \(error.localizedDescription)")
        }
    }

    private static func load(from url: URL) -> [TodoItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([TodoItem].self, from: data)
        } catch {
            print("Failed to load to-dos: \(error.localizedDescription)")
            return []
        }
    }
}
