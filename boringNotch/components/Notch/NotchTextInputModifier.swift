//
//  NotchTextInputModifier.swift
//  boringNotch
//
//  Created by Deckmian on 2026-10-15.
//

import AppKit
import SwiftUI

extension View {
    /// Makes a text control inside the notch editable without stealing focus.
    ///
    /// Binds the control to `isFocused`, mirrors that focus into
    /// `BoringViewCoordinator.isEditingText` (which keeps the notch open),
    /// ends editing on Escape or when the user switches to another app, and
    /// hands keyboard focus back to the previous app when the view disappears.
    func notchTextInput(isFocused: FocusState<Bool>.Binding) -> some View {
        modifier(NotchTextInputModifier(isFocused: isFocused))
    }
}

// The notch panel is non-activating: clicking into a text control makes it key
// without bringing the app to the front, so typing stays with the frontmost
// app until the user explicitly starts editing.
private struct NotchTextInputModifier: ViewModifier {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    var isFocused: FocusState<Bool>.Binding
    @State private var hostWindow: NSWindow?
    @State private var escapeMonitor: Any?

    func body(content: Content) -> some View {
        content
            .focused(isFocused)
            .background(WindowReader { window in
                hostWindow = window
            })
            .onChange(of: isFocused.wrappedValue) { _, focused in
                coordinator.isEditingText = focused
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
                guard let window = notification.object as? NSWindow, window === hostWindow else { return }
                // The user moved focus to another app: stop editing and close if the pointer is gone
                endEditing(closeIfIdle: true)
            }
            .onAppear {
                installEscapeMonitor()
            }
            .onDisappear {
                removeEscapeMonitor()
                coordinator.isEditingText = false
                relinquishKeyStatus()
            }
    }

    /// Hands keyboard focus back to the previously focused app.
    private func relinquishKeyStatus() {
        guard let window = hostWindow, window.isKeyWindow else { return }
        window.makeFirstResponder(nil)
        // Keep the app active if one of its regular windows (e.g. Settings) is open
        let hasRegularWindow = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.canBecomeMain }
        if !hasRegularWindow {
            NSApp.deactivate()
        }
    }

    private func endEditing(closeIfIdle: Bool) {
        isFocused.wrappedValue = false
        coordinator.isEditingText = false
        hostWindow?.makeFirstResponder(nil)

        if closeIfIdle && vm.notchState == .open && !vm.isMouseHovering() && !coordinator.preventsAutoClose {
            vm.close()
        }
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 53 = Escape
            guard event.keyCode == 53,
                  coordinator.isEditingText,
                  let window = hostWindow,
                  event.window === window else { return event }
            endEditing(closeIfIdle: true)
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        escapeMonitor = nil
    }
}

/// Reports the `NSWindow` hosting a SwiftUI view once it is attached.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        WindowReaderView(onWindow: onWindow)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReaderView: NSView {
        let onWindow: (NSWindow) -> Void

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Defer to avoid mutating SwiftUI state during a view update
            DispatchQueue.main.async { [onWindow] in
                onWindow(window)
            }
        }
    }
}
