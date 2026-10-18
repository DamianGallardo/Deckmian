//
//  TimerView.swift
//  boringNotch
//
//  Created by Deckmian on 2026-10-15.
//

import SwiftUI

struct TimerView: View {
    @ObservedObject var store = TimerStore.shared

    var body: some View {
        HStack(spacing: 16) {
            clock
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)
                .padding(.vertical, 4)

            controls
                .frame(width: 262)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    store.state == .finished ? Color.effectiveAccent.opacity(0.6) : Color.white.opacity(0.1),
                    lineWidth: 1
                )
        }
        .animation(.smooth, value: store.state)
    }

    // MARK: - Clock

    private var clock: some View {
        HStack(spacing: 14) {
            TimerRing(progress: store.progress, state: store.state)
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(store.state == .finished ? Color.effectiveAccent : Color.gray)
                    .textCase(.uppercase)

                Text(TimerStore.format(store.remaining))
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(store.state == .paused ? Color.gray : Color.white)
                    .contentTransition(.numericText(countsDown: true))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if store.state != .idle {
                    Text("of \(TimerStore.format(store.runDuration))")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Color.gray.opacity(0.7))
                }
            }
        }
    }

    private var statusText: String {
        switch store.state {
        case .idle: "Ready"
        case .running: "Running"
        case .paused: "Paused"
        case .finished: "Time's up"
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            presets
            actions
        }
    }

    private var canPickPreset: Bool {
        store.state == .idle || store.state == .finished
    }

    private var presets: some View {
        HStack(spacing: 6) {
            ForEach(TimerStore.presets, id: \.self) { preset in
                let isSelected = store.state == .idle && store.duration == preset
                Button {
                    withAnimation(.smooth) { store.setDuration(preset) }
                } label: {
                    Text("\(Int(preset / 60))m")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .foregroundStyle(isSelected ? Color.white : Color.gray)
                        .background {
                            Capsule()
                                .fill(isSelected ? Color.effectiveAccent.opacity(0.35) : Color.white.opacity(0.06))
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(!canPickPreset)
        .opacity(canPickPreset ? 1 : 0.4)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch store.state {
            case .idle:
                TimerIconButton(icon: "minus", help: "Remove 1 minute") {
                    store.add(seconds: -60)
                }
                .disabled(store.duration <= TimerStore.minimumDuration)

                TimerIconButton(icon: "plus", help: "Add 1 minute") {
                    store.add(seconds: 60)
                }
                .disabled(store.duration >= TimerStore.maximumDuration)

                Spacer(minLength: 0)

                TimerActionButton(title: "Start", icon: "play.fill", prominent: true) {
                    store.start()
                }

            case .running, .paused:
                TimerActionButton(title: "+1 min", icon: nil) {
                    store.add(seconds: 60)
                }

                Spacer(minLength: 0)

                TimerActionButton(title: "Reset", icon: "arrow.counterclockwise") {
                    store.reset()
                }

                if store.state == .running {
                    TimerActionButton(title: "Pause", icon: "pause.fill", prominent: true) {
                        store.pause()
                    }
                } else {
                    TimerActionButton(title: "Resume", icon: "play.fill", prominent: true) {
                        store.resume()
                    }
                }

            case .finished:
                TimerActionButton(title: "+1 min", icon: nil) {
                    store.add(seconds: 60)
                }

                Spacer(minLength: 0)

                TimerActionButton(title: "Reset", icon: "arrow.counterclockwise") {
                    store.reset()
                }

                TimerActionButton(title: "Restart", icon: "play.fill", prominent: true) {
                    store.start()
                }
            }
        }
        .frame(height: 30)
    }
}

// MARK: - Components

/// Circular progress ring that drains as the countdown runs.
struct TimerRing: View {
    let progress: Double
    let state: TimerState
    var lineWidth: CGFloat = 6

    private var icon: String {
        switch state {
        case .idle: "timer"
        case .running: "hourglass"
        case .paused: "pause.fill"
        case .finished: "bell.fill"
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: state == .finished ? 1 : progress)
                .stroke(
                    Color.effectiveAccent.opacity(state == .paused ? 0.5 : 1),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)

            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(state == .finished ? Color.effectiveAccent : Color.gray)
                .symbolEffect(.pulse, isActive: state == .finished)
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

private struct TimerIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(isEnabled ? Color.white : Color.gray.opacity(0.5))
                .background {
                    Circle().fill(Color.white.opacity(0.06))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct TimerActionButton: View {
    let title: String
    let icon: String?
    var prominent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .foregroundStyle(prominent ? Color.white : Color.gray)
            .background {
                Capsule()
                    .fill(prominent ? Color.effectiveAccent : Color.white.opacity(0.06))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
