//
//  BluetoothView.swift
//  Deckmian
//
//  Created by Deckmian on 2026-10-15.
//

import SwiftUI

struct BluetoothView: View {
    @ObservedObject var manager = BluetoothManager.shared

    private static let cardSize = CGSize(width: 132, height: 80)
    private static let cardSpacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            Group {
                if manager.permissionDenied && manager.connectedDevices.isEmpty {
                    permissionHint
                } else if manager.connectedDevices.isEmpty {
                    emptyState
                } else {
                    deviceRow
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            manager.tabDidAppear()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.effectiveAccent)

            if let error = manager.errorMessage {
                Text(error)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .transition(.opacity)
            } else {
                Text(deviceCountText)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }

            if manager.isRefreshingBatteries {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }

            Spacer(minLength: 8)

            Button {
                BluetoothManager.openBluetoothSettings()
            } label: {
                Text("Bluetooth Settings")
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .frame(height: 18)
                    .background {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 10, weight: .medium))
        .frame(height: 18)
        .animation(.smooth, value: manager.errorMessage)
    }

    private var deviceCountText: String {
        switch manager.connectedDevices.count {
        case 0: "Bluetooth"
        case 1: "1 device connected"
        default: "\(manager.connectedDevices.count) devices connected"
        }
    }

    private var deviceRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Self.cardSpacing) {
                ForEach(manager.connectedDevices) { device in
                    BluetoothDeviceCard(
                        device: device,
                        isDisconnecting: manager.disconnectingIDs.contains(device.id),
                        size: Self.cardSize
                    ) {
                        manager.disconnect(device)
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .animation(.smooth, value: manager.connectedDevices)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        Text("No Bluetooth devices connected")
            .font(.system(size: 12))
            .foregroundStyle(Color.gray.opacity(0.7))
    }

    private var permissionHint: some View {
        VStack(spacing: 8) {
            Label("Deckmian needs Bluetooth access to list your devices.", systemImage: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.gray.opacity(0.85))

            Button {
                BluetoothManager.openPrivacySettings()
            } label: {
                Text("Open Privacy Settings")
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
    }
}

private struct BluetoothDeviceCard: View {
    let device: BluetoothDeviceInfo
    let isDisconnecting: Bool
    let size: CGSize
    let onDisconnect: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                ZStack {
                    Circle()
                        .fill(Color.effectiveAccent.opacity(0.25))
                    Image(systemName: device.kind.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.effectiveAccent)
                }
                .frame(width: 26, height: 26)

                Spacer(minLength: 0)

                if isDisconnecting {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 18, height: 18)
                } else if isHovering && device.canDisconnect {
                    disconnectButton
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }

            Text(device.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            if let battery = device.battery {
                BluetoothBatteryLabel(battery: battery)
            }
        }
        .padding(8)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(isHovering ? 0.1 : 0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .help(device.name)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.smooth(duration: 0.2), value: isHovering)
    }

    private var disconnectButton: some View {
        Button(action: onDisconnect) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 18, height: 18)
                .background {
                    Circle()
                        .fill(Color.white.opacity(0.15))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Disconnect")
    }
}

/// Battery readout: a single percentage, or compact L/R/Case values for earbuds.
private struct BluetoothBatteryLabel: View {
    let battery: BluetoothBatteryInfo

    private var parts: [(label: String, level: Int)] {
        if battery.left != nil || battery.right != nil {
            return [("L", battery.left), ("R", battery.right), ("C", battery.caseLevel)]
                .compactMap { label, level in level.map { (label, $0) } }
        }
        if let main = battery.main {
            return [("", main)]
        }
        return battery.caseLevel.map { [("C", $0)] } ?? []
    }

    var body: some View {
        HStack(spacing: 6) {
            if let lowest = parts.map(\.level).min() {
                Image(systemName: Self.symbol(for: lowest))
                    .font(.system(size: 9))
                    .foregroundStyle(Self.color(for: lowest))
            }
            ForEach(parts, id: \.label) { part in
                HStack(spacing: 2) {
                    if !part.label.isEmpty {
                        Text(part.label)
                            .foregroundStyle(.gray)
                    }
                    Text("\(part.level)%")
                        .foregroundStyle(Self.color(for: part.level))
                }
            }
        }
        .font(.system(size: 10, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    static func color(for level: Int) -> Color {
        level < 20 ? .red : .white.opacity(0.85)
    }

    static func symbol(for level: Int) -> String {
        switch level {
        case ..<13: "battery.0"
        case ..<38: "battery.25"
        case ..<63: "battery.50"
        case ..<88: "battery.75"
        default: "battery.100"
        }
    }
}
