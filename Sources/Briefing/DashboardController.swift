import AppKit
import SwiftUI

/// A borderless panel the size of the screen, at ordinary window level: other windows can come in front of it.
/// nonactivatingPanel lets it take keyboard input immediately, like Spotlight.
final class DashboardPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = false
        level = .normal
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class DashboardController {
    let model = DashboardModel()

    private var panel: DashboardPanel?
    private var backdrops: [NSWindow] = []
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var activeObservers: [NSObjectProtocol] = []
    private var shownAt = Date.distantPast
    private var closing = false

    var isVisible: Bool { panel != nil }
    /// Opens Briefing's Settings on top of the dashboard (wired up by the app delegate).
    var openSettings: (SettingsTab) -> Void = { _ in }

    /// Gives the keyboard back to the dashboard, e.g. after the Settings window closes.
    func refocus() {
        guard let panel, !closing else { return }
        panel.makeKey()
    }

    // MARK: Showing

    /// False if there was nowhere to show it.
    @discardableResult
    func show(reason: String) -> Bool {
        if panel != nil { bringToFront(); return true }
        guard let screen = NSScreen.screens.first ?? NSScreen.main else {
            Log.write("show: no screen")
            return false
        }
        closing = false
        shownAt = Date()
        model.dock = DockMetrics.insets(for: screen)
        model.activate()

        let panel = DashboardPanel(frame: screen.frame)
        let host = NSHostingView(rootView: DashboardView(
            model: model,
            onClose: { [weak self] in self?.close() },
            onSettings: { [weak self] tab in self?.openSettings(tab) }
        ))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.setFrame(screen.frame, display: false)
        panel.alphaValue = 0
        self.panel = panel

        if model.settings.dimOtherScreens {
            for other in NSScreen.screens.dropFirst() {
                let w = NSWindow(contentRect: other.frame, styleMask: .borderless, backing: .buffered, defer: false)
                w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
                w.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 1)
                w.isOpaque = false
                w.alphaValue = 0
                // Only a veil: clicks go through to whatever is on that display.
                w.ignoresMouseEvents = true
                w.isReleasedWhenClosed = false
                w.setFrame(other.frame, display: false)
                w.orderFrontRegardless()
                backdrops.append(w)
            }
        }

        panel.orderFrontRegardless()
        panel.makeKey()
        NSAppActivate()

        // Only the dark ground fades in; the type arrives afterwards, piece by piece.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.7
            ctx.timingFunction = Curves.windowIn
            panel.animator().alphaValue = 1
            for b in backdrops { b.animator().alphaValue = 0.92 }
        }

        installKeyMonitor()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reframe() }
        }
        // The other displays are dimmed only while Briefing is the app in front.
        let nc = NotificationCenter.default
        activeObservers = [
            nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dimOthers(false) }
            },
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dimOthers(true) }
            },
        ]
        Log.write("shown (\(reason))")
        return true
    }

    private func dimOthers(_ on: Bool) {
        guard panel != nil, !closing, !backdrops.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            ctx.timingFunction = Curves.windowIn
            for b in backdrops { b.animator().alphaValue = on ? 0.92 : 0 }
        }
    }

    private func reframe() {
        guard let panel, let screen = NSScreen.screens.first else { return }
        panel.setFrame(screen.frame, display: true)
        let dock = DockMetrics.insets(for: screen)
        if dock != model.dock {
            withAnimation(Curves.settle(0.9)) { model.dock = dock }
        }
    }

    // MARK: Closing

    func close() {
        guard let panel, !closing else { return }
        closing = true
        if model.editing { model.endEditing() }
        removeKeyMonitor()
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
        activeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        activeObservers.removeAll()

        let backdrops = self.backdrops
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.2
            ctx.timingFunction = Curves.windowOut
            panel.animator().alphaValue = 0
            for b in backdrops { b.animator().alphaValue = 0 }
        }
        // The window is destroyed entirely: nothing renders or ticks while the dashboard is closed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.contentView = nil
                backdrops.forEach { $0.orderOut(nil) }
                guard let self else { return }
                self.backdrops.removeAll()
                self.panel = nil
                self.closing = false
                self.model.deactivate()
                Log.write("closed")
            }
        }
    }

    /// Hidden behind other windows: bring it forward first; already in front: close.
    func toggle(reason: String) {
        guard let panel else { show(reason: reason); return }
        if panel.isKeyWindow && NSApp.isActive { close() } else { bringToFront() }
    }

    private func bringToFront() {
        guard let panel, !closing else { return }
        backdrops.forEach { $0.orderFront(nil) }
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAppActivate()
    }

    /// The window was left open since yesterday and a new morning came: refresh the content.
    func refreshForNewDay() {
        model.refreshForNewDay()
        panel?.makeKey()
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handleKey(event) }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel, !closing else { return false }
        guard event.window == nil || event.window === panel else { return false }

        let escape: UInt16 = 53
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        let settings = SettingsStore.shared.settings
        let action = settings.action(for: KeyCombo(event: event))

        if model.editing {
            // In edit mode the keys go into the text. Esc always leaves edit mode; a Settings key with ⌘ still works.
            if event.keyCode == escape {
                panel.makeFirstResponder(nil)
                model.endEditing()
                return true
            }
            if action == .settings, !mods.isEmpty {
                openSettings(.general)
                return true
            }
            return false
        }

        // Guard against closing by accident with the key used to wake the Mac.
        if Date().timeIntervalSince(shownAt) < 1.5 { return true }

        switch action {
        case .advance:
            if model.stage != .full {
                model.advance()            // first press: open the day
            } else if model.canClose {
                close()                    // second press: sign and begin
            }
            return true
        case .close:
            close()
            return true
        case .amend:
            model.beginEditing()
            return true
        case .settings:
            openSettings(.general)
            return true
        case .toggle, nil:
            return mods.isEmpty   // swallow the rest to avoid the system "bonk" sound
        }
    }
}
