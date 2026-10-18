//
//  TimerStore.swift
//  boringNotch
//
//  Created by Deckmian on 2026-10-15.
//

import AppKit
import Combine
import Defaults
import Foundation

enum TimerState {
    case idle
    case running
    case paused
    case finished
}

/// Drives the countdown timer shown in the Timer tab and the closed-notch live activity.
///
/// The countdown is derived from wall-clock time (`endDate` while running, a frozen
/// `remaining` while paused), so ticks only refresh the published value and never drift.
@MainActor
final class TimerStore: ObservableObject {
    static let shared = TimerStore()

    static let minimumDuration: TimeInterval = 60
    static let maximumDuration: TimeInterval = 3 * 60 * 60
    static let presets: [TimeInterval] = [1, 5, 10, 15, 25, 45].map { $0 * 60 }

    @Published private(set) var state: TimerState = .idle
    /// Total length selected for the next run.
    @Published private(set) var duration: TimeInterval
    /// Time left in the current run (equals `duration` while idle).
    @Published private(set) var remaining: TimeInterval
    /// Total length of the current run, including any time added while it was going.
    @Published private(set) var runDuration: TimeInterval

    private var endDate: Date?
    private var ticker: Timer?
    private var cancellables = Set<AnyCancellable>()
    private static let tickInterval: TimeInterval = 0.25

    /// True whenever there is something worth surfacing outside the Timer tab.
    var isActive: Bool {
        state != .idle
    }

    /// Fraction of the current run still left, from 1 (just started) to 0 (finished).
    var progress: Double {
        guard runDuration > 0 else { return 1 }
        return min(1, max(0, remaining / runDuration))
    }

    private init() {
        let initial = Self.clamp(Defaults[.timerLastDuration])
        duration = initial
        remaining = initial
        runDuration = initial

        // Stop any countdown when the feature gets turned off
        Defaults.publisher(.enableTimer)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self = self, !change.newValue else { return }
                    self.reset()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Configuration

    func setDuration(_ newValue: TimeInterval) {
        let clamped = Self.clamp(newValue)
        duration = clamped
        Defaults[.timerLastDuration] = clamped
        if state == .idle || state == .finished {
            stopTicker()
            endDate = nil
            state = .idle
            remaining = clamped
            runDuration = clamped
        }
    }

    // MARK: - Controls

    func start() {
        runDuration = duration
        remaining = duration
        endDate = Date().addingTimeInterval(duration)
        state = .running
        startTicker()
    }

    func pause() {
        guard state == .running, let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        self.endDate = nil
        stopTicker()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        endDate = Date().addingTimeInterval(remaining)
        state = .running
        startTicker()
    }

    func reset() {
        stopTicker()
        endDate = nil
        state = .idle
        remaining = duration
        runDuration = duration
    }

    /// Adds (or removes, when negative) time: extends a running or paused countdown,
    /// adjusts the selected duration while idle, and starts a short new run once finished.
    func add(seconds: TimeInterval) {
        switch state {
        case .idle:
            setDuration(duration + seconds)
        case .running:
            guard let endDate else { return }
            let extra = cappedExtra(seconds, current: endDate.timeIntervalSinceNow)
            self.endDate = endDate.addingTimeInterval(extra)
            runDuration += extra
            tick()
        case .paused:
            let extra = cappedExtra(seconds, current: remaining)
            remaining += extra
            runDuration += extra
        case .finished:
            guard seconds > 0 else { return }
            let length = min(seconds, Self.maximumDuration)
            runDuration = length
            remaining = length
            endDate = Date().addingTimeInterval(length)
            state = .running
            startTicker()
        }
    }

    // MARK: - Ticking

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        timer.tolerance = 0.05
        // `.common` keeps the countdown updating while menus or scroll views track events
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard state == .running, let endDate else { return }
        let left = endDate.timeIntervalSinceNow
        if left <= 0 {
            finish()
        } else {
            remaining = left
        }
    }

    private func finish() {
        stopTicker()
        endDate = nil
        remaining = 0
        state = .finished

        if Defaults[.timerPlaySound] {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
        // Briefly widen the closed-notch live activity to announce the end
        if Defaults[.enableTimer] && Defaults[.timerLiveActivity] {
            BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .timer)
        }
    }

    // MARK: - Helpers

    private func cappedExtra(_ seconds: TimeInterval, current: TimeInterval) -> TimeInterval {
        // Never push past the maximum, and never drop below one second left
        let target = min(Self.maximumDuration, max(1, current + seconds))
        return target - current
    }

    private static func clamp(_ value: TimeInterval) -> TimeInterval {
        min(maximumDuration, max(minimumDuration, value))
    }

    /// Formats a duration as `M:SS`, or `H:MM:SS` from one hour up, rounding up to whole seconds.
    static func format(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval).rounded(.up))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
