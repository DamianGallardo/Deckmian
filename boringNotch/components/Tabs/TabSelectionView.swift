//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.tabOrder) var tabOrder
    @Default(.boringShelf) var boringShelf
    @Default(.enableNotes) var enableNotes
    @Default(.enableTodos) var enableTodos
    @Default(.enableTimer) var enableTimer
    @Default(.enableShortcutsTab) var enableShortcutsTab
    @Default(.enableBluetooth) var enableBluetooth
    @Namespace var animation

    /// The user's tab order, limited to enabled features.
    private var visibleTabs: [NotchViews] {
        tabOrder.normalizedOrder().filter(isEnabled)
    }

    private func isEnabled(_ tab: NotchViews) -> Bool {
        switch tab {
        case .home: true
        case .shelf: boringShelf
        case .notes: enableNotes
        case .todos: enableTodos
        case .timer: enableTimer
        case .shortcuts: enableShortcutsTab
        case .bluetooth: enableBluetooth
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(visibleTabs, id: \.self) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab
                        }
                    }
                    .background {
                        if tab == coordinator.currentView {
                            Capsule()
                                .fill(Color.white.opacity(0.14))
                                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .animation(.smooth, value: tabOrder)
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
