//
//  BoringHeader.swift
//  Deckmian
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @StateObject var tvm = ShelfStateViewModel.shared
    @Default(.enableNotes) var enableNotes
    @Default(.enableTodos) var enableTodos
    @Default(.enableTimer) var enableTimer
    @Default(.enableShortcutsTab) var enableShortcutsTab
    @Default(.enableBluetooth) var enableBluetooth
    @Default(.showLockButton) var showLockButton
    @Default(.showMirror) var showMirror
    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if ((!tvm.isEmpty || coordinator.alwaysShowTabs) && Defaults[.boringShelf]) || enableNotes || enableTodos || enableTimer || enableShortcutsTab || enableBluetooth {
                    TabSelectionView()
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            // Both sides share the space left of and right of the notch equally, so the
            // notch cover stays centered over the hardware notch regardless of content width
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 8) {
                if vm.notchState == .open {
                    if isHUDType(coordinator.sneakPeek.type) && coordinator.sneakPeek.show && Defaults[.showOpenNotchHUD] {
                        OpenNotchHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        if showLockButton {
                            lockButton
                        }
                        if showMirror {
                            Button(action: {
                                vm.toggleCameraPreview()
                            }) {
                                Capsule()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "web.camera.fill")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        if Defaults[.settingsIconInNotch] {
                            Button(action: {
                                DispatchQueue.main.async {
                                    SettingsWindowController.shared.showWindow()
                                }
                                
                            }) {
                                Capsule()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        Image(systemName: "gearshape.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        if Defaults[.showBatteryIndicator] {
                            BoringBatteryView(
                                batteryWidth: 30,
                                isCharging: batteryModel.isCharging,
                                isInLowPowerMode: batteryModel.isInLowPowerMode,
                                isPluggedIn: batteryModel.isPluggedIn,
                                levelBattery: batteryModel.levelBattery,
                                maxCapacity: batteryModel.maxCapacity,
                                timeToFullCharge: batteryModel.timeToFullCharge,
                                isForNotification: false
                            )
                        }
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    private var lockButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                coordinator.isNotchLocked.toggle()
            }
        }) {
            Capsule()
                .fill(coordinator.isNotchLocked ? Color.effectiveAccent.opacity(0.18) : Color.white.opacity(0.1))
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: coordinator.isNotchLocked ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(coordinator.isNotchLocked ? Color.effectiveAccent : .white)
                        .contentTransition(.symbolEffect(.replace))
                        .scaleEffect(coordinator.isNotchLocked ? 1.05 : 1)
                }
        }
        .buttonStyle(PlainButtonStyle())
        .help(coordinator.isNotchLocked ? "Unlock" : "Keep the notch open")
    }

    func isHUDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
