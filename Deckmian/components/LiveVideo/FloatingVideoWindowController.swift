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
/// Drag anywhere to move (drop it on the notch to send the video back), drag edges or corners to
/// resize (the aspect ratio is locked to the video), double-click to enlarge. Hover shows
/// "Back to notch", "Enlarge" and close.
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

    /// Mouse-following drag (moving the panel, or a drag out of the notch).
    private var dragTimer: Timer?
    /// Cursor position relative to the panel's origin, as a fraction of its size.
    private var dragAnchor = CGPoint(x: 0.5, y: 0.5)
    private var dragBaseSize: NSSize = .zero
    private var isOverDropZone = false

    private var isEnlarged: Bool { frameBeforeEnlarge != nil }
    private var isDragging: Bool { dragTimer != nil }

    private static let dropZoneScale: CGFloat = 0.8
    private static let dropZoneAlpha: CGFloat = 0.6
    /// Area around the top center of a screen where dropping the panel returns it to the notch.
    private static let dropZoneSize = NSSize(width: 360, height: 90)

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

    /// Shows the panel centered under the cursor and keeps it there until the mouse is released.
    func showFollowingMouse() {
        let isNew = panel == nil
        if isNew { createPanel() }
        guard let panel else { return }

        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        panel.setFrame(
            NSRect(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2, width: size.width, height: size.height),
            display: true
        )
        if isNew {
            LiveVideoCapture.shared.acquire(.floatingWindow)
            panel.alphaValue = 1
        }
        panel.orderFrontRegardless()
        beginMouseDrag(anchor: CGPoint(x: 0.5, y: 0.5))
    }

    func close() {
        guard let panel else { return }
        stopDragTimer()
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
            // Resizing is done by the container's edge handles: borderless panels show no
            // native resize cursors.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Moving is handled by `beginMouseDrag` so the drop-on-notch hint can follow the cursor.
        panel.isMovableByWindowBackground = false
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
        container.onBeginMove = { [weak self] anchor in self?.beginMouseDrag(anchor: anchor) }
        container.onResize = { [weak self] startFrame, edges, delta in
            self?.resize(from: startFrame, edges: edges, delta: delta)
        }
        container.onEndResize = { [weak self] in self?.endResize() }
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

    // MARK: - Moving and drag back to the notch

    /// Moves the panel with the cursor until the left mouse button is released.
    ///
    /// Polls the global mouse state instead of relying on mouse-dragged events, so it also works
    /// when the drag started in the notch window (which keeps receiving those events).
    /// - Parameter anchor: cursor position inside the panel, as a fraction of its size.
    private func beginMouseDrag(anchor: CGPoint) {
        guard let panel else { return }
        stopDragTimer()
        dragAnchor = anchor
        dragBaseSize = panel.frame.size
        isOverDropZone = false

        // Scheduled on the main run loop, so the callback runs on the main thread.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated { FloatingVideoWindowController.shared.dragTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    private func dragTick() {
        guard let panel else {
            stopDragTimer()
            return
        }
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            endMouseDrag()
            return
        }

        let mouse = NSEvent.mouseLocation
        let overDropZone = Self.dropZone(containing: mouse) != nil
        if overDropZone != isOverDropZone {
            isOverDropZone = overDropZone
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = overDropZone ? Self.dropZoneAlpha : 1
            }
        }

        let scale = overDropZone ? Self.dropZoneScale : 1
        let size = NSSize(width: dragBaseSize.width * scale, height: dragBaseSize.height * scale)
        let origin = NSPoint(x: mouse.x - size.width * dragAnchor.x, y: mouse.y - size.height * dragAnchor.y)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func endMouseDrag() {
        stopDragTimer()
        guard let panel else { return }

        if isOverDropZone {
            isOverDropZone = false
            panel.setFrame(NSRect(origin: panel.frame.origin, size: dragBaseSize), display: false)
            LiveVideoCapture.shared.returnToNotch()
            return
        }

        panel.alphaValue = 1
        let target = clamped(panel.frame, to: nil)
        if target != panel.frame {
            isAnimatingFrame = true
            panel.setFrame(target, display: true, animate: true)
            isAnimatingFrame = false
        }
        saveFrame()
    }

    private func stopDragTimer() {
        dragTimer?.invalidate()
        dragTimer = nil
    }

    /// The notch drop area of the screen under `point`: the top center, around the notch.
    private static func dropZone(containing point: NSPoint) -> NSRect? {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return nil }
        let frame = screen.frame
        let zone = NSRect(
            x: frame.midX - dropZoneSize.width / 2,
            y: frame.maxY - dropZoneSize.height,
            width: dropZoneSize.width,
            height: dropZoneSize.height
        )
        return NSMouseInRect(point, zone, false) ? zone : nil
    }

    // MARK: - Resizing

    /// Resizes from an edge or corner drag, keeping the video's aspect ratio. The opposite edge
    /// (or corner) stays put; a single edge keeps the other axis centered.
    private func resize(from startFrame: NSRect, edges: ResizeEdges, delta: CGVector) {
        guard let panel else { return }
        let ratio = startFrame.width / max(startFrame.height, 1)

        var width = startFrame.width
        if edges.contains(.right) { width += delta.dx }
        if edges.contains(.left) { width -= delta.dx }
        var height = startFrame.height
        if edges.contains(.top) { height += delta.dy }
        if edges.contains(.bottom) { height -= delta.dy }

        // Follow whichever axis the user moved more.
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)
        if vertical && (!horizontal || abs(height - startFrame.height) * ratio > abs(width - startFrame.width)) {
            width = height * ratio
        }

        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 4000, height: 4000)
        let maxWidth = min(visible.width, visible.height * ratio)
        width = min(max(width, Self.minimumWidth), maxWidth)
        height = width / ratio

        var origin = startFrame.origin
        if edges.contains(.left) {
            origin.x = startFrame.maxX - width
        } else if !horizontal {
            origin.x = startFrame.midX - width / 2
        }
        if edges.contains(.bottom) {
            origin.y = startFrame.maxY - height
        } else if !vertical {
            origin.y = startFrame.midY - height / 2
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    private func endResize() {
        // A manual resize while enlarged becomes the new normal size.
        frameBeforeEnlarge = nil
        container?.isEnlarged = false
        panel?.invalidateShadow()
        saveFrame()
    }

    // MARK: - Frame persistence

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidResize(_ notification: Notification) {
        panel?.invalidateShadow()
    }

    private func saveFrame() {
        guard let panel, !isEnlarged, !isAnimatingFrame, !isDragging else { return }
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

/// Window edges grabbed by a resize handle.
fileprivate struct ResizeEdges: OptionSet {
    let rawValue: Int
    static let left = ResizeEdges(rawValue: 1 << 0)
    static let right = ResizeEdges(rawValue: 1 << 1)
    static let top = ResizeEdges(rawValue: 1 << 2)
    static let bottom = ResizeEdges(rawValue: 1 << 3)
}

/// Invisible strip along an edge or corner of the floating window that resizes it when dragged.
private final class ResizeHandleView: NSView {
    let edges: ResizeEdges
    var onResize: ((NSRect, ResizeEdges, CGVector) -> Void)?
    var onEnd: (() -> Void)?
    private var hoverArea: NSTrackingArea?

    init(edges: ResizeEdges) {
        self.edges = edges
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch edges {
            case [.top, .left]: position = .topLeft
            case [.top, .right]: position = .topRight
            case [.bottom, .left]: position = .bottomLeft
            case [.bottom, .right]: position = .bottomRight
            case .left: position = .left
            case .right: position = .right
            case .top: position = .top
            default: position = .bottom
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        if edges == .left || edges == .right { return .resizeLeftRight }
        if edges == .top || edges == .bottom { return .resizeUpDown }
        return .crosshair
    }

    // The panel never becomes key, so cursor rects would not apply; set the cursor on hover.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { cursor.set() }
    override func mouseMoved(with event: NSEvent) { cursor.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startFrame = window.frame
        let startMouse = NSEvent.mouseLocation
        cursor.set()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let mouse = NSEvent.mouseLocation
            onResize?(startFrame, edges, CGVector(dx: mouse.x - startMouse.x, dy: mouse.y - startMouse.y))
        }
        onEnd?()
    }
}

/// Root view of the floating window: video, resize handles, hover controls and an
/// "unavailable" label.
private final class FloatingVideoContainerView: NSView {
    var onBackToNotch: (() -> Void)?
    var onToggleEnlarge: (() -> Void)?
    /// Starts moving the window; the point is the cursor position as a fraction of the size.
    var onBeginMove: ((CGPoint) -> Void)?
    var onResize: ((NSRect, ResizeEdges, CGVector) -> Void)?
    var onEndResize: (() -> Void)?

    private static let edgeThickness: CGFloat = 6
    private static let cornerSize: CGFloat = 16
    private var handles: [ResizeHandleView] = []

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

        let allEdges: [ResizeEdges] = [
            .left, .right, .top, .bottom, [.top, .left], [.top, .right], [.bottom, .left], [.bottom, .right],
        ]
        for edges in allEdges {
            let handle = ResizeHandleView(edges: edges)
            handle.onResize = { [weak self] startFrame, edges, delta in self?.onResize?(startFrame, edges, delta) }
            handle.onEnd = { [weak self] in self?.onEndResize?() }
            addSubview(handle)
            handles.append(handle)
        }

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

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onToggleEnlarge?()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        onBeginMove?(CGPoint(x: point.x / bounds.width, y: point.y / bounds.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let edge = Self.edgeThickness, corner = Self.cornerSize
        let w = bounds.width, h = bounds.height
        for handle in handles {
            switch handle.edges {
            case .left: handle.frame = NSRect(x: 0, y: corner, width: edge, height: h - 2 * corner)
            case .right: handle.frame = NSRect(x: w - edge, y: corner, width: edge, height: h - 2 * corner)
            case .bottom: handle.frame = NSRect(x: corner, y: 0, width: w - 2 * corner, height: edge)
            case .top: handle.frame = NSRect(x: corner, y: h - edge, width: w - 2 * corner, height: edge)
            case [.bottom, .left]: handle.frame = NSRect(x: 0, y: 0, width: corner, height: corner)
            case [.bottom, .right]: handle.frame = NSRect(x: w - corner, y: 0, width: corner, height: corner)
            case [.top, .left]: handle.frame = NSRect(x: 0, y: h - corner, width: corner, height: corner)
            default: handle.frame = NSRect(x: w - corner, y: h - corner, width: corner, height: corner)
            }
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
