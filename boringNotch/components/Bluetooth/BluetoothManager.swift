//
//  BluetoothManager.swift
//  boringNotch
//
//  Created by Deckmian on 2026-10-15.
//

import AppKit
import Combine
import CoreBluetooth
import Defaults
import IOBluetooth

// MARK: - Models

enum BluetoothDeviceKind: Equatable {
    case headphones
    case airpods
    case airpodsPro
    case airpodsMax
    case keyboard
    case mouse
    case gamepad
    case speaker
    case phone
    case computer
    case other

    var symbol: String {
        switch self {
        case .headphones: "headphones"
        case .airpods: "airpods"
        case .airpodsPro: "airpodspro"
        case .airpodsMax: "airpodsmax"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .gamepad: "gamecontroller"
        case .speaker: "hifispeaker"
        case .phone: "iphone"
        case .computer: "laptopcomputer"
        case .other: "dot.radiowaves.left.and.right"
        }
    }

    /// Picks a kind from the device name first (it is the most specific hint), then from the
    /// Bluetooth class of device, then from the minor type string reported by `system_profiler`.
    static func classify(
        name: String,
        majorClass: UInt32? = nil,
        minorClass: UInt32? = nil,
        minorType: String? = nil
    ) -> BluetoothDeviceKind {
        if let kind = fromName(name) { return kind }
        if let majorClass, let minorClass, let kind = fromDeviceClass(major: majorClass, minor: minorClass) {
            return kind
        }
        if let minorType, let kind = fromMinorType(minorType) { return kind }
        return .other
    }

    private static func fromName(_ name: String) -> BluetoothDeviceKind? {
        let lowered = name.lowercased()
        if lowered.contains("airpods max") { return .airpodsMax }
        if lowered.contains("airpods pro") { return .airpodsPro }
        if lowered.contains("airpods") { return .airpods }
        if lowered.contains("keyboard") { return .keyboard }
        if lowered.contains("mouse") || lowered.contains("trackpad") { return .mouse }
        if ["controller", "gamepad", "dualsense", "dualshock", "joy-con"].contains(where: lowered.contains) {
            return .gamepad
        }
        if lowered.contains("iphone") { return .phone }
        if ["macbook", "imac", "mac mini", "mac studio"].contains(where: lowered.contains) { return .computer }
        if ["headphone", "buds", "beats"].contains(where: lowered.contains) { return .headphones }
        if lowered.contains("speaker") { return .speaker }
        return nil
    }

    /// Major/minor values of the Bluetooth "Class of Device" field (Assigned Numbers, section 2.8).
    private static func fromDeviceClass(major: UInt32, minor: UInt32) -> BluetoothDeviceKind? {
        switch major {
        case 0x01:
            return .computer
        case 0x02:
            return .phone
        case 0x04:
            // Audio/Video: loudspeaker (0x05) and HiFi audio (0x0A) are speakers; headsets and the rest are worn
            return minor == 0x05 || minor == 0x0A ? .speaker : .headphones
        case 0x05:
            // Peripheral: the low 4 bits name the device type, the upper 2 bits keyboard/pointing
            switch minor & 0x0F {
            case 0x01, 0x02: return .gamepad
            default: break
            }
            switch minor & 0x30 {
            case 0x10, 0x30: return .keyboard
            case 0x20: return .mouse
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func fromMinorType(_ minorType: String) -> BluetoothDeviceKind? {
        let lowered = minorType.lowercased()
        if lowered.contains("headset") || lowered.contains("headphone") || lowered.contains("hands-free") {
            return .headphones
        }
        if lowered.contains("keyboard") { return .keyboard }
        if lowered.contains("mouse") || lowered.contains("trackpad") || lowered.contains("pointing") { return .mouse }
        if lowered.contains("gamepad") || lowered.contains("joystick") { return .gamepad }
        if lowered.contains("speaker") { return .speaker }
        if lowered.contains("phone") { return .phone }
        if lowered.contains("computer") || lowered.contains("laptop") || lowered.contains("desktop") { return .computer }
        return nil
    }
}

/// Battery levels in percent; each part is optional because most accessories report only some (or none).
struct BluetoothBatteryInfo: Equatable {
    var main: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?

    var isEmpty: Bool {
        main == nil && left == nil && right == nil && caseLevel == nil
    }

    /// Builds battery info from the raw strings sent by the helper; nil when nothing could be parsed.
    init?(report: [String: String]) {
        main = Self.percent(report[BluetoothDeviceKeys.batteryMain])
        left = Self.percent(report[BluetoothDeviceKeys.batteryLeft])
        right = Self.percent(report[BluetoothDeviceKeys.batteryRight])
        caseLevel = Self.percent(report[BluetoothDeviceKeys.batteryCase])
        if isEmpty { return nil }
    }

    /// Parses values like "85%", "85 %" or "85" into a 0...100 integer.
    static func percent(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let digits = raw.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        guard let value = Int(digits) else { return nil }
        return min(100, max(0, value))
    }
}

struct BluetoothDeviceInfo: Identifiable, Equatable {
    /// Normalized device address (see `BluetoothAddress.normalize`).
    let id: String
    var name: String
    var kind: BluetoothDeviceKind
    var battery: BluetoothBatteryInfo?
    /// False for devices only known from `system_profiler` (for example some Bluetooth LE accessories).
    var canDisconnect: Bool
}

struct BluetoothConnectionEvent: Equatable {
    var device: BluetoothDeviceInfo
    var connected: Bool
    var date: Date
}

enum BluetoothAddress {
    /// Lowercase hex pairs joined by ":" so "24-1A-E6-2F-CB-EA" and "24:1a:e6:2f:cb:ea" compare equal.
    static func normalize(_ address: String) -> String {
        let hex = address.lowercased().filter(\.isHexDigit)
        guard hex.count == 12 else { return hex }
        var pairs: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            pairs.append(String(hex[index..<next]))
            index = next
        }
        return pairs.joined(separator: ":")
    }
}

// MARK: - Manager

/// Tracks connected Bluetooth devices for the Bluetooth tab and announces connections in the closed notch.
///
/// Connections come from IOBluetooth notifications; battery levels (and devices IOBluetooth does not
/// track) come from `system_profiler`, which the XPC helper runs on demand.
@MainActor
final class BluetoothManager: ObservableObject {
    static let shared = BluetoothManager()

    @Published private(set) var connectedDevices: [BluetoothDeviceInfo] = []
    @Published private(set) var lastEvent: BluetoothConnectionEvent?
    @Published private(set) var isObserving = false
    @Published private(set) var isRefreshingBatteries = false
    /// True when the user denied (or a profile restricts) Bluetooth access for the app.
    @Published private(set) var permissionDenied = false
    @Published private(set) var disconnectingIDs: Set<String> = []
    @Published private(set) var errorMessage: String?

    private static let launchGracePeriod: TimeInterval = 3
    private static let duplicateEventWindow: TimeInterval = 2
    private static let batteryRefreshInterval: TimeInterval = 5 * 60
    private static let postConnectBatteryDelay: Duration = .seconds(3)

    private let launchDate = Date()
    private var started = false
    private var observationStart = Date.distantPast

    private var receiver: BluetoothNotificationReceiver?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var ioDevices: [String: IOBluetoothDevice] = [:]

    private var batteries: [String: BluetoothBatteryInfo] = [:]
    private var reportedMinorTypes: [String: String] = [:]
    private var profilerOnlyDevices: [BluetoothDeviceInfo] = []
    private var recentEvents: [String: (connected: Bool, date: Date)] = [:]

    private var batteryTask: Task<Void, Never>?
    private var delayedBatteryTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var periodicRefresh: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    /// Starts following the `enableBluetooth` setting; observation runs only while it is on.
    func start() {
        guard !started else { return }
        started = true

        Defaults.publisher(.enableBluetooth)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self else { return }
                    if change.newValue {
                        self.startObserving()
                    } else {
                        self.stopObserving()
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Observation

    private func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        observationStart = Date()
        updatePermissionState()

        let receiver = BluetoothNotificationReceiver()
        receiver.onConnect = { [weak self] device in
            self?.handleConnect(device)
        }
        receiver.onDisconnect = { [weak self] notification, device in
            self?.handleDisconnect(notification, device: device)
        }
        self.receiver = receiver

        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        for device in paired where device.isConnected() {
            track(device)
        }

        // IOBluetooth also reports already connected devices here; `track` ignores those it knows
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: receiver,
            selector: #selector(BluetoothNotificationReceiver.deviceConnected(_:device:))
        )

        rebuildDeviceList()
        refreshBatteries()
    }

    private func stopObserving() {
        guard isObserving else { return }
        isObserving = false

        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
        receiver = nil

        batteryTask?.cancel()
        batteryTask = nil
        delayedBatteryTask?.cancel()
        delayedBatteryTask = nil
        periodicRefresh?.invalidate()
        periodicRefresh = nil

        ioDevices.removeAll()
        batteries.removeAll()
        reportedMinorTypes.removeAll()
        profilerOnlyDevices.removeAll()
        recentEvents.removeAll()
        disconnectingIDs.removeAll()
        isRefreshingBatteries = false
        connectedDevices = []
        lastEvent = nil
    }

    /// Remembers a connected device and subscribes to its disconnection; returns false if already tracked.
    @discardableResult
    private func track(_ device: IOBluetoothDevice) -> Bool {
        guard let address = device.addressString else { return false }
        let id = BluetoothAddress.normalize(address)
        let isNew = ioDevices[id] == nil
        ioDevices[id] = device

        if disconnectNotifications[id] == nil, let receiver {
            disconnectNotifications[id] = device.register(
                forDisconnectNotification: receiver,
                selector: #selector(BluetoothNotificationReceiver.deviceDisconnected(_:device:))
            )
        }
        return isNew
    }

    private func handleConnect(_ device: IOBluetoothDevice) {
        guard isObserving, track(device), let address = device.addressString else { return }
        let id = BluetoothAddress.normalize(address)

        // A device that was only known from system_profiler is now tracked by IOBluetooth
        profilerOnlyDevices.removeAll { $0.id == id }
        rebuildDeviceList()

        if let info = connectedDevices.first(where: { $0.id == id }) {
            announce(info, connected: true)
        }

        // Give the accessory a moment to publish its battery level
        delayedBatteryTask?.cancel()
        delayedBatteryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.postConnectBatteryDelay)
            guard !Task.isCancelled else { return }
            self?.refreshBatteries()
        }
    }

    private func handleDisconnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        guard isObserving, let address = device.addressString else { return }
        let id = BluetoothAddress.normalize(address)

        let info = connectedDevices.first(where: { $0.id == id }) ?? makeInfo(for: device, id: id)
        disconnectNotifications[id] = nil
        ioDevices[id] = nil
        batteries[id] = nil
        disconnectingIDs.remove(id)
        rebuildDeviceList()
        updatePeriodicRefresh()

        announce(info, connected: false)
    }

    /// Records the event and, outside the launch grace period, widens the closed notch for a few seconds.
    private func announce(_ device: BluetoothDeviceInfo, connected: Bool) {
        let now = Date()

        // IOBluetooth may deliver the same transition twice in a row
        if let previous = recentEvents[device.id], previous.connected == connected,
           now.timeIntervalSince(previous.date) < Self.duplicateEventWindow {
            return
        }
        recentEvents[device.id] = (connected, now)
        lastEvent = BluetoothConnectionEvent(device: device, connected: connected, date: now)

        // Connect notifications for devices that were already connected arrive right after registering
        guard now.timeIntervalSince(launchDate) >= Self.launchGracePeriod,
              now.timeIntervalSince(observationStart) >= Self.launchGracePeriod,
              Defaults[.bluetoothLiveActivity]
        else { return }

        BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .bluetooth)
    }

    // MARK: - Device list

    private func makeInfo(for device: IOBluetoothDevice, id: String) -> BluetoothDeviceInfo {
        let name = device.name ?? device.nameOrAddress ?? "Unknown device"
        let kind = BluetoothDeviceKind.classify(
            name: name,
            majorClass: UInt32(device.deviceClassMajor),
            minorClass: UInt32(device.deviceClassMinor),
            minorType: reportedMinorTypes[id]
        )
        return BluetoothDeviceInfo(id: id, name: name, kind: kind, battery: batteries[id], canDisconnect: true)
    }

    private func rebuildDeviceList() {
        var devices = ioDevices.map { id, device in makeInfo(for: device, id: id) }
        devices += profilerOnlyDevices.filter { ioDevices[$0.id] == nil }
        devices.sort {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        if devices != connectedDevices {
            connectedDevices = devices
        }
    }

    // MARK: - Batteries

    /// Asks the helper for fresh battery levels; never blocks the caller and coalesces concurrent requests.
    func refreshBatteries() {
        guard isObserving, batteryTask == nil else { return }
        isRefreshingBatteries = true
        batteryTask = Task { [weak self] in
            let report = await XPCHelperClient.shared.bluetoothBatteryLevels()
            guard let self, !Task.isCancelled else { return }
            self.batteryTask = nil
            self.isRefreshingBatteries = false
            self.apply(report)
        }
    }

    private func apply(_ report: [[String: String]]) {
        guard isObserving else { return }

        var newBatteries: [String: BluetoothBatteryInfo] = [:]
        var newMinorTypes: [String: String] = [:]
        var profilerOnly: [BluetoothDeviceInfo] = []

        for entry in report {
            guard let address = entry[BluetoothDeviceKeys.address] else { continue }
            let id = BluetoothAddress.normalize(address)
            let battery = BluetoothBatteryInfo(report: entry)
            newBatteries[id] = battery
            newMinorTypes[id] = entry[BluetoothDeviceKeys.minorType]

            if ioDevices[id] == nil {
                let name = entry[BluetoothDeviceKeys.name] ?? address
                profilerOnly.append(BluetoothDeviceInfo(
                    id: id,
                    name: name,
                    kind: .classify(name: name, minorType: entry[BluetoothDeviceKeys.minorType]),
                    battery: battery,
                    canDisconnect: false
                ))
            }
        }

        batteries = newBatteries
        reportedMinorTypes = newMinorTypes
        profilerOnlyDevices = profilerOnly
        rebuildDeviceList()
        updatePeriodicRefresh()
    }

    /// Polls every few minutes while there is something only `system_profiler` can keep current.
    private func updatePeriodicRefresh() {
        let needsPolling = isObserving && (!batteries.isEmpty || !profilerOnlyDevices.isEmpty)
        guard needsPolling else {
            periodicRefresh?.invalidate()
            periodicRefresh = nil
            return
        }
        guard periodicRefresh == nil else { return }

        let timer = Timer(timeInterval: Self.batteryRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshBatteries()
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        periodicRefresh = timer
    }

    // MARK: - Tab

    /// Called when the Bluetooth tab is shown: rechecks access and refreshes battery levels.
    func tabDidAppear() {
        updatePermissionState()
        refreshBatteries()
    }

    private func updatePermissionState() {
        let authorization = CBManager.authorization
        permissionDenied = authorization == .denied || authorization == .restricted
    }

    // MARK: - Actions

    func disconnect(_ device: BluetoothDeviceInfo) {
        guard let ioDevice = ioDevices[device.id], !disconnectingIDs.contains(device.id) else { return }
        disconnectingIDs.insert(device.id)

        // `closeConnection` waits for the baseband to drop, so keep it off the main thread
        let box = UncheckedDeviceBox(device: ioDevice)
        let name = device.name
        let id = device.id
        DispatchQueue.global(qos: .userInitiated).async {
            let status = box.device.closeConnection()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let manager = BluetoothManager.shared
                    manager.disconnectingIDs.remove(id)
                    if status != kIOReturnSuccess {
                        manager.showError("Couldn't disconnect \(name).")
                    }
                }
            }
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        errorTask?.cancel()
        errorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.errorMessage = nil
        }
    }

    // MARK: - System Settings

    static func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Carries an IOBluetooth device to a background queue for a single blocking call.
private struct UncheckedDeviceBox: @unchecked Sendable {
    let device: IOBluetoothDevice
}

/// Objective-C target for IOBluetooth notifications, which are delivered on the main run loop.
@MainActor
final class BluetoothNotificationReceiver: NSObject {
    var onConnect: ((IOBluetoothDevice) -> Void)?
    var onDisconnect: ((IOBluetoothUserNotification, IOBluetoothDevice) -> Void)?

    @objc func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onConnect?(device)
    }

    @objc func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onDisconnect?(notification, device)
    }
}
