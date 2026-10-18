//
//  DeckmianXPCHelper+Bluetooth.swift
//  DeckmianXPCHelper
//
//  Created by Deckmian on 2026-10-15.
//

import Foundation

// MARK: - Bluetooth

/// Battery levels of Bluetooth accessories are only exposed through `system_profiler`,
/// which the sandboxed app cannot spawn, so the lookup happens here.
extension DeckmianXPCHelper {

    @objc func bluetoothBatteryLevels(with reply: @escaping ([[String: String]]) -> Void) {
        ShortcutsCommandLine.run(
            ["SPBluetoothDataType", "-json"],
            executable: BluetoothProfiler.executableURL,
            timeout: 20
        ) { result in
            guard result.succeeded else {
                reply([])
                return
            }
            reply(BluetoothProfiler.parseConnectedDevices(Data(result.output.utf8)))
        }
    }
}

/// Parses the JSON report of `system_profiler SPBluetoothDataType -json`.
enum BluetoothProfiler {
    static let executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")

    /// Returns one dictionary per connected device, keyed by `BluetoothDeviceKeys`.
    /// Devices without an address are skipped; battery entries are included only when reported.
    static func parseConnectedDevices(_ data: Data) -> [[String: String]] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }

        var devices: [[String: String]] = []
        for controller in controllers {
            for (name, properties) in namedEntries(controller["device_connected"]) {
                guard let address = properties["device_address"] as? String, !address.isEmpty else { continue }

                var entry: [String: String] = [
                    BluetoothDeviceKeys.address: address,
                    BluetoothDeviceKeys.name: name
                ]
                if let minorType = properties["device_minorType"] as? String {
                    entry[BluetoothDeviceKeys.minorType] = minorType
                }
                for (key, value) in properties {
                    guard let level = value as? String, let target = batteryKey(for: key) else { continue }
                    entry[target] = level
                }
                devices.append(entry)
            }
        }
        return devices
    }

    /// Maps `device_batteryLevel[Main|Left|Right|Case]` to the matching transfer key.
    private static func batteryKey(for key: String) -> String? {
        let prefix = "device_batteryLevel"
        guard key.hasPrefix(prefix) else { return nil }
        switch key.dropFirst(prefix.count) {
        case "", "Main": return BluetoothDeviceKeys.batteryMain
        case "Left": return BluetoothDeviceKeys.batteryLeft
        case "Right": return BluetoothDeviceKeys.batteryRight
        case "Case": return BluetoothDeviceKeys.batteryCase
        default: return nil
        }
    }

    /// The device list is an array of single-entry `{ name: properties }` objects; tolerate a plain object too.
    private static func namedEntries(_ value: Any?) -> [(String, [String: Any])] {
        if let list = value as? [[String: Any]] {
            return list.flatMap { namedEntries($0) }
        }
        if let object = value as? [String: Any] {
            return object.compactMap { name, properties in
                (properties as? [String: Any]).map { (name, $0) }
            }
        }
        return []
    }
}
