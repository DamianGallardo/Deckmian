//
//  DeckmianXPCHelper+Shortcuts.swift
//  DeckmianXPCHelper
//
//  Created by Deckmian on 2026-10-15.
//

import Foundation

// MARK: - macOS Shortcuts

/// The sandboxed app cannot spawn `/usr/bin/shortcuts`, so listing and running shortcuts happens here.
extension DeckmianXPCHelper {

    @objc func listShortcuts(with reply: @escaping ([[String: String]], String?) -> Void) {
        ShortcutsCommandLine.run(["list", "--show-identifiers"], timeout: 30) { result in
            if result.succeeded {
                reply(ShortcutsCommandLine.parseList(result.output, withIdentifiers: true), nil)
                return
            }

            // Older versions of the tool may not know `--show-identifiers`; fall back to names only
            ShortcutsCommandLine.run(["list"], timeout: 30) { fallback in
                if fallback.succeeded {
                    reply(ShortcutsCommandLine.parseList(fallback.output, withIdentifiers: false), nil)
                } else {
                    reply([], fallback.errorDescription ?? result.errorDescription ?? "Could not list shortcuts.")
                }
            }
        }
    }

    @objc func runShortcut(_ identifierOrName: String, with reply: @escaping (Bool, String?) -> Void) {
        guard !identifierOrName.isEmpty else {
            reply(false, "Missing shortcut identifier.")
            return
        }

        // A leading dash would be parsed as an option; `--` ends option parsing
        var arguments = ["run"]
        if identifierOrName.hasPrefix("-") {
            arguments.append("--")
        }
        arguments.append(identifierOrName)

        ShortcutsCommandLine.run(arguments, timeout: 120) { result in
            reply(result.succeeded, result.succeeded ? nil : result.errorDescription ?? "The shortcut failed.")
        }
    }
}

/// Spawns `/usr/bin/shortcuts` (or another system tool) with an argument array, never through a shell,
/// and collects its output.
enum ShortcutsCommandLine {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")

    struct Result {
        var exitCode: Int32
        var output: String
        var errorOutput: String
        var timedOut: Bool
        var launchError: String?

        var succeeded: Bool {
            launchError == nil && !timedOut && exitCode == 0
        }

        /// A human-readable reason for a failed invocation.
        var errorDescription: String? {
            if let launchError { return launchError }
            if timedOut { return "Timed out." }
            let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { return message }
            return exitCode == 0 ? nil : "Exited with code \(exitCode)."
        }
    }

    /// Runs the tool asynchronously and calls `completion` exactly once, on a background queue.
    /// The process is terminated (and killed if needed) once `timeout` elapses.
    static func run(
        _ arguments: [String],
        executable: URL = executableURL,
        timeout: TimeInterval,
        completion: @escaping (Result) -> Void
    ) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let state = InvocationState()
        let readers = DispatchGroup()

        // Drain both pipes concurrently so a chatty process never blocks on a full pipe buffer
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            state.setOutput(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            state.setErrorOutput(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        process.terminationHandler = { finished in
            // A child spawned by the shortcut may keep the pipes open; don't wait on it for long
            _ = readers.wait(timeout: .now() + 2)
            let snapshot = state.snapshot()
            completion(Result(
                exitCode: finished.terminationStatus,
                output: String(decoding: snapshot.output, as: UTF8.self),
                errorOutput: String(decoding: snapshot.errorOutput, as: UTF8.self),
                timedOut: snapshot.timedOut,
                launchError: nil
            ))
        }

        do {
            try process.run()
        } catch {
            // Nothing was spawned: close the write ends so the readers reach EOF, then report the failure
            process.terminationHandler = nil
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            DispatchQueue.global(qos: .userInitiated).async {
                completion(Result(exitCode: -1, output: "", errorOutput: "", timedOut: false,
                                  launchError: "Could not launch \(executable.lastPathComponent): \(error.localizedDescription)"))
            }
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            state.markTimedOut()
            process.terminate()
            // Escalate if the tool ignores SIGTERM
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }

    /// Parses `shortcuts list` output: one shortcut per line, optionally suffixed with ` (<UUID>)`.
    static func parseList(_ output: String, withIdentifiers: Bool) -> [[String: String]] {
        var entries: [[String: String]] = []
        output.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }

            var name = line
            var identifier = line
            if withIdentifiers, let split = splitIdentifier(from: line) {
                name = split.name
                identifier = split.identifier
            }
            entries.append([
                SystemShortcutKeys.name: name,
                SystemShortcutKeys.identifier: identifier
            ])
        }
        return entries
    }

    /// Splits `Name (UUID)` into its parts; returns nil when the line has no trailing UUID.
    private static func splitIdentifier(from line: String) -> (name: String, identifier: String)? {
        guard line.hasSuffix(")"), let open = line.range(of: " (", options: .backwards) else { return nil }
        let candidate = String(line[open.upperBound..<line.index(before: line.endIndex)])
        guard UUID(uuidString: candidate) != nil else { return nil }
        let name = String(line[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (name, candidate)
    }
}

/// Thread-safe storage shared by the reader, timeout and termination callbacks of one invocation.
private final class InvocationState {
    private let lock = NSLock()
    private var output = Data()
    private var errorOutput = Data()
    private var timedOut = false

    func setOutput(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        output = data
    }

    func setErrorOutput(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        errorOutput = data
    }

    func markTimedOut() {
        lock.lock(); defer { lock.unlock() }
        timedOut = true
    }

    func snapshot() -> (output: Data, errorOutput: Data, timedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (output, errorOutput, timedOut)
    }
}
