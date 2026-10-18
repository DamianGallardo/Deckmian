//
//  LiveVideoFrameSink.swift
//  boringNotch
//
//  Created by Deckmian on 2026-10-18.
//

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Fans captured frames out to every visible `LiveVideoView`.
///
/// Called from the capture queue; renderers are registered from the main thread. The last
/// complete frame is kept so a view that appears while the video is paused is not left black.
final class LiveVideoFrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var renderers: [ObjectIdentifier: AVSampleBufferVideoRenderer] = [:]
    private var lastFrame: CMSampleBuffer?

    func register(_ renderer: AVSampleBufferVideoRenderer) {
        lock.lock()
        renderers[ObjectIdentifier(renderer)] = renderer
        let frame = lastFrame
        lock.unlock()
        if let frame { enqueue(frame, into: renderer) }
    }

    func unregister(_ renderer: AVSampleBufferVideoRenderer) {
        lock.lock()
        renderers.removeValue(forKey: ObjectIdentifier(renderer))
        lock.unlock()
    }

    /// Drops the retained frame (and its IOSurface) when capture stops.
    func reset() {
        lock.lock()
        lastFrame = nil
        let current = Array(renderers.values)
        lock.unlock()
        current.forEach { $0.flush(removingDisplayedImage: true, completionHandler: nil) }
    }

    func deliver(_ sampleBuffer: CMSampleBuffer) {
        guard Self.isCompleteFrame(sampleBuffer) else { return }
        Self.markDisplayImmediately(sampleBuffer)

        lock.lock()
        lastFrame = sampleBuffer
        let current = Array(renderers.values)
        lock.unlock()

        current.forEach { enqueue(sampleBuffer, into: $0) }
    }

    private func enqueue(_ sampleBuffer: CMSampleBuffer, into renderer: AVSampleBufferVideoRenderer) {
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
        guard renderer.isReadyForMoreMediaData else { return }
        renderer.enqueue(sampleBuffer)
    }

    /// ScreenCaptureKit also sends idle and blank frames without an image; only show complete ones.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard sampleBuffer.isValid, CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }

    /// Captured frames carry capture timestamps; show them as soon as they arrive.
    private static func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0
        else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}
