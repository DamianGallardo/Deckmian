//
//  LiveVideoCapture.swift
//  Deckmian
//
//  Created by Deckmian on 2026-10-18.
//

import AppKit
import Combine
import CoreMedia
import Defaults
import ScreenCaptureKit
import os

/// Streams the video playing in Google Chrome so it can replace the music artwork.
///
/// The Chrome window is captured with ScreenCaptureKit and cropped to the `<video>` element,
/// whose frame is polled through the Accessibility tree (via the XPC helper). Capture only runs
/// while someone shows it (the open notch's music widget or the floating window), the toggle is
/// on and the current Now Playing source is Chrome.
@MainActor
final class LiveVideoCapture: ObservableObject {
    static let shared = LiveVideoCapture()

    enum State: Equatable {
        case idle
        /// Accessibility trust is needed to find the video in Chrome.
        case needsAccessibility
        /// A video was found but Screen Recording is not granted yet.
        case needsScreenRecordingPermission
        /// Screen Recording was granted but only takes effect after relaunching.
        case needsRestart
        case notVisible
        case streaming
        case failed(String)

        /// States resolved by the one-click setup card.
        var needsSetup: Bool {
            switch self {
            case .needsAccessibility, .needsScreenRecordingPermission, .needsRestart: true
            default: false
            }
        }
    }

    enum Consumer: Hashable {
        case notchSlot
        case floatingWindow
    }

    /// The next permission step, independent of whether Chrome is playing (used by Settings).
    enum SetupStep: Equatable {
        case accessibility
        case screenRecording
        case restart
    }

    @Published private(set) var state: State = .idle
    /// Width / height of the captured video, used for the floating window.
    @Published private(set) var aspectRatio: CGFloat = 16.0 / 9.0
    @Published private(set) var isPoppedOut = false
    /// True when the toggle is on and Chrome is the current media source.
    @Published private(set) var isEligible = false
    /// True while waiting for the user to switch Screen Recording on in System Settings.
    @Published private(set) var isAwaitingScreenRecording = false
    /// Last known Accessibility trust (nil until checked).
    @Published private(set) var isAccessibilityTrusted: Bool?
    @Published private(set) var requiresRestart = false

    let frameSink = LiveVideoFrameSink()

    private var consumers: [Consumer: Int] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var pollTask: Task<Void, Never>?
    private var permissionWatchTask: Task<Void, Never>?

    private var stream: SCStream?
    private var streamOutput: LiveVideoStreamOutput?
    private var streamWindowKey: String?
    private var streamConfiguration: SCStreamConfiguration?
    private var retryAfter: Date = .distantPast
    private var lastTarget: BrowserVideoTarget?

    private static let log = Logger(subsystem: "com.deckmian.live-video", category: "capture")
    private static let pollInterval: Duration = .milliseconds(750)
    private static let maxOutputWidth: CGFloat = 1280
    private static let retryDelay: TimeInterval = 3
    private static let permissionPollInterval: Duration = .milliseconds(1500)
    private static let permissionWatchLimit: TimeInterval = 120
    private static let sampleQueue = DispatchQueue(label: "com.deckmian.liveVideo.frames", qos: .userInteractive)

    private init() {
        let musicManager = MusicManager.shared
        Publishers.CombineLatest(
            musicManager.$bundleIdentifier.removeDuplicates(),
            Defaults.publisher(.liveVideoArtwork).map(\.newValue).removeDuplicates()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] bundleIdentifier, enabled in
            Self.log.notice("source=\(bundleIdentifier ?? "nil", privacy: .public) enabled=\(enabled, privacy: .public)")
            self?.updateEligibility(enabled && bundleIdentifier == BrowserVideoLocator.chromeBundleIdentifier)
        }
        .store(in: &cancellables)
    }

    // MARK: - Consumers

    func acquire(_ consumer: Consumer) {
        consumers[consumer, default: 0] += 1
        reconcile()
    }

    func release(_ consumer: Consumer) {
        guard let count = consumers[consumer] else { return }
        consumers[consumer] = count > 1 ? count - 1 : nil
        reconcile()
    }

    // MARK: - Floating window

    func popOut() {
        guard isEligible, !isPoppedOut else { return }
        isPoppedOut = true
        FloatingVideoWindowController.shared.show()
    }

    /// Pops the video out from a drag that left the artwork slot: the floating window appears
    /// under the cursor and follows it until the mouse button is released.
    func popOutByDragging() {
        guard isEligible, state == .streaming, !isPoppedOut else { return }
        isPoppedOut = true
        FloatingVideoWindowController.shared.showFollowingMouse()
    }

    /// Closes the floating window and shows the video in the notch again.
    func returnToNotch() {
        guard isPoppedOut else { return }
        isPoppedOut = false
        FloatingVideoWindowController.shared.close()
    }

    // MARK: - Setup

    var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// The step `enable()` performs next, or nil when everything is granted.
    var pendingSetupStep: SetupStep? {
        if requiresRestart { return .restart }
        if isAccessibilityTrusted == false { return .accessibility }
        if !hasScreenRecordingPermission { return .screenRecording }
        return nil
    }

    /// Re-reads the permissions (Settings calls this when it appears).
    func refreshPermissions() async {
        isAccessibilityTrusted = await XPCHelperClient.shared.isAccessibilityAuthorized()
        objectWillChange.send()
    }

    /// The single "Enable" action: performs the next missing permission step.
    /// Only call from an explicit user action, since it may show system prompts.
    func enable() {
        Defaults[.liveVideoSetupDismissed] = false
        switch pendingSetupStep {
        case .accessibility:
            Task {
                isAccessibilityTrusted = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
            }
        case .screenRecording:
            requestScreenRecordingPermission()
        case .restart:
            ApplicationRelauncher.restart()
        case nil:
            retryAfter = .distantPast
        }
    }

    /// Hides the setup card in the notch; Settings keeps offering the "Enable" button.
    func dismissSetup() {
        Defaults[.liveVideoSetupDismissed] = true
    }

    private func requestScreenRecordingPermission() {
        let isFirstRequest = !Defaults[.liveVideoRequestedScreenRecording]
        Defaults[.liveVideoRequestedScreenRecording] = true
        // The first request shows the system alert (which offers to open System Settings);
        // later requests are silent, so open the Screen Recording pane directly.
        if !CGRequestScreenCaptureAccess() {
            if !isFirstRequest {
                Self.openPrivacySettings("Privacy_ScreenCapture")
            }
            watchScreenRecordingPermission()
        } else {
            retryAfter = .distantPast
        }
    }

    /// Polls for the grant for up to two minutes, then checks whether a relaunch is needed.
    private func watchScreenRecordingPermission() {
        permissionWatchTask?.cancel()
        isAwaitingScreenRecording = true
        permissionWatchTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.permissionWatchLimit)
            while !Task.isCancelled, Date() < deadline {
                if CGPreflightScreenCaptureAccess() {
                    await self?.screenRecordingWasGranted()
                    return
                }
                try? await Task.sleep(for: Self.permissionPollInterval)
            }
            self?.isAwaitingScreenRecording = false
        }
    }

    private func screenRecordingWasGranted() async {
        isAwaitingScreenRecording = false
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            requiresRestart = false
            retryAfter = .distantPast
        } catch {
            // macOS often applies the grant only to new processes.
            requiresRestart = true
            stopStream()
            if shouldRun { state = .needsRestart }
        }
    }

    var statusDescription: String {
        switch state {
        case .idle:
            switch pendingSetupStep {
            case .accessibility: return "Needs Accessibility access"
            case .screenRecording: return "Needs Screen Recording access"
            case .restart: return "Restart Deckmian to finish"
            case nil: return isEligible ? "Ready" : "Starts when Chrome plays a video"
            }
        case .needsAccessibility:
            return "Needs Accessibility access to find the video in Chrome"
        case .needsScreenRecordingPermission:
            return isAwaitingScreenRecording
                ? "Turn on Deckmian in System Settings"
                : "Needs Screen Recording access to show the video"
        case .needsRestart:
            return "Restart Deckmian to finish"
        case .notVisible:
            return "Keep the video in Chrome's front tab of a visible window"
        case .streaming:
            return "Showing live video"
        case .failed(let message):
            return "Capture failed: \(message)"
        }
    }

    private static func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Lifecycle

    private func updateEligibility(_ eligible: Bool) {
        guard eligible != isEligible else { return }
        isEligible = eligible
        if !eligible { returnToNotch() }
        reconcile()
        if eligible { prewarmLocator() }
    }

    /// One lookup as soon as Chrome becomes the media source, so Chrome builds its Accessibility
    /// tree before the notch opens and the first real lookup finds the video right away.
    private func prewarmLocator() {
        guard !shouldRun else { return }
        let title = MusicManager.shared.songTitle
        Task {
            let location = await BrowserVideoLocator.locate(preferredTitle: title)
            Self.log.notice("prewarm: \(String(describing: location), privacy: .public)")
        }
    }

    private var shouldRun: Bool {
        isEligible && !consumers.isEmpty
    }

    private func reconcile() {
        Self.log.notice("reconcile: eligible=\(self.isEligible, privacy: .public) consumers=\(self.consumers.count, privacy: .public)")
        if shouldRun {
            guard pollTask == nil else { return }
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.tick()
                    try? await Task.sleep(for: Self.pollInterval)
                }
            }
        } else {
            pollTask?.cancel()
            pollTask = nil
            stopStream()
            state = .idle
        }
    }

    private func tick() async {
        guard shouldRun else { return }

        let location = await BrowserVideoLocator.locate(preferredTitle: MusicManager.shared.songTitle)
        guard shouldRun, !Task.isCancelled else { return }
        Self.log.notice("tick: \(String(describing: location), privacy: .public) screenRecording=\(self.hasScreenRecordingPermission, privacy: .public) restart=\(self.requiresRestart, privacy: .public)")

        switch location {
        case .needsAccessibility:
            isAccessibilityTrusted = false
            stopStream()
            state = .needsAccessibility
        case .found(let target):
            isAccessibilityTrusted = true
            if requiresRestart {
                stopStream()
                state = .needsRestart
            } else if !hasScreenRecordingPermission {
                stopStream()
                state = .needsScreenRecordingPermission
            } else {
                await show(target)
            }
        case .chromeNotRunning, .notVisible:
            stopStream()
            state = .notVisible
        }
    }

    // MARK: - Stream

    private func show(_ target: BrowserVideoTarget) async {
        lastTarget = target

        if let stream, let configuration = streamConfiguration, streamWindowKey == target.windowKey {
            // Same window: follow scrolling and resizes without restarting.
            let scale = streamOutput?.pointPixelScale ?? 2
            guard let crop = Self.cropRect(for: target, scale: scale) else {
                stopStream()
                state = .notVisible
                return
            }
            if Self.apply(crop, scale: scale, to: configuration) {
                do {
                    try await stream.updateConfiguration(configuration)
                    updateAspectRatio(crop.size)
                } catch {
                    handleStreamFailure(error)
                }
            }
            if self.stream != nil { state = .streaming }
            return
        }

        stopStream()
        guard Date() >= retryAfter else { return }
        await startStream(for: target)
    }

    private func startStream(for target: BrowserVideoTarget) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard shouldRun, lastTarget?.windowKey == target.windowKey else { return }
            guard let window = Self.matchWindow(for: target, in: content.windows) else {
                Self.log.notice("startStream: no SCWindow matches the located window")
                state = .notVisible
                return
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            guard let crop = Self.cropRect(for: target, scale: scale) else {
                state = .notVisible
                return
            }

            let configuration = SCStreamConfiguration()
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.showsCursor = false
            configuration.queueDepth = 5
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            configuration.ignoreShadowsSingleWindow = true
            _ = Self.apply(crop, scale: scale, to: configuration)

            let output = LiveVideoStreamOutput(sink: frameSink, pointPixelScale: scale) { [weak self] outputID, error in
                Task { @MainActor in
                    // Ignore late errors from a stream that has already been replaced.
                    guard let self, let current = self.streamOutput, ObjectIdentifier(current) == outputID else { return }
                    self.handleStreamFailure(error)
                }
            }
            let newStream = SCStream(filter: filter, configuration: configuration, delegate: output)
            try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: Self.sampleQueue)
            try await newStream.startCapture()

            // The consumers may have gone away (or a newer poll took over) while starting.
            guard shouldRun, !Task.isCancelled, stream == nil else {
                try? await newStream.stopCapture()
                return
            }
            stream = newStream
            streamOutput = output
            streamWindowKey = target.windowKey
            streamConfiguration = configuration
            updateAspectRatio(crop.size)
            state = .streaming
            Self.log.notice("startStream: streaming crop=\(NSStringFromRect(crop), privacy: .public)")
        } catch {
            handleStreamFailure(error)
        }
    }

    private func stopStream() {
        guard let stream else { return }
        let output = streamOutput
        self.stream = nil
        streamOutput = nil
        streamWindowKey = nil
        streamConfiguration = nil
        frameSink.reset()
        Task {
            try? await stream.stopCapture()
            _ = output
        }
    }

    private func handleStreamFailure(_ error: Error) {
        Self.log.error("stream failure: \(String(describing: error), privacy: .public)")
        stopStream()
        retryAfter = Date().addingTimeInterval(Self.retryDelay)
        let declined = (error as? SCStreamError)?.code == .userDeclined
        if declined || !hasScreenRecordingPermission {
            // Granted in System Settings but this process still cannot capture: relaunch needed.
            if hasScreenRecordingPermission { requiresRestart = true }
            state = requiresRestart ? .needsRestart : .needsScreenRecordingPermission
        } else if shouldRun {
            state = .failed(error.localizedDescription)
        }
    }

    private func updateAspectRatio(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let ratio = size.width / size.height
        if abs(ratio - aspectRatio) > 0.01 { aspectRatio = ratio }
    }

    // MARK: - Geometry

    /// Matches the located window to a capturable one: by `CGWindowID`, then frame, then title.
    private static func matchWindow(for target: BrowserVideoTarget, in windows: [SCWindow]) -> SCWindow? {
        if let windowID = target.cgWindowID, let exact = windows.first(where: { $0.windowID == windowID }) {
            return exact
        }
        let chromeWindows = windows.filter {
            $0.owningApplication?.bundleIdentifier == BrowserVideoLocator.chromeBundleIdentifier && $0.windowLayer == 0
        }
        func distance(_ window: SCWindow) -> CGFloat {
            let a = window.frame, b = target.windowBounds
            return abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
        }
        if let byFrame = chromeWindows.min(by: { distance($0) < distance($1) }), distance(byFrame) < 16 {
            return byFrame
        }
        guard !target.title.isEmpty else { return nil }
        return chromeWindows.first { ($0.title ?? "").localizedCaseInsensitiveContains(target.title) }
    }

    /// The video's visible frame in window points (the stream's `sourceRect`), clamped to the window.
    static func cropRect(for target: BrowserVideoTarget, scale: CGFloat) -> CGRect? {
        let window = target.windowBounds.size
        guard window.width > 0, window.height > 0 else { return nil }

        let rect: CGRect
        switch target.geometry {
        case .screen(let screenRect):
            rect = screenRect.offsetBy(dx: -target.windowBounds.minX, dy: -target.windowBounds.minY)
        case .page(let page):
            guard let pageRect = pageCropRect(page, window: window, scale: scale) else { return nil }
            rect = pageRect
        }

        let clamped = rect.intersection(CGRect(origin: .zero, size: window)).integral
        guard !clamped.isNull, clamped.width >= 16, clamped.height >= 16 else { return nil }
        return clamped
    }

    /// Maps a CSS-pixel rect into window points (JavaScript fallback only).
    ///
    /// The page zoom comes from `devicePixelRatio / backing scale`, falling back to the ratio of
    /// window width to `outerWidth`. The viewport is assumed to sit at the bottom of the window,
    /// horizontally centered (Chrome's tab strip and toolbar are above it).
    private static func pageCropRect(
        _ page: BrowserVideoTarget.PageGeometry, window: CGSize, scale: CGFloat
    ) -> CGRect? {
        let viewport = page.viewportSize
        guard viewport.width > 0, viewport.height > 0 else { return nil }

        func fits(_ zoom: CGFloat) -> Bool {
            zoom > 0.2 && zoom < 6
                && viewport.width * zoom <= window.width + 2
                && viewport.height * zoom <= window.height + 2
        }
        var zoom: CGFloat = 1
        if scale > 0, fits(page.devicePixelRatio / scale) {
            zoom = page.devicePixelRatio / scale
        } else if page.outerSize.width > 0, fits(window.width / page.outerSize.width) {
            zoom = window.width / page.outerSize.width
        }

        let offsetX = max(0, (window.width - viewport.width * zoom) / 2)
        let offsetY = max(0, window.height - viewport.height * zoom)
        return CGRect(
            x: page.videoRect.minX * zoom + offsetX,
            y: page.videoRect.minY * zoom + offsetY,
            width: page.videoRect.width * zoom,
            height: page.videoRect.height * zoom
        )
    }

    /// Writes the crop and output size into `configuration`. Returns false when nothing changed.
    private static func apply(_ crop: CGRect, scale: CGFloat, to configuration: SCStreamConfiguration) -> Bool {
        let pixelWidth = min(crop.width * max(scale, 1), maxOutputWidth)
        let pixelHeight = pixelWidth * crop.height / crop.width
        let width = max(2, Int(pixelWidth.rounded()) & ~1)
        let height = max(2, Int(pixelHeight.rounded()) & ~1)

        guard configuration.sourceRect != crop || configuration.width != width || configuration.height != height else {
            return false
        }
        configuration.sourceRect = crop
        configuration.width = width
        configuration.height = height
        return true
    }
}

/// Receives ScreenCaptureKit frames on the capture queue and forwards them to the frame sink.
final class LiveVideoStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let pointPixelScale: CGFloat
    private let sink: LiveVideoFrameSink
    private let onStop: @Sendable (ObjectIdentifier, Error) -> Void

    init(
        sink: LiveVideoFrameSink,
        pointPixelScale: CGFloat,
        onStop: @escaping @Sendable (ObjectIdentifier, Error) -> Void
    ) {
        self.sink = sink
        self.pointPixelScale = pointPixelScale
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        sink.deliver(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(ObjectIdentifier(self), error)
    }
}
