//
//  DeckmianXPCHelper+LiveVideo.swift
//  DeckmianXPCHelper
//
//  Created by Deckmian on 2026-10-18.
//

import AppKit
import ApplicationServices
import os
import Darwin

// MARK: - Live video

/// Finds the `<video>` playing in Google Chrome through the Accessibility tree, which needs no
/// Chrome setting and no Automation consent (only the Accessibility trust the helper already uses).
extension DeckmianXPCHelper {

    @objc func locateChromeVideo(_ preferredTitle: String, with reply: @escaping ([String: String]) -> Void) {
        ChromeVideoAXLocator.queue.async {
            reply(ChromeVideoAXLocator.locate(preferredTitle: preferredTitle))
        }
    }
}

/// Private but long-standing AX call that returns the `CGWindowID` of a window element.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

enum ChromeVideoAXLocator {
    static let log = Logger(subsystem: "com.deckmian.live-video", category: "helper")
    static let queue = DispatchQueue(label: "com.deckmian.helper.liveVideo", qos: .userInitiated)

    private static let chromeBundleIdentifier = "com.google.Chrome"
    /// Total time spent walking the tree per call, so a huge page never stalls the poll.
    private static let timeBudget: TimeInterval = 0.15
    private static let maxNodes = 6000
    private static let maxDepth = 48
    /// Smallest visible size (points) considered a real video rather than a thumbnail.
    private static let minimumVisibleSize = CGSize(width: 80, height: 45)

    /// Processes for which web accessibility was already switched on (touched only on `queue`).
    nonisolated(unsafe) private static var enabledProcesses = Set<pid_t>()

    /// Roles whose subtrees are browser UI or text, never the page's video.
    private static let skippedRoles: Set<String> = [
        "AXToolbar", "AXTabGroup", "AXMenuBar", "AXMenu", "AXStaticText", "AXTextField",
        "AXTextArea", "AXButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXSlider",
        "AXScrollBar", "AXImage",
    ]

    private enum MatchKind: Int, Comparable {
        /// YouTube's player box (may include black bars in theater mode).
        case playerContainer = 1
        /// The `<video>` element itself.
        case video = 2

        static func < (lhs: MatchKind, rhs: MatchKind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct Match {
        var kind: MatchKind
        var visibleFrame: CGRect
        var area: CGFloat { visibleFrame.width * visibleFrame.height }
    }

    private struct WindowMatch {
        var windowID: CGWindowID
        var windowFrame: CGRect
        var title: String
        var match: Match
    }

    // MARK: Entry point

    static func locate(preferredTitle: String) -> [String: String] {
        guard AXIsProcessTrusted() else {
            log.notice("locate: helper is not trusted for Accessibility")
            return status(ChromeVideoKeys.statusNotTrusted)
        }
        guard let chromePID = chromeProcessIdentifier() else {
            log.notice("locate: Chrome process not found")
            return status(ChromeVideoKeys.statusChromeNotRunning)
        }

        let app = AXUIElementCreateApplication(chromePID)
        AXUIElementSetMessagingTimeout(app, 0.3)
        enableWebAccessibility(app, pid: chromePID)

        guard let windows = copyValue(app, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else {
            log.notice("locate: Chrome exposes no AX windows")
            return status(ChromeVideoKeys.statusNotFound)
        }
        log.notice("locate: \(windows.count, privacy: .public) Chrome windows, title hint '\(preferredTitle, privacy: .public)'")

        let title = preferredTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Search the window showing the current song first, then front to back.
        let ordered = windows.enumerated().sorted { lhs, rhs in
            let l = matchesTitle(lhs.element, title), r = matchesTitle(rhs.element, title)
            return l != r ? l : lhs.offset < rhs.offset
        }.map(\.element)

        let deadline = Date().addingTimeInterval(timeBudget)
        var matches: [WindowMatch] = []
        for window in ordered {
            guard Date() < deadline else { break }
            if copyValue(window, kAXMinimizedAttribute) as? Bool == true { continue }
            guard let windowFrame = frame(of: window), windowFrame.width > 0, windowFrame.height > 0 else { continue }
            guard let match = searchVideo(in: window, windowFrame: windowFrame, deadline: deadline) else { continue }

            var windowID: CGWindowID = 0
            _ = _AXUIElementGetWindow(window, &windowID)
            matches.append(WindowMatch(
                windowID: windowID,
                windowFrame: windowFrame,
                title: copyValue(window, kAXTitleAttribute) as? String ?? "",
                match: match
            ))
            // The window that shows the current song wins outright.
            if !title.isEmpty, matches.last?.title.localizedCaseInsensitiveContains(title) == true { break }
        }

        guard let best = matches.max(by: { score($0, title) < score($1, title) }) else {
            log.notice("locate: no video match in any window")
            if let first = ordered.first { logSample(of: first) }
            return status(ChromeVideoKeys.statusNotFound)
        }
        log.notice("locate: found kind=\(best.match.kind.rawValue, privacy: .public) frame=\(NSStringFromRect(best.match.visibleFrame), privacy: .public) window=\(best.windowID, privacy: .public)")

        let video = best.match.visibleFrame
        return [
            ChromeVideoKeys.status: ChromeVideoKeys.statusFound,
            ChromeVideoKeys.windowID: String(best.windowID),
            ChromeVideoKeys.windowX: String(Double(best.windowFrame.minX)),
            ChromeVideoKeys.windowY: String(Double(best.windowFrame.minY)),
            ChromeVideoKeys.windowWidth: String(Double(best.windowFrame.width)),
            ChromeVideoKeys.windowHeight: String(Double(best.windowFrame.height)),
            ChromeVideoKeys.videoX: String(Double(video.minX)),
            ChromeVideoKeys.videoY: String(Double(video.minY)),
            ChromeVideoKeys.videoWidth: String(Double(video.width)),
            ChromeVideoKeys.videoHeight: String(Double(video.height)),
            ChromeVideoKeys.title: best.title,
            ChromeVideoKeys.kind: best.match.kind == .video ? ChromeVideoKeys.kindVideo : ChromeVideoKeys.kindPlayer,
        ]
    }

    private static func status(_ value: String) -> [String: String] {
        [ChromeVideoKeys.status: value]
    }

    private static func score(_ candidate: WindowMatch, _ title: String) -> (Int, Int, CGFloat) {
        let titleMatch = !title.isEmpty && candidate.title.localizedCaseInsensitiveContains(title)
        return (titleMatch ? 1 : 0, candidate.match.kind.rawValue, candidate.match.area)
    }

    private static func matchesTitle(_ window: AXUIElement, _ title: String) -> Bool {
        guard !title.isEmpty, let windowTitle = copyValue(window, kAXTitleAttribute) as? String else { return false }
        return windowTitle.localizedCaseInsensitiveContains(title)
    }

    /// Chrome only builds the web content tree for assistive clients; ask for it explicitly.
    private static func enableWebAccessibility(_ app: AXUIElement, pid: pid_t) {
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if manual != .success {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        if !enabledProcesses.contains(pid) {
            enabledProcesses.insert(pid)
            // Give Chrome a moment to build the tree the first time.
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    // MARK: Tree search

    private struct Node {
        var element: AXUIElement
        var depth: Int
        /// Visible region for this subtree: the window, narrowed by each web area (viewport).
        var clip: CGRect
    }

    private static let nodeAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute,
        "AXDOMIdentifier", "AXDOMClassList", kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
    ]

    /// Breadth-first search for the largest visible video (or YouTube player) in a window.
    private static func searchVideo(in window: AXUIElement, windowFrame: CGRect, deadline: Date) -> Match? {
        var queue = [Node(element: window, depth: 0, clip: windowFrame)]
        var index = 0
        var best: Match?

        while index < queue.count, index < maxNodes, Date() < deadline {
            let node = queue[index]
            index += 1

            let values = copyValues(node.element, nodeAttributes)
            let role = values[0] as? String ?? ""
            let subrole = values[1] as? String ?? ""
            let roleDescription = values[2] as? String ?? ""
            let domIdentifier = values[3] as? String ?? ""
            let classes = values[4] as? [String] ?? []
            let elementFrame = rect(position: values[5], size: values[6])

            var clip = node.clip
            if role == "AXWebArea", let elementFrame {
                clip = clip.intersection(elementFrame)
                if clip.isNull { continue }
            }

            if let kind = classify(
                role: role, subrole: subrole, roleDescription: roleDescription,
                domIdentifier: domIdentifier, classes: classes
            ), let elementFrame {
                let visible = elementFrame.intersection(clip)
                if !visible.isNull,
                   visible.width >= minimumVisibleSize.width, visible.height >= minimumVisibleSize.height {
                    let match = Match(kind: kind, visibleFrame: visible)
                    if best.map({ ($0.kind, $0.area) < (match.kind, match.area) }) ?? true {
                        best = match
                    }
                }
                // Nothing interesting lives inside the video element itself.
                if kind == .video { continue }
            }

            guard node.depth < maxDepth, !skippedRoles.contains(role),
                  let children = values[7] as? [AXUIElement], !children.isEmpty
            else { continue }

            // Skip subtrees that are entirely outside the viewport (scrolled away).
            if let elementFrame, elementFrame.width > 0, elementFrame.height > 0, !elementFrame.intersects(clip) {
                continue
            }
            for child in children {
                queue.append(Node(element: child, depth: node.depth + 1, clip: clip))
            }
        }
        return best
    }

    private static func classify(
        role: String, subrole: String, roleDescription: String, domIdentifier: String, classes: [String]
    ) -> MatchKind? {
        if role == "AXVideo" || subrole == "AXVideo" { return .video }
        if classes.contains("video-stream") || classes.contains("html5-main-video") { return .video }
        if role == "AXGroup" {
            // Chrome describes <video> as a group whose role description is the localized "video".
            let description = roleDescription.lowercased()
            if ["video", "vídeo", "vidéo", "wideo", "видео"].contains(description) { return .video }
        }
        if domIdentifier == "movie_player" || classes.contains("html5-video-player") { return .playerContainer }
        return nil
    }

    // MARK: AX helpers

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    /// Fetches several attributes in one round trip; missing ones come back as `nil`.
    private static func copyValues(_ element: AXUIElement, _ attributes: [String]) -> [AnyObject?] {
        var raw: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw
        )
        guard result == .success, let values = raw as [AnyObject]?, values.count == attributes.count else {
            return Array(repeating: nil, count: attributes.count)
        }
        return values.map { value in
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                return nil
            }
            return value
        }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        rect(position: copyValue(element, kAXPositionAttribute), size: copyValue(element, kAXSizeAttribute))
    }

    /// AX positions are global screen points with a top-left origin.
    private static func rect(position: AnyObject?, size: AnyObject?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: point, size: extent)
    }
}


extension ChromeVideoAXLocator {
    /// Diagnostics: logs a sample of the AX tree so a missed video can be matched by hand.
    fileprivate static func logSample(of window: AXUIElement) {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var seen = Set<String>()
        var visited = 0
        while !queue.isEmpty, visited < 1500, seen.count < 60 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = sampleValue(element, kAXRoleAttribute) as? String ?? ""
            let description = sampleValue(element, kAXRoleDescriptionAttribute) as? String ?? ""
            let classes = (sampleValue(element, "AXDOMClassList") as? [String])?.joined(separator: ".") ?? ""
            let identifier = sampleValue(element, "AXDOMIdentifier") as? String ?? ""
            let key = "\(role)|\(description)|\(identifier)|\(classes.prefix(60))"
            if role != "AXStaticText", seen.insert(key).inserted {
                log.notice("sample d\(depth, privacy: .public): \(key, privacy: .public)")
            }
            if depth < 40, let children = sampleValue(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        log.notice("sample: visited \(visited, privacy: .public) nodes")
    }

    private static func sampleValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}


extension ChromeVideoAXLocator {
    /// Chrome's main process. XPC services may not see LaunchServices' running-app list, so fall
    /// back to scanning the process table for Chrome's main executable.
    fileprivate static func chromeProcessIdentifier() -> pid_t? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleIdentifier)
            .first(where: { !$0.isTerminated }) {
            return app.processIdentifier
        }

        // Chrome may run from a code-sign clone (".../Google Chrome.app.bundle/..."), so match the
        // main executable by name inside a bundle rather than by its install path.
        let mainExecutableSuffix = "/Contents/MacOS/Google Chrome"
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return nil }

        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executablePath = String(cString: path)
            if executablePath.hasSuffix(mainExecutableSuffix), executablePath.contains("Google Chrome.app") {
                return pid
            }
        }
        return nil
    }
}
