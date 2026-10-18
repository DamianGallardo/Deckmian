//
//  TimerLiveActivity.swift
//  boringNotch
//
//  Created by Deckmian on 2026-10-15.
//

import SwiftUI

/// Compact countdown shown around the closed notch: a progress ring on the left wing and the
/// remaining time on the right one. Briefly widens to announce "Time's up" when the timer ends.
struct TimerLiveActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var store = TimerStore.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared

    private var isExpanded: Bool {
        coordinator.expandingView.show && coordinator.expandingView.type == .timer
    }

    private var wingWidth: CGFloat {
        Self.wingWidth(remaining: store.remaining, expanded: isExpanded, notchHeight: vm.effectiveClosedNotchHeight)
    }

    private var indicatorSize: CGFloat {
        min(18, max(0, vm.effectiveClosedNotchHeight - 12))
    }

    private var timeColor: Color {
        switch store.state {
        case .finished: .effectiveAccent
        case .paused: .gray
        case .idle, .running: .white
        }
    }

    var body: some View {
        HStack {
            leadingWing
                .frame(width: wingWidth, alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width + -cornerRadiusInsets.closed.top)

            Text(TimerStore.format(store.remaining))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(timeColor)
                .contentTransition(.numericText(countsDown: true))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: wingWidth, alignment: .trailing)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
        .animation(.smooth, value: isExpanded)
        .animation(.smooth, value: store.state)
    }

    @ViewBuilder
    private var leadingWing: some View {
        if store.state == .finished {
            HStack(spacing: 4) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.effectiveAccent)
                    .symbolEffect(.pulse, isActive: true)

                if isExpanded {
                    Text("Time's up")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
        } else {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: store.progress)
                    .stroke(
                        Color.effectiveAccent.opacity(store.state == .paused ? 0.5 : 1),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: store.progress)
                if store.state == .paused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.gray)
                }
            }
            .frame(width: indicatorSize, height: indicatorSize)
        }
    }

    /// Width of each side wing; shared with the closed-notch hit area sizing in `ContentView`.
    static func wingWidth(remaining: TimeInterval, expanded: Bool, notchHeight: CGFloat) -> CGFloat {
        let content: CGFloat
        if expanded {
            content = 84
        } else if remaining.rounded(.up) >= 3600 {
            content = 52
        } else {
            content = 40
        }
        return max(max(0, notchHeight - 12), content)
    }
}
