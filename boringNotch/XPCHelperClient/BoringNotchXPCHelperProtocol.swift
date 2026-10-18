//
//  BoringNotchXPCHelperProtocol.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol BoringNotchXPCHelperProtocol {
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void)
    func requestAccessibilityAuthorization()
    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void)
    // Keyboard backlight / CoreBrightness access (performed by the helper)
    func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Screen brightness access (performed by the helper)
    func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // macOS Shortcuts access (performed by the unsandboxed helper via /usr/bin/shortcuts)
    /// Replies with one dictionary per shortcut (see `SystemShortcutKeys`) and an error message when listing failed.
    func listShortcuts(with reply: @escaping ([[String: String]], String?) -> Void)
    /// Runs a shortcut by identifier (or name) and replies with its success and, on failure, an error message.
    func runShortcut(_ identifierOrName: String, with reply: @escaping (Bool, String?) -> Void)
    // Bluetooth device details (performed by the unsandboxed helper via system_profiler)
    /// Replies with one dictionary per connected Bluetooth device (see `BluetoothDeviceKeys`); empty on failure.
    func bluetoothBatteryLevels(with reply: @escaping ([[String: String]]) -> Void)
}

/// Dictionary keys used to transfer shortcut descriptions over XPC.
enum SystemShortcutKeys {
    static let name = "name"
    static let identifier = "identifier"
}

/// Dictionary keys used to transfer connected Bluetooth device details over XPC.
/// Battery values are passed through as reported by the system (for example "85%") and may be absent.
enum BluetoothDeviceKeys {
    static let address = "address"
    static let name = "name"
    static let minorType = "minorType"
    static let batteryMain = "batteryMain"
    static let batteryLeft = "batteryLeft"
    static let batteryRight = "batteryRight"
    static let batteryCase = "batteryCase"
}

