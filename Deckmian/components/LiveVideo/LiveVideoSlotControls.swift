//
//  LiveVideoSlotControls.swift
//  Deckmian
//
//  Created by Deckmian on 2026-10-18.
//

import Defaults
import SwiftUI

/// Small buttons over the music artwork: pop out the live video or bring it back from the
/// floating window. Shows nothing when there is nothing to do.
struct LiveVideoSlotControls: View {
    @ObservedObject var capture = LiveVideoCapture.shared
    let isHovering: Bool

    var body: some View {
        Group {
            if capture.isEligible {
                if capture.isPoppedOut {
                    slotButton(
                        symbol: "pip",
                        help: "The video is playing in a floating window. Click to bring it back here.",
                        action: capture.returnToNotch
                    )
                } else if capture.state == .streaming, isHovering {
                    slotButton(symbol: "pip.exit", help: "Open the video in a floating window", action: capture.popOut)
                }
            }
        }
        .padding(4)
        .animation(.smooth(duration: 0.2), value: isHovering)
        .animation(.smooth(duration: 0.2), value: capture.state)
        .animation(.smooth(duration: 0.2), value: capture.isPoppedOut)
    }

    private func slotButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.black.opacity(0.6)))
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .help(help)
        .transition(.scale.combined(with: .opacity))
    }
}

/// One-click setup card shown over the artwork when Chrome plays a video that Deckmian could show
/// once a permission is granted. Never blocks the artwork for longer than the user wants: it can
/// be dismissed, and Settings keeps the same "Enable" button.
struct LiveVideoSetupCard: View {
    @ObservedObject var capture = LiveVideoCapture.shared
    @Default(.liveVideoSetupDismissed) private var isDismissed
    let cornerRadius: CGFloat

    private var isVisible: Bool {
        guard capture.isEligible, !capture.isPoppedOut, capture.state.needsSetup else { return false }
        // The restart step is the result of the user's own click, so it ignores the dismissal.
        return capture.state == .needsRestart || !isDismissed
    }

    var body: some View {
        ZStack {
            if isVisible {
                card
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: isVisible)
        .animation(.smooth(duration: 0.2), value: capture.isAwaitingScreenRecording)
    }

    private var card: some View {
        VStack(spacing: 6) {
            Text(message)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
            Button {
                capture.enable()
            } label: {
                Text(buttonTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(PlainButtonStyle())
            .help(help)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(alignment: .topTrailing) {
            if capture.state != .needsRestart {
                Button {
                    capture.dismissSetup()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .help("Not now")
                .padding(3)
            }
        }
    }

    private var message: String {
        switch capture.state {
        case .needsRestart:
            return "Restart Deckmian to finish"
        case .needsScreenRecordingPermission where capture.isAwaitingScreenRecording:
            return "Turn on Deckmian in System Settings"
        default:
            return "Show the video here?"
        }
    }

    private var buttonTitle: String {
        switch capture.state {
        case .needsRestart: return "Restart"
        case .needsScreenRecordingPermission where capture.isAwaitingScreenRecording: return "Open"
        default: return "Enable"
        }
    }

    private var help: String {
        switch capture.state {
        case .needsAccessibility:
            return "Deckmian needs Accessibility access to find the video playing in Chrome."
        case .needsScreenRecordingPermission:
            return "Deckmian needs Screen Recording access to show the Chrome video here and in a floating window."
        case .needsRestart:
            return "macOS applies Screen Recording access after Deckmian restarts. This takes a second."
        default:
            return ""
        }
    }
}

/// Registers the view as a live video consumer while it is on screen and `isActive` is true.
private struct LiveVideoConsumerModifier: ViewModifier {
    let consumer: LiveVideoCapture.Consumer
    let isActive: Bool
    @State private var isVisible = false
    @State private var isAcquired = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                sync()
            }
            .onDisappear {
                isVisible = false
                sync()
            }
            .onChange(of: isActive) { _, _ in sync() }
    }

    private func sync() {
        let shouldAcquire = isVisible && isActive
        guard shouldAcquire != isAcquired else { return }
        isAcquired = shouldAcquire
        if shouldAcquire {
            LiveVideoCapture.shared.acquire(consumer)
        } else {
            LiveVideoCapture.shared.release(consumer)
        }
    }
}

extension View {
    func liveVideoConsumer(_ consumer: LiveVideoCapture.Consumer, isActive: Bool) -> some View {
        modifier(LiveVideoConsumerModifier(consumer: consumer, isActive: isActive))
    }
}
