import AppKit
import Carbon.HIToolbox
import CoreText

@main
enum BriefingApp {
    @MainActor
    static func main() {
        // uninstall.sh: take the login item away before the app is deleted.
        if CommandLine.arguments.contains("--remove-login-item") {
            LoginItem.set(false)
            exit(0)
        }
        // One copy only: a second launch (a double click, a second login item) hands over to the first and quits.
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != me }) {
            other.activate()
            exit(0)
        }
        // The app is English-only: system-provided pieces (text menus, alerts) follow suit, for this run only.
        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        UserDefaults.standard.setVolatileDomain(["AppleLanguages": ["en"]], forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = DashboardController()
    private let engine = TriggerEngine()
    private let onboarding = OnboardingController()
    private let settingsWindow = SettingsWindowController()
    private var engineStarted = false
    private var statusItem: NSStatusItem!
    private var activity: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?

    private let showItem = NSMenuItem(title: "Open Briefing", action: nil, keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch")
        LoginItem.migrateLegacyAgent()
        // No App Nap: the backup timer must tick on time. System and display sleep are not blocked.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Briefing: waiting for the first wake of the day"
        )
        registerUserFonts()
        setupStatusItem()
        Updates.shared.start()

        HotKeyCenter.shared.action = { [weak self] in
            guard let self else { return }
            self.controller.toggle(reason: "hotkey")
        }
        if !HotKeyCenter.shared.reload() {
            Log.write("global shortcut \(SettingsStore.shared.settings.keyLabel(.toggle)) is taken — change it in Settings")
        }

        settingsWindow.isDashboardVisible = { [weak self] in self?.controller.isVisible ?? false }
        settingsWindow.isOnboardingVisible = { [weak self] in self?.onboarding.isVisible ?? false }
        settingsWindow.showOnboarding = { [weak self] in self?.showOnboarding() }
        settingsWindow.timeChanged = { [weak self] in self?.engine.evaluate("new time") }
        settingsWindow.onClose = { [weak self] in self?.controller.refocus() }
        controller.openSettings = { [weak self] tab in self?.settingsWindow.show(tab) }

        // Settings changed anywhere (Settings window, onboarding, Google sign-in).
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .briefingSettingsChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { _ = HotKeyCenter.shared.reload() }
        }

        engine.isVisible = { [weak self] in self?.controller.isVisible ?? false }
        engine.show = { [weak self] reason in
            self?.controller.show(reason: reason) ?? false
        }
        engine.refreshVisible = { [weak self] in self?.controller.refreshForNewDay() }
        engine.isPaused = { [weak self] in self?.onboarding.isVisible ?? false }
        onboarding.onFinish = { [weak self] in self?.startEngine() }

        if SettingsStore.shared.settings.onboarded {
            // Permissions are asked only in onboarding, never on a plain launch.
            startEngine()
        } else {
            // First launch: onboarding asks for every permission itself, step by step.
            onboarding.show()
        }
    }

    private func startEngine() {
        guard !engineStarted else { return }
        engineStarted = true
        engine.start()
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
            button.setAccessibilityLabel("Briefing")
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        showItem.action = #selector(showNow)
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(item("Show Onboarding\u{2026}", #selector(showOnboarding)))
        menu.addItem(.separator())
        menu.addItem(item("Open Data Folder", #selector(openData)))
        menu.addItem(item("Open Log", #selector(openLog)))
        menu.addItem(item("Reset \u{201C}Shown Today\u{201D}", #selector(resetShown)))
        menu.addItem(.separator())
        menu.addItem(item("Check for Updates\u{2026}", #selector(checkForUpdates)))
        menu.addItem(item("Support Briefing\u{2026}", #selector(support)))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit)))

        statusItem.menu = menu
    }

    /// The app icon itself, at menu bar size. Falls back to a drawn template outside an app bundle.
    private static func menuBarIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = false
            icon.accessibilityDescription = "Briefing"
            return icon
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let tile = NSRect(x: 2.5, y: 2.5, width: 13, height: 13)
            let outline = NSBezierPath(roundedRect: tile, xRadius: 3, yRadius: 3)

            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            NSColor.black.setFill()
            NSRect(x: tile.minX, y: tile.minY, width: tile.width / 3, height: tile.height / 3).fill()
            let grid = NSBezierPath()
            for i in 1...2 {
                let x = tile.minX + tile.width * CGFloat(i) / 3
                let y = tile.minY + tile.height * CGFloat(i) / 3
                grid.move(to: NSPoint(x: x, y: tile.minY))
                grid.line(to: NSPoint(x: x, y: tile.maxY))
                grid.move(to: NSPoint(x: tile.minX, y: y))
                grid.line(to: NSPoint(x: tile.maxX, y: y))
            }
            grid.lineWidth = 0.8
            NSColor.black.withAlphaComponent(0.5).setStroke()
            grid.stroke()
            NSGraphicsContext.restoreGraphicsState()

            outline.lineWidth = 1.2
            NSColor.black.setStroke()
            outline.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Briefing"
        return image
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    func menuWillOpen(_ menu: NSMenu) {
        SettingsStore.shared.reload()
        let s = SettingsStore.shared.settings
        if let combo = s.combos(.toggle).first {
            showItem.keyEquivalent = combo.menuKeyEquivalent
            showItem.keyEquivalentModifierMask = combo.flags
        } else {
            showItem.keyEquivalent = ""
        }

        let state = DataStore.shared.state
        if DataStore.shared.wasShown(on: Date()), let at = state.lastShownAt {
            statusLine.title = "Shown today at \(Fmt.time(at))"
        } else {
            statusLine.title = "Not shown yet today"
        }
    }

    @objc private func showNow() {
        controller.show(reason: "menu")
        let now = Date()
        if now >= SettingsStore.shared.settings.threshold(on: now) {
            DataStore.shared.markShown(now, reason: "menu")
        }
    }

    @objc private func openSettings() {
        settingsWindow.show(.general)
    }

    @objc private func showOnboarding() {
        if controller.isVisible { controller.close() }
        onboarding.show()
    }

    @objc private func openData() {
        NSWorkspace.shared.open(Paths.support)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Paths.log)
    }

    @objc private func resetShown() {
        DataStore.shared.resetShown()
        Log.write("marker reset manually")
    }

    @objc private func checkForUpdates() {
        Updates.shared.checkNow()
    }

    /// Briefing is free; this is the only place it asks for anything.
    @objc private func support() {
        if let url = URL(string: "https://ko-fi.com/vanodium") { NSWorkspace.shared.open(url) }
    }

    @objc private func quit() {
        Log.write("quit from menu")
        NSApp.terminate(nil)   // exit code 0 — launchd will not relaunch until next login
    }

    // MARK: Fonts

    /// Fonts in ~/Library/Application Support/Briefing/Fonts are registered for this app only.
    private func registerUserFonts() {
        let dir = Paths.fonts
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
