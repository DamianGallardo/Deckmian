//
//  DeckmianXPCHelperProtocol.swift
//  DeckmianXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol DeckmianXPCHelperProtocol {
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
    // Live video (performed by the helper through the Accessibility tree of Google Chrome)
    /// Replies with the frame of the video playing in Chrome, keyed by `ChromeVideoKeys`.
    /// `preferredTitle` (the current song) picks between several windows; pass "" when unknown.
    func locateChromeVideo(_ preferredTitle: String, with reply: @escaping ([String: String]) -> Void)
}

/// Dictionary keys used to transfer shortcut descriptions over XPC.
enum SystemShortcutKeys {
    static let name = "name"
    static let identifier = "identifier"
}

/// Dictionary keys used to transfer the location of Chrome's video over XPC.
/// Frames are global screen points with a top-left origin, encoded as decimal strings.
enum ChromeVideoKeys {
    static let status = "status"
    static let statusFound = "found"
    static let statusNotFound = "notFound"
    static let statusNotTrusted = "notTrusted"
    static let statusChromeNotRunning = "chromeNotRunning"
    /// `CGWindowID` of the Chrome window ("0" when unknown).
    static let windowID = "windowID"
    static let windowX = "windowX"
    static let windowY = "windowY"
    static let windowWidth = "windowWidth"
    static let windowHeight = "windowHeight"
    /// Visible part of the video (clipped to the viewport).
    static let videoX = "videoX"
    static let videoY = "videoY"
    static let videoWidth = "videoWidth"
    static let videoHeight = "videoHeight"
    static let title = "title"
    /// `kindVideo` for the `<video>` element, `kindPlayer` for a player box that may include bars.
    static let kind = "kind"
    static let kindVideo = "video"
    static let kindPlayer = "player"
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

