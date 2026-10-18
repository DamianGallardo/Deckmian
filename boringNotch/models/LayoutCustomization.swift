//
//  LayoutCustomization.swift
//  boringNotch
//
//  User-customizable ordering of the notch tabs and the Home tab widgets.
//

import Defaults
import Foundation

// MARK: - Order normalization

extension Array where Element: CaseIterable & Hashable {
    /// The stored order with duplicates dropped and every case missing from it appended at the end,
    /// so cases added in future versions always show up.
    func normalizedOrder() -> [Element] {
        var seen = Set<Element>()
        let known = filter { seen.insert($0).inserted }
        return known + Element.allCases.filter { !seen.contains($0) }
    }

    /// Moves `element` one position towards the start (`offset: -1`) or the end (`offset: 1`).
    func moving(_ element: Element, by offset: Int) -> [Element] {
        guard let index = firstIndex(of: element) else { return self }
        let target = index + offset
        guard indices.contains(target) else { return self }
        var result = self
        result.swapAt(index, target)
        return result
    }
}

// MARK: - Tabs

extension NotchViews {
    static let defaultOrder: [NotchViews] = Array(allCases)

    var label: String {
        switch self {
        case .home: "Home"
        case .shelf: "Shelf"
        case .notes: "Notes"
        case .todos: "To-dos"
        case .timer: "Timer"
        case .shortcuts: "Shortcuts"
        case .bluetooth: "Bluetooth"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .shelf: "tray.full"
        case .notes: "square.and.pencil"
        case .todos: "checklist"
        case .timer: "stopwatch"
        case .shortcuts: "square.grid.2x2"
        case .bluetooth: "headphones"
        }
    }

    /// The setting that enables this tab; `nil` for tabs that are always shown (Home).
    var enableKey: Defaults.Key<Bool>? {
        switch self {
        case .home: nil
        case .shelf: .boringShelf
        case .notes: .enableNotes
        case .todos: .enableTodos
        case .timer: .enableTimer
        case .shortcuts: .enableShortcutsTab
        case .bluetooth: .enableBluetooth
        }
    }
}

// MARK: - Home widgets

enum HomeWidget: String, CaseIterable, Identifiable, Codable, Defaults.Serializable {
    case music
    case calendar
    case mirror

    var id: String { rawValue }

    static let defaultOrder: [HomeWidget] = [.music, .calendar, .mirror]

    var displayName: String {
        switch self {
        case .music: "Music player"
        case .calendar: "Calendar"
        case .mirror: "Mirror"
        }
    }

    var icon: String {
        switch self {
        case .music: "music.note"
        case .calendar: "calendar"
        case .mirror: "web.camera"
        }
    }

    /// The setting that controls whether this widget is shown on the Home tab.
    var visibilityKey: Defaults.Key<Bool> {
        switch self {
        case .music: .showMusicWidget
        case .calendar: .showCalendar
        case .mirror: .showMirror
        }
    }
}
