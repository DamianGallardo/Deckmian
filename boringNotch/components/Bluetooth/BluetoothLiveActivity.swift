//
//  BluetoothLiveActivity.swift
//  boringNotch
//
//  Created by Deckmian on 2026-10-15.
//

import SwiftUI

/// Brief announcement around the closed notch when a Bluetooth device connects or disconnects:
/// the device symbol and name on the left wing, its new status on the right one.
struct BluetoothLiveActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var manager = BluetoothManager.shared

    private var wingWidth: CGFloat {
        Self.wingWidth(notchHeight: vm.effectiveClosedNotchHeight)
    }

    var body: some View {
        HStack {
            if let event = manager.lastEvent {
                HStack(spacing: 6) {
                    Image(systemName: event.device.kind.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(event.connected ? Color.effectiveAccent : .gray)
                        .frame(width: 16)

                    Text(event.device.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(width: wingWidth, alignment: .leading)

                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width + -cornerRadiusInsets.closed.top)

                HStack(spacing: 5) {
                    Circle()
                        .fill(event.connected ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)

                    Text(event.connected ? "Connected" : "Disconnected")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(event.connected ? .white : .gray)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: wingWidth, alignment: .trailing)
            }
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
        .transition(.opacity)
    }

    /// Width of each side wing; shared with the closed-notch hit area sizing in `ContentView`.
    static func wingWidth(notchHeight: CGFloat) -> CGFloat {
        max(max(0, notchHeight - 12), 100)
    }
}
