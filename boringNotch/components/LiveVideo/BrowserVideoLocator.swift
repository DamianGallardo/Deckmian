//
//  BrowserVideoLocator.swift
//  boringNotch
//
//  Created by Deckmian on 2026-10-18.
//

import AppKit
import CoreServices
import Foundation

/// The video found in the active tab of a Chrome window.
struct BrowserVideoTarget: Equatable, Sendable {
    /// Where the video's frame came from.
    enum Geometry: Equatable, Sendable {
        /// Visible part of the video in global screen points, top-left origin (Accessibility).
        case screen(CGRect)
        /// Visible part of the video in CSS pixels relative to the viewport (JavaScript fallback).
        case page(PageGeometry)
    }

    struct PageGeometry: Equatable, Sendable {
        var videoRect: CGRect
        var viewportSize: CGSize
        var outerSize: CGSize
        var devicePixelRatio: CGFloat
    }

    /// Identifies the window across polls ("cg:<CGWindowID>" or "as:<AppleScript id>").
    var windowKey: String
    /// The window's `CGWindowID` when known, for an exact ScreenCaptureKit match.
    var cgWindowID: CGWindowID?
    /// Window bounds in global screen points, top-left origin (same space as `SCWindow.frame`).
    var windowBounds: CGRect
    var geometry: Geometry
    var title: String
}

enum BrowserVideoLocation: Equatable, Sendable {
    case found(BrowserVideoTarget)
    case chromeNotRunning
    /// Deckmian is not trusted for Accessibility, so Chrome's page cannot be inspected.
    case needsAccessibility
    /// No video in an active tab of a visible window (background tab, minimized, scrolled away).
    case notVisible
}

/// Finds the video playing in Google Chrome.
///
/// The primary path asks the XPC helper to walk Chrome's Accessibility tree, which needs only the
/// Accessibility trust Deckmian already uses. When that finds nothing, a JavaScript lookup through
/// AppleScript is tried silently, but only if the user already allowed Deckmian to control Chrome
/// (it never triggers the Automation prompt) and only if Chrome happens to allow JavaScript from
/// Apple Events. Its failures are never surfaced.
enum BrowserVideoLocator {
    static let chromeBundleIdentifier = "com.google.Chrome"

    private static let queue = DispatchQueue(label: "com.deckmian.liveVideo.locator", qos: .userInitiated)

    static var isChromeRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleIdentifier).isEmpty
    }

    /// - Parameter preferredTitle: the current song title, used to pick between several windows.
    static func locate(preferredTitle: String?) async -> BrowserVideoLocation {
        // Never address Chrome when it is not running: `tell application` would launch it.
        guard isChromeRunning else { return .chromeNotRunning }

        let title = preferredTitle ?? ""
        if let reply = await XPCHelperClient.shared.locateChromeVideo(preferredTitle: title) {
            switch reply[ChromeVideoKeys.status] {
            case ChromeVideoKeys.statusFound:
                if let target = target(fromAccessibility: reply) { return .found(target) }
            case ChromeVideoKeys.statusNotTrusted:
                return .needsAccessibility
            case ChromeVideoKeys.statusChromeNotRunning:
                return .chromeNotRunning
            default:
                break
            }
        }

        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: runScriptFallback(preferredTitle: preferredTitle))
            }
        }
    }

    private static func target(fromAccessibility reply: [String: String]) -> BrowserVideoTarget? {
        func number(_ key: String) -> CGFloat? {
            reply[key].flatMap(Double.init).map { CGFloat($0) }
        }
        guard let wx = number(ChromeVideoKeys.windowX), let wy = number(ChromeVideoKeys.windowY),
              let ww = number(ChromeVideoKeys.windowWidth), let wh = number(ChromeVideoKeys.windowHeight),
              let vx = number(ChromeVideoKeys.videoX), let vy = number(ChromeVideoKeys.videoY),
              let vw = number(ChromeVideoKeys.videoWidth), let vh = number(ChromeVideoKeys.videoHeight),
              ww > 0, wh > 0, vw > 0, vh > 0
        else { return nil }

        let windowID = reply[ChromeVideoKeys.windowID].flatMap { CGWindowID($0) } ?? 0
        let bounds = CGRect(x: wx, y: wy, width: ww, height: wh)
        return BrowserVideoTarget(
            windowKey: windowID != 0 ? "cg:\(windowID)" : "ax:\(Int(wx)),\(Int(wy))",
            cgWindowID: windowID != 0 ? windowID : nil,
            windowBounds: bounds,
            geometry: .screen(CGRect(x: vx, y: vy, width: vw, height: vh)),
            title: reply[ChromeVideoKeys.title] ?? ""
        )
    }

    // MARK: - JavaScript fallback

    /// True only when the user already allowed Deckmian to control Chrome; never shows the prompt.
    private static func canAutomateChromeSilently() -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: chromeBundleIdentifier)
        guard let address = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, false)
        return status == noErr
    }

    private static func runScriptFallback(preferredTitle: String?) -> BrowserVideoLocation {
        guard canAutomateChromeSilently(), let script = NSAppleScript(source: appleScriptSource) else {
            return .notVisible
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        // Permission revoked, JavaScript from Apple Events off, timeouts: all stay silent.
        guard errorInfo == nil else { return .notVisible }
        return parse(descriptor.stringValue ?? "", preferredTitle: preferredTitle)
    }

    private struct PageReport: Decodable {
        var found: Bool
        var hidden: Bool?
        var playing: Bool?
        var x: Double?
        var y: Double?
        var width: Double?
        var height: Double?
        var innerWidth: Double
        var innerHeight: Double
        var outerWidth: Double
        var outerHeight: Double
        var devicePixelRatio: Double
        var title: String?
    }

    /// Each output line is either `id, minimized, left, top, right, bottom, json` (tab separated)
    /// or `ERR, number, message` when the window's tab could not be scripted (ignored).
    private static func parse(_ output: String, preferredTitle: String?) -> BrowserVideoLocation {
        var candidates: [(target: BrowserVideoTarget, isPlaying: Bool, area: CGFloat)] = []

        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7, fields[0] != "ERR",
                  let windowID = Int(fields[0]),
                  let left = Double(fields[2]), let top = Double(fields[3]),
                  let right = Double(fields[4]), let bottom = Double(fields[5]),
                  let data = fields[6].data(using: .utf8),
                  let page = try? JSONDecoder().decode(PageReport.self, from: data),
                  page.found, page.hidden != true, fields[1] != "true"
            else { continue }

            let videoRect = CGRect(x: page.x ?? 0, y: page.y ?? 0, width: page.width ?? 0, height: page.height ?? 0)
            let target = BrowserVideoTarget(
                windowKey: "as:\(windowID)",
                cgWindowID: nil,
                windowBounds: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                geometry: .page(BrowserVideoTarget.PageGeometry(
                    videoRect: videoRect,
                    viewportSize: CGSize(width: page.innerWidth, height: page.innerHeight),
                    outerSize: CGSize(width: page.outerWidth, height: page.outerHeight),
                    devicePixelRatio: page.devicePixelRatio
                )),
                title: page.title ?? ""
            )
            candidates.append((target, page.playing ?? false, videoRect.width * videoRect.height))
        }

        // Prefer playing videos, then a page title matching the current song, then the largest.
        let title = preferredTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func score(_ candidate: (target: BrowserVideoTarget, isPlaying: Bool, area: CGFloat)) -> (Int, Int, CGFloat) {
            let matchesTitle = !title.isEmpty && candidate.target.title.localizedCaseInsensitiveContains(title)
            return (candidate.isPlaying ? 1 : 0, matchesTitle ? 1 : 0, candidate.area)
        }
        guard let best = candidates.max(by: { score($0) < score($1) }) else { return .notVisible }
        return .found(best.target)
    }

    // MARK: - Sources

    /// Finds the largest playing video (or the largest one that has played) and reports the
    /// visible part of its content box. Written without double quotes or backslashes so it can be
    /// embedded in an AppleScript string literal as is.
    private static let pageScript = """
    (function(){
      var vs = document.querySelectorAll('video');
      var best = null, bestArea = 0, bestPlaying = false;
      for (var i = 0; i < vs.length; i++) {
        var v = vs[i];
        var r = v.getBoundingClientRect();
        var a = r.width * r.height;
        if (a < 1) continue;
        var p = !v.paused && !v.ended && v.readyState > 2;
        if (!p && !(v.currentTime > 0)) continue;
        if ((p && !bestPlaying) || (p === bestPlaying && a > bestArea)) { best = v; bestArea = a; bestPlaying = p; }
      }
      var o = { found: false, hidden: document.visibilityState === 'hidden', title: document.title,
        innerWidth: innerWidth, innerHeight: innerHeight, outerWidth: outerWidth, outerHeight: outerHeight,
        devicePixelRatio: devicePixelRatio };
      if (best) {
        var b = best.getBoundingClientRect();
        var left = b.left, top = b.top, w = b.width, h = b.height;
        var fit = getComputedStyle(best).objectFit;
        if (best.videoWidth > 0 && best.videoHeight > 0 && (fit === 'contain' || fit === 'scale-down')) {
          var s = Math.min(w / best.videoWidth, h / best.videoHeight);
          var cw = best.videoWidth * s, ch = best.videoHeight * s;
          left += (w - cw) / 2; top += (h - ch) / 2; w = cw; h = ch;
        }
        var x = Math.max(0, left), y = Math.max(0, top);
        var vw = Math.min(innerWidth, left + w) - x, vh = Math.min(innerHeight, top + h) - y;
        o.found = vw > 1 && vh > 1;
        o.playing = bestPlaying;
        o.x = x; o.y = y; o.width = vw; o.height = vh;
        o.videoWidth = best.videoWidth; o.videoHeight = best.videoHeight;
      }
      return JSON.stringify(o);
    })()
    """

    /// Separators are built outside the `tell` block: inside it, `tab` would resolve to Chrome's tab class.
    private static let appleScriptSource: String = {
        let escapedJS = pageScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return """
        set sepTab to character id 9
        set sepLine to character id 10
        with timeout of 3 seconds
            tell application id "\(chromeBundleIdentifier)"
                set out to ""
                repeat with w in windows
                    try
                        set b to bounds of w
                        set m to minimized of w
                        set r to execute (active tab of w) javascript "\(escapedJS)"
                        if r is missing value then set r to ""
                        set out to out & ((id of w) as text) & sepTab & (m as text) & sepTab & ((item 1 of b) as text) & sepTab & ((item 2 of b) as text) & sepTab & ((item 3 of b) as text) & sepTab & ((item 4 of b) as text) & sepTab & r & sepLine
                    on error errMsg number errNum
                        if errNum is -1743 then error errMsg number errNum
                        set out to out & "ERR" & sepTab & (errNum as text) & sepTab & errMsg & sepLine
                    end try
                end repeat
                return out
            end tell
        end timeout
        """
    }()
}
