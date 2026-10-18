//
//  NotesStore.swift
//  boringNotch
//
//  Created by Deckmian on 2026-10-15.
//

import AppKit
import Combine
import Foundation

/// Holds the single scratchpad note and persists it as plain UTF-8 text
/// in Application Support (`boringNotch/Notes/note.txt`).
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published var text: String

    private let fileURL: URL
    private var cancellables = Set<AnyCancellable>()
    private var lastSavedText: String

    private init() {
        let fm = FileManager.default
        let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = (support ?? fm.temporaryDirectory).appendingPathComponent("boringNotch", isDirectory: true).appendingPathComponent("Notes", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("note.txt")

        let initialText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        text = initialText
        lastSavedText = initialText

        // Persist shortly after the user stops typing
        $text
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

    func save() {
        guard text != lastSavedText else { return }
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            lastSavedText = text
        } catch {
            print("Failed to save note: \(error.localizedDescription)")
        }
    }
}
