//
//  LiveVideoView.swift
//  Deckmian
//
//  Created by Deckmian on 2026-10-18.
//

import AppKit
import AVFoundation
import SwiftUI

/// Hosts an `AVSampleBufferDisplayLayer` fed by `LiveVideoCapture`.
///
/// It ignores mouse events so clicks reach the SwiftUI button (notch) or the window background
/// (floating window) behind it.
final class LiveVideoNSView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var isRegistered = false

    var fillsBounds: Bool = true {
        didSet { displayLayer.videoGravity = fillsBounds ? .resizeAspectFill : .resizeAspect }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let sink = LiveVideoCapture.shared.frameSink
        if window != nil, !isRegistered {
            sink.register(displayLayer.sampleBufferRenderer)
            isRegistered = true
        } else if window == nil, isRegistered {
            sink.unregister(displayLayer.sampleBufferRenderer)
            isRegistered = false
        }
    }
}

struct LiveVideoView: NSViewRepresentable {
    /// Aspect fill (artwork slot) when true, aspect fit (floating window) when false.
    var fill: Bool = true

    func makeNSView(context: Context) -> LiveVideoNSView {
        let view = LiveVideoNSView(frame: .zero)
        view.fillsBounds = fill
        return view
    }

    func updateNSView(_ nsView: LiveVideoNSView, context: Context) {
        if nsView.fillsBounds != fill { nsView.fillsBounds = fill }
    }
}
