//
//  FloatingVideoWindowController.swift
//  Deckmian
//
//  Created by Deckmian on 2026-10-18.
//

import AppKit
import Combine
import Defaults

/// Borderless panel that never becomes key, so Chrome keeps keyboard focus (space to pause).
private final class FloatingVideoPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A movable, resizable floating window showing the live Chrome video.
///
/// Drag anywhere to move, drag edges or corners to resize (the aspect ratio is locked to the
/// video), double-click to enlarge. Hover shows "Back to notch", "Enlarge" and close.
@MainActor
final class FloatingVideoWindowController: NSObject, NSWindowDelegate {
    static let shared = FloatingVideoWindowController()

    private static let minimumWidth: CGFloat = 240
    private static let defaultWidth: CGFloat = 480
    private static let enlargedScreenFraction: CGFloat = 0.6

    private var panel: FloatingVideoPanel?
    private var container: FloatingVideoContainerView?
    private var cancellables = Set<AnyCancellable>()
    /// The user's frame while enlarged, restored when shrinking back.
    private var frameBeforeEnlarge: NSRect?
    private var isAnimatingFrame = false

    private var isEnlarged: Bool { frameBeforeEnlarge != nil }

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        createPanel()
        guard let panel else { return }
        LiveVideoCapture.shared.acquire(.floatingWindow)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        container = nil
        cancellables.removeAll()
        frameBeforeEnlarge = nil
        panel.delegate = nil
        LiveVideoCapture.shared.release(.floatingWindow)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        }
    }

    // MARK: - Setup

    private func createPanel() {
        let capture = LiveVideoCapture.shared
        let frame = restoredFrame(aspectRatio: capture.aspectRatio)

        let panel = FloatingVideoPanel(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self

        let container = FloatingVideoContainerView(frame: NSRect(origin: .zero, size: frame.size))
        container.onBackToNotch = { LiveVideoCapture.shared.returnToNotch() }
        container.onToggleEnlarge = { [weak self] in self?.toggleEnlarge() }
        panel.contentView = container

        self.panel = panel
        self.container = container
        applyAspectRatio(capture.aspectRatio, resize: false)

        capture.$aspectRatio
            .removeDuplicates()
            .sink { [weak self] ratio in self?.applyAspectRatio(ratio, resize: true) }
            .store(in: &cancellables)
        capture.$state
            .sink { [weak self] state in self?.container?.showsUnavailable = state != .streaming }
            .store(in: &cancellables)
    }

    private func applyAspectRatio(_ ratio: CGFloat, resize: Bool) {
        guard let panel, ratio > 0 else { return }
        panel.contentAspectRatio = NSSize(width: ratio, height: 1)
        panel.contentMinSize = NSSize(width: Self.minimumWidth, height: Self.minimumWidth / ratio)
        if let screen = panel.screen ?? NSScreen.main {
            panel.contentMaxSize = screen.visibleFrame.size
        }
        guard resize else { return }
        // Keep the width and the center, adjust the height to the new ratio.
        var frame = panel.frame
        let height = frame.width / ratio
        frame.origin.y += (frame.height - height) / 2
        frame.size.height = height
        panel.setFrame(clamped(frame, to: panel.screen), display: true)
    }

    // MARK: - Enlarge

    func toggleEnlarge() {
        guard let panel else { return }
        let target: NSRect
        if let previous = frameBeforeEnlarge {
            target = previous
            frameBeforeEnlarge = nil
        } else {
            guard let screen = panel.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            let ratio = LiveVideoCapture.shared.aspectRatio
            var width = visible.width * Self.enlargedScreenFraction
            var height = width / ratio
            if height > visible.height * 0.9 {
                height = visible.height * 0.9
                width = height * ratio
            }
            frameBeforeEnlarge = panel.frame
            target = NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
        }
        container?.isEnlarged = isEnlarged
        isAnimatingFrame = true
        panel.setFrame(target, display: true, animate: true)
        isAnimatingFrame = false
        panel.invalidateShadow()
        if !isEnlarged { saveFrame() }
    }

    // MARK: - Frame persistence

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // A manual resize while enlarged becomes the new normal size.
        frameBeforeEnlarge = nil
        container?.isEnlarged = false
        panel?.invalidateShadow()
        saveFrame()
    }

    func windowDidResize(_ notification: Notification) {
        panel?.invalidateShadow()
    }

    private func saveFrame() {
        guard let panel, !isEnlarged, !isAnimatingFrame else { return }
        Defaults[.floatingVideoFrame] = NSStringFromRect(panel.frame)
    }

    private func restoredFrame(aspectRatio: CGFloat) -> NSRect {
        let ratio = aspectRatio > 0 ? aspectRatio : 16.0 / 9.0
        let saved = NSRectFromString(Defaults[.floatingVideoFrame])
        if saved.width >= Self.minimumWidth,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            var frame = saved
            frame.size.height = frame.width / ratio
            return clamped(frame, to: nil)
        }

        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = Self.defaultWidth
        let height = width / ratio
        return NSRect(x: visible.maxX - width - 24, y: visible.minY + 24, width: width, height: height)
    }

    /// Fits `frame` inside the visible frame of the screen it overlaps most.
    private func clamped(_ frame: NSRect, to preferredScreen: NSScreen?) -> NSRect {
        let screen = preferredScreen
            ?? NSScreen.screens.max { overlap($0, frame) < overlap($1, frame) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }

        var result = frame
        if result.width > visible.width || result.height > visible.height {
            let scale = min(visible.width / result.width, visible.height / result.height)
            result.size = NSSize(width: result.width * scale, height: result.height * scale)
        }
        result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(result.minY, visible.minY), visible.maxY - result.height)
        return result
    }

    private func overlap(_ screen: NSScreen, _ frame: NSRect) -> CGFloat {
        let intersection = screen.visibleFrame.intersection(frame)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

// MARK: - Content

/// Root view of the floating window: video, hover controls and an "unavailable" label.
private final class FloatingVideoContainerView: NSView {
    var onBackToNotch: (() -> Void)?
    var onToggleEnlarge: (() -> Void)?

    var isEnlarged = false {
        didSet { updateEnlargeButton() }
    }

    var showsUnavailable = false {
        didSet { unavailableLabel.isHidden = !showsUnavailable }
    }

    private let videoView = LiveVideoNSView(frame: .zero)
    private let controls = NSStackView()
    private let enlargeButton = NSButton()
    private let unavailableLabel = NSTextField(labelWithString: "Video unavailable")
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        videoView.fillsBounds = false
        videoView.frame = bounds
        videoView.autoresizingMask = [.width, .height]
        addSubview(videoView)

        unavailableLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        unavailableLabel.font = .systemFont(ofSize: 13, weight: .medium)
        unavailableLabel.translatesAutoresizingMaskIntoConstraints = false
        unavailableLabel.isHidden = true
        addSubview(unavailableLabel)

        let backButton = makeButton(symbol: "pip.enter", tooltip: "Back to notch", action: #selector(backToNotch))
        let closeButton = makeButton(symbol: "xmark", tooltip: "Close", action: #selector(backToNotch))
        configure(enlargeButton, action: #selector(toggleEnlarge))
        updateEnlargeButton()

        controls.orientation = .horizontal
        controls.spacing = 6
        controls.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        controls.layer?.cornerRadius = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.alphaValue = 0
        [backButton, enlargeButton, closeButton].forEach(controls.addArrangedSubview)
        addSubview(controls)

        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            unavailableLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            unavailableLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Mouse

    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onToggleEnlarge?()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setControlsVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        setControlsVisible(false)
    }

    private func setControlsVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            controls.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: Buttons

    private func makeButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton()
        configure(button, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.toolTip = tooltip
        return button
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func updateEnlargeButton() {
        let symbol = isEnlarged ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        let tooltip = isEnlarged ? "Restore size" : "Enlarge"
        enlargeButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        enlargeButton.toolTip = tooltip
    }

    @objc private func backToNotch() {
        onBackToNotch?()
    }

    @objc private func toggleEnlarge() {
        onToggleEnlarge?()
    }
}
