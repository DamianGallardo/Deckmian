//
//  LayoutSettings.swift
//  Deckmian
//
//  Settings page for the tab order and the Home tab widget layout.
//

import AVFoundation
import Defaults
import SwiftUI

struct LayoutSettings: View {
    @Default(.tabOrder) private var tabOrder
    @Default(.homeWidgetOrder) private var homeWidgetOrder
    @Default(.homeWidgetSpacing) private var homeWidgetSpacing
    @Default(.showWidgetDividers) private var showWidgetDividers

    private var orderedTabs: [NotchViews] { tabOrder.normalizedOrder() }
    private var orderedWidgets: [HomeWidget] { homeWidgetOrder.normalizedOrder() }

    private var hasCamera: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    var body: some View {
        Form {
            tabsSection
            homeWidgetsSection
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Layout")
    }

    // MARK: Tabs

    private var tabsSection: some View {
        Section {
            let tabs = orderedTabs
            ForEach(tabs, id: \.self) { tab in
                LayoutReorderRow(
                    icon: tab.icon,
                    title: tab.label,
                    visibilityKey: tab.enableKey,
                    canMoveUp: tab != tabs.first,
                    canMoveDown: tab != tabs.last
                ) { offset in
                    tabOrder = tabs.moving(tab, by: offset)
                }
            }
            .onMove { source, destination in
                var order = tabs
                order.move(fromOffsets: source, toOffset: destination)
                tabOrder = order
            }

            Button("Reset order") {
                Defaults.reset(.tabOrder)
            }
            .disabled(tabs == NotchViews.defaultOrder)
        } header: {
            Text("Tabs")
        } footer: {
            Text("Drag or use the arrows to reorder the tabs of the open notch. Home is always shown.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Home widgets

    private var homeWidgetsSection: some View {
        Section {
            let widgets = orderedWidgets
            ForEach(widgets) { widget in
                LayoutReorderRow(
                    icon: widget.icon,
                    title: widget.displayName,
                    visibilityKey: widget.visibilityKey,
                    isToggleDisabled: widget == .mirror && !hasCamera,
                    canMoveUp: widget != widgets.first,
                    canMoveDown: widget != widgets.last
                ) { offset in
                    homeWidgetOrder = widgets.moving(widget, by: offset)
                }
            }
            .onMove { source, destination in
                var order = widgets
                order.move(fromOffsets: source, toOffset: destination)
                homeWidgetOrder = order
            }

            Slider(value: $homeWidgetSpacing, in: 0...24, step: 1) {
                HStack {
                    Text("Spacing")
                    Spacer()
                    Text("\(homeWidgetSpacing, specifier: "%.0f") pt")
                        .foregroundStyle(.secondary)
                }
            }

            Defaults.Toggle(key: .showWidgetDividers) {
                Text("Show dividers")
            }

            Button("Reset") {
                Defaults.reset(.homeWidgetOrder, .homeWidgetSpacing, .showWidgetDividers)
            }
            .disabled(
                widgets == HomeWidget.defaultOrder
                    && homeWidgetSpacing == Defaults.Keys.homeWidgetSpacing.defaultValue
                    && showWidgetDividers == Defaults.Keys.showWidgetDividers.defaultValue
            )
        } header: {
            Text("Home widgets")
        } footer: {
            Text("The mirror appears once you turn on the camera from the notch header. Reset restores the order, spacing and dividers; visibility is left unchanged.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// A settings row with an icon, a title, an optional visibility toggle and up/down reorder buttons.
private struct LayoutReorderRow: View {
    let icon: String
    let title: String
    let visibilityKey: Defaults.Key<Bool>?
    var isToggleDisabled = false
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMove: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(title)
            Spacer()
            HStack(spacing: 2) {
                Button {
                    onMove(-1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(!canMoveUp)
                .help("Move up")
                Button {
                    onMove(1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(!canMoveDown)
                .help("Move down")
            }
            .buttonStyle(.borderless)
            if let visibilityKey {
                Defaults.Toggle(key: visibilityKey) {
                    Text(title)
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isToggleDisabled)
            }
        }
    }
}
