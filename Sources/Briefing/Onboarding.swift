import AppKit
import CoreLocation
import EventKit
import ServiceManagement
import SwiftUI

// MARK: - Steps

enum OnboardingStep: Int, CaseIterable {
    case welcome, theme, access, principles, challenge, wake, ready

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .theme: return "Theme"
        case .access: return "Your day"
        case .principles: return "Principles"
        case .challenge: return Fmt.string(Date(), "MMMM") + " challenge"
        case .wake: return "Wake routine"
        case .ready: return "Ready"
        }
    }

    var question: String {
        switch self {
        case .welcome: return "Your morning, on one screen."
        case .theme: return "Pick the light you wake up to."
        case .access: return "Let Briefing see your day."
        case .principles: return "What do you stand by?"
        case .challenge: return "What will you do every day this month?"
        case .wake: return "When should it appear?"
        case .ready: return "You\u{2019}re set."
        }
    }

    /// Steps are sections, numbered like the dashboard's: 001, 002…  Items inside a step use two digits.
    var number: String { String(format: "%03d", rawValue + 1) }
}

/// Where a system permission stands, as shown on the Access step.
enum PermissionState { case ask, granted, denied }

/// The typed city, checked as you type: nothing yet, looking, found (with its full name), or not found.
enum CityStatus: Equatable { case idle, looking, found(String), notFound }

// MARK: - Model

@MainActor
final class OnboardingModel: ObservableObject {
    enum Phase { case pre, shown, out }
    enum Splash { case pre, show, gone, none }

    // Flow
    @Published var step: OnboardingStep = .welcome
    @Published var phase: Phase = .pre
    @Published var back = false
    @Published var splash: Splash = .pre
    @Published var lightOn = false
    @Published var finishing = false
    /// Drives the progress line. Changed inside its own animation, separately from the page swap
    /// (which happens with animations disabled), so the line always glides.
    @Published var progressIndex = 0
    var onDone: (_ saved: Bool) -> Void = { _ in }
    private var started = false

    // Answers
    @Published var themeID: String { didSet { Palette.override = themeID } }
    @Published var calendar: PermissionState = .ask
    @Published var reminders: PermissionState = .ask
    /// Off for someone who keeps no calendar: the Today block is hidden and nothing is asked.
    @Published var showToday: Bool
    @Published var city: String { didSet { if city != oldValue { resolveCity() } } }
    @Published var cityStatus: CityStatus = .idle
    @Published var principles: [String]
    @Published var challenges: [String]
    @Published var autoOpen: Bool
    @Published var notBefore: Date
    @Published var openAtLogin: Bool

    private let initialLogin: Bool
    private var timers: [DispatchWorkItem] = []
    private var resolved: (typed: String, place: Place)?
    private var cityTask: Task<Void, Never>?

    init() {
        let s = SettingsStore.shared.settings
        themeID = s.theme
        showToday = s.shows(.today)
        city = s.city
        autoOpen = s.autoOpen
        let (h, m) = s.triggerHourMinute
        notBefore = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
        let login = LoginItem.isEnabled
        // A first setup suggests opening at login; a repeat shows what is set now.
        openAtLogin = login || !s.onboarded
        initialLogin = login

        let saved = DataStore.shared.loadMindset().principles
        principles = Array((saved + Array(repeating: "", count: 5)).prefix(5))
        let month = DataStore.shared.loadChallenges().months[DayKey.month(Date())] ?? []
        challenges = Array((month + ["", ""]).prefix(2))

        Palette.override = themeID
        refreshPermissions()
        resolveCity(after: 0)
    }

    var palette: Palette { Palette.byID(themeID) }
    var chromeOn: Bool { splash == .gone || splash == .none }
    var progress: CGFloat {
        chromeOn ? CGFloat(progressIndex + 1) / CGFloat(OnboardingStep.allCases.count) : 0
    }

    /// Where the page sits: in place, or a third of a screen away — above when leaving, below when arriving
    /// (mirrored when going back), so a step change reads as a scroll.
    var pageOffset: CGFloat {
        switch phase {
        case .shown: return 0
        case .out: return back ? 0.12 : -0.12
        case .pre: return back ? -0.12 : 0.12
        }
    }

    static var progressGlide: Animation { Curves.reduceMotion ? .linear(duration: 0) : .timingCurve(0.65, 0, 0.35, 1, duration: 1.4) }

    // MARK: Timeline

    /// Called once the window is actually in front of the person, so the splash is never played to an empty room.
    func start() {
        guard !started else { return }
        started = true
        later(0.15) { $0.splash = .show; $0.lightOn = true }
        later(2.8) { m in withAnimation(Curves.glideLong) { m.splash = .gone } }
        later(3.1) { m in withAnimation(Self.progressGlide) { m.progressIndex = m.step.rawValue } }
        later(3.45) { m in withAnimation(Curves.settle(1.25)) { m.phase = .shown } }
        later(4.5) { $0.splash = .none }
    }

    func go(_ target: OnboardingStep) {
        guard phase == .shown, target != step, !finishing else { return }
        back = target.rawValue < step.rawValue
        withAnimation(Self.progressGlide) { progressIndex = target.rawValue }
        // Quick: the old page is gone in about a third of a second, the next one starts at once.
        withAnimation(Curves.leave(0.3)) { phase = .out }
        later(0.28) { m in
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                m.step = target
                m.phase = .pre
            }
        }
        later(0.32) { m in withAnimation(Curves.settle(0.8)) { m.phase = .shown } }
    }

    func next() {
        if step == .ready { finish(); return }
        if let n = OnboardingStep(rawValue: step.rawValue + 1) { go(n) }
    }

    func previous() {
        if let p = OnboardingStep(rawValue: step.rawValue - 1) { go(p) }
    }

    private func later(_ delay: Double, _ body: @escaping (OnboardingModel) -> Void) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self)
            }
        }
        timers.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancelTimers() {
        timers.forEach { $0.cancel() }
        timers.removeAll()
        cityTask?.cancel()
    }

    // MARK: Theme

    func pick(_ id: String) {
        withAnimation(Curves.fade(0.8)) { themeID = id }
    }

    // MARK: Permissions

    func refreshPermissions() {
        calendar = Self.state(EKEventStore.authorizationStatus(for: .event))
        reminders = Self.state(EKEventStore.authorizationStatus(for: .reminder))
    }

    private static func state(_ s: EKAuthorizationStatus) -> PermissionState {
        switch s {
        case .fullAccess, .authorized: return .granted
        case .notDetermined: return .ask
        default: return .denied
        }
    }

    var anyAccess: Bool {
        calendar == .granted || reminders == .granted || CloudProvider.allCases.contains { CloudAccount.shared($0).isConnected }
    }

    func cloud(_ provider: CloudProvider) -> PermissionState {
        CloudAccount.shared(provider).isConnected ? .granted : .ask
    }

    func connect(_ provider: CloudProvider) {
        let account = CloudAccount.shared(provider)
        guard !account.isConnected else { return }
        Task { @MainActor in
            await account.connect()
            NSAppActivate()
            withAnimation(Curves.fade(0.4)) { self.objectWillChange.send() }
        }
    }

    func toggleToday() {
        withAnimation(Curves.fade(0.4)) { showToday.toggle() }
    }

    func allowCalendar() {
        switch calendar {
        case .granted: return
        case .denied: Self.openPrivacy("Privacy_Calendars")
        case .ask:
            Task { @MainActor in
                _ = try? await AgendaService.shared.store.requestFullAccessToEvents()
                Log.write("onboarding: calendar access \(EKEventStore.authorizationStatus(for: .event).rawValue)")
                NSAppActivate()
                withAnimation(Curves.fade(0.4)) { self.refreshPermissions() }
            }
        }
    }

    func allowReminders() {
        switch reminders {
        case .granted: return
        case .denied: Self.openPrivacy("Privacy_Reminders")
        case .ask:
            Task { @MainActor in
                _ = try? await AgendaService.shared.store.requestFullAccessToReminders()
                Log.write("onboarding: reminders access \(EKEventStore.authorizationStatus(for: .reminder).rawValue)")
                NSAppActivate()
                withAnimation(Curves.fade(0.4)) { self.refreshPermissions() }
            }
        }
    }

    private static func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Wake time

    var notBeforeText: String { Fmt.time(notBefore) }

    /// Steps the time in quarters of an hour, wrapping around midnight.
    func shiftTime(_ minutes: Int) {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: notBefore)
        var total = (c.hour ?? 7) * 60 + (c.minute ?? 30)
        total = ((total / 15) * 15 + minutes + 24 * 60) % (24 * 60)
        notBefore = cal.date(bySettingHour: total / 60, minute: total % 60, second: 0, of: Date()) ?? notBefore
    }

    // MARK: Finish

    var filledPrinciples: [String] {
        principles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var filledChallenges: [String] {
        challenges.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    func finish() {
        guard !finishing else { return }
        finishing = true
        Task { @MainActor in
            let place = await lookUpCity()
            save(place)
            onDone(true)
        }
    }

    private struct Place {
        let name: String
        let country: String?
        let latitude: Double
        let longitude: Double
        let timezone: String?

        var label: String { [name, country].compactMap { $0 }.joined(separator: ", ") }
    }

    /// The typed city, for saving: unchanged means nothing to save; otherwise the place found while typing,
    /// or one more lookup if typing ended a moment ago.
    private func lookUpCity() async -> Place? {
        let typed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, typed != SettingsStore.shared.settings.city else { return nil }
        if let r = resolved, r.typed == typed { return r.place }
        let place = await geocode(typed)
        if place == nil { Log.write("onboarding: could not find city \u{201C}\(typed)\u{201D} — weather location unchanged") }
        return place
    }

    /// Looked up in English, for the weather's coordinates and time zone.
    private func geocode(_ typed: String) async -> Place? {
        let english = Locale(identifier: "en_US")
        guard let found = try? await CLGeocoder().geocodeAddressString(typed, in: nil, preferredLocale: english).first,
              let location = found.location else { return nil }
        return Place(name: found.locality ?? found.name ?? typed,
                     country: found.country,
                     latitude: location.coordinate.latitude,
                     longitude: location.coordinate.longitude,
                     timezone: found.timeZone?.identifier)
    }

    /// Checks the city a beat after typing stops, so the person sees it was understood before moving on.
    private func resolveCity(after delay: Double = 0.7) {
        cityTask?.cancel()
        let typed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            resolved = nil
            cityStatus = .idle
            return
        }
        if let r = resolved, r.typed == typed {
            cityStatus = .found(r.place.label)
            return
        }
        if cityStatus != .looking { withAnimation(Curves.fade(0.3)) { cityStatus = .looking } }
        cityTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            let place = await self.geocode(typed)
            guard !Task.isCancelled else { return }
            withAnimation(Curves.fade(0.4)) {
                if let place {
                    self.resolved = (typed, place)
                    self.cityStatus = .found(place.label)
                } else {
                    self.resolved = nil
                    self.cityStatus = .notFound
                }
            }
        }
    }

    private func save(_ place: Place?) {
        SettingsStore.shared.update { s in
            s.theme = themeID
            s.triggerTime = Fmt.string(notBefore, "HH:mm")
            s.autoOpen = autoOpen
            s.onboarded = true
            s.setBlock(.today, visible: showToday)
            if let place {
                s.city = place.name
                s.latitude = place.latitude
                s.longitude = place.longitude
                if let tz = place.timezone { s.timezone = tz }
            }
        }
        Palette.override = nil

        if !filledPrinciples.isEmpty {
            var m = DataStore.shared.loadMindset()
            m.principles = filledPrinciples
            DataStore.shared.saveMindset(m)
        }
        if !filledChallenges.isEmpty {
            var c = DataStore.shared.loadChallenges()
            c.months[DayKey.month(Date())] = filledChallenges
            DataStore.shared.saveChallenges(c)
        }
        if openAtLogin != initialLogin { LoginItem.set(openAtLogin) }

        // "Tomorrow morning, it will be waiting": today's showing counts as done once the threshold has passed.
        let now = Date()
        if now >= SettingsStore.shared.settings.threshold(on: now) {
            DataStore.shared.markShown(now, reason: "onboarding")
        }
        Log.write("onboarding finished: theme \(themeID), not before \(notBeforeText)")
    }
}

extension Curves {
    /// The splash leaving: the same heavy, symmetric glide as the dashboard's upper block.
    static var glideLong: Animation { reduceMotion ? .linear(duration: 0) : .timingCurve(0.76, 0, 0.24, 1, duration: 1.5) }
}

// MARK: - Open at login

/// A login item registered with macOS (System Settings → General → Login Items). The only way Briefing starts at login.
enum LoginItem {
    /// Earlier builds started from a LaunchAgent written by install.sh.
    private static var legacyAgent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/local.morning.dashboard.plist")
    }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on {
                if !isEnabled { try SMAppService.mainApp.register() }
            } else if isEnabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.write("login item: \(error.localizedDescription)")
        }
        Log.write("open at login: \(on)")
    }

    /// The old LaunchAgent becomes a login item, so the app never starts twice at login.
    static func migrateLegacyAgent() {
        guard FileManager.default.fileExists(atPath: legacyAgent.path) else { return }
        try? FileManager.default.removeItem(at: legacyAgent)
        set(true)
        Log.write("login: LaunchAgent replaced by a login item")
    }
}

// MARK: - Window

/// An ordinary window that fills the space between the menu bar and the Dock.
/// Other windows can go on top of it; the Dock stays visible.
final class OnboardingWindow: NSWindow {
    init(frame: NSRect) {
        super.init(contentRect: frame,
                   styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        title = "Briefing"
        level = .normal
        isOpaque = true
        backgroundColor = .black
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        animationBehavior = .documentWindow
        tabbingMode = .disallowed
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    private var window: OnboardingWindow?
    private var model: OnboardingModel?
    private var activeObserver: NSObjectProtocol?
    private var savedMenu: NSMenu?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var closing = false
    var onFinish: () -> Void = {}

    var isVisible: Bool { window != nil }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSAppActivate()
            return
        }
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        closing = false
        let model = OnboardingModel()
        model.onDone = { [weak self] _ in self?.close() }
        self.model = model

        let frame = screen.visibleFrame
        let window = OnboardingWindow(frame: frame)
        window.delegate = self
        let host = NSHostingView(rootView: OnboardingView(model: model))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.setFrame(frame, display: false)
        self.window = window

        // While onboarding is open Briefing behaves like a normal app: a Dock icon, ⌘-Tab,
        // and an Edit menu so copy and paste work in the text fields.
        NSApp.setActivationPolicy(.regular)
        savedMenu = NSApp.mainMenu
        NSApp.mainMenu = AppMenu.make()
        window.center()
        window.setFrame(frame, display: false)
        window.makeKeyAndOrderFront(nil)
        NSAppActivate()
        installKeyMonitor()

        // The splash waits until the window is really in front (after login the app may start in the background).
        if NSApp.isActive {
            model.start()
        } else {
            activeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.startWhenActive() }
            }
        }
        Log.write("onboarding shown")
    }

    private func startWhenActive() {
        if let o = activeObserver { NotificationCenter.default.removeObserver(o) }
        activeObserver = nil
        model?.start()
    }

    /// The red button: close without saving. Onboarding comes back at the next launch.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Log.write("onboarding closed before finishing")
        close()
        return false
    }

    func close() {
        guard let window, !closing else { return }
        closing = true
        removeKeyMonitor()
        model?.cancelTimers()
        if let o = activeObserver { NotificationCenter.default.removeObserver(o) }
        activeObserver = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.6
            ctx.timingFunction = Curves.windowOut
            window.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            MainActor.assumeIsolated {
                window.orderOut(nil)
                window.contentView = nil
                Palette.override = nil
                guard let self else { return }
                NSApp.mainMenu = self.savedMenu
                NSApp.setActivationPolicy(.accessory)
                self.window = nil
                self.model = nil
                self.closing = false
                self.onFinish()
            }
        }
    }

    // MARK: Keyboard

    /// Space scrolls to the next step, Shift-Space back, like reading a page.
    /// Inside a text field Space is just a space. On the last step it signs, like Enter.
    private func installKeyMonitor() {
        removeKeyMonitor()
        installMouseMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handleKey(event) }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
    }

    /// A click anywhere outside the field being typed in ends the typing, as on a web page.
    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let window = self?.window, event.window === window,
                      let editor = window.firstResponder as? NSTextView,
                      let field = editor.isFieldEditor ? editor.delegate as? NSView : editor else { return }
                let p = field.convert(event.locationInWindow, from: nil)
                if !field.bounds.contains(p) { window.makeFirstResponder(nil) }
            }
            return event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let space: UInt16 = 49
        guard event.keyCode == space, let window, let model, !closing, event.window === window else { return false }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if window.firstResponder is NSText { return false }   // typing
        if event.isARepeat || model.phase != .shown { return true }
        if event.modifierFlags.contains(.shift) {
            model.previous()
        } else {
            model.next()
        }
        return true
    }
}
