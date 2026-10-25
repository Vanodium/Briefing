import AppKit
import CoreGraphics

/// Session state read directly — not from notifications, which can be missed.
enum SystemState {
    /// Tracked from notifications — fallback if CGSession does not return the lock key.
    static var trackedLocked = false

    static var sessionUnlocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let onConsole = dict["kCGSSessionOnConsoleKey"] as? Bool, !onConsole { return false }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return !locked }
        return !trackedLocked
    }

    static var displayAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }
}

/// Decides when to show the dashboard.
///
/// Principle: events (wake, unlock, login, screensaver end) only *wake up* the check;
/// the decision is made from state: "not shown today" + "time ≥ threshold" + "session
/// unlocked" + "display awake". Any missed notification is backed up by a timer
/// that detects sleep itself (a gap in wall-clock time between ticks).
@MainActor
final class TriggerEngine {
    var isVisible: () -> Bool = { false }
    /// Shows the dashboard; false if it could not.
    var show: (String) -> Bool = { _ in false }
    var refreshVisible: () -> Void = {}
    /// True while something else owns the screen (onboarding): never open on top of it.
    var isPaused: () -> Bool = { false }

    private var lastActivation = Date.distantPast
    private var lastTick = Date()
    private var screensaverRunning = false
    private var timer: Timer?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var pending: [DispatchWorkItem] = []
    private var lastBlockedReason = ""

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        on(ws, NSWorkspace.didWakeNotification) { $0.activation("wake") }
        on(ws, NSWorkspace.screensDidWakeNotification) { $0.activation("screensDidWake") }
        on(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.activation("sessionActive") }
        on(ws, NSWorkspace.willSleepNotification) { _ in Log.write("event: sleep") }

        let dnc = DistributedNotificationCenter.default()
        on(dnc, Notification.Name("com.apple.screenIsUnlocked")) {
            SystemState.trackedLocked = false
            $0.activation("unlock")
        }
        on(dnc, Notification.Name("com.apple.screenIsLocked")) { _ in
            SystemState.trackedLocked = true
            Log.write("event: screen locked")
        }
        on(dnc, Notification.Name("com.apple.screensaver.didstart")) { $0.screensaverRunning = true }
        on(dnc, Notification.Name("com.apple.screensaver.didstop")) {
            $0.screensaverRunning = false
            $0.activation("screensaverStop")
        }

        let nc = NotificationCenter.default
        on(nc, .NSCalendarDayChanged) { $0.evaluate("dayChanged") }
        on(nc, .NSSystemClockDidChange) { $0.evaluate("clockChanged") }

        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 8
        RunLoop.main.add(t, forMode: .common)
        timer = t

        activation("launch", delays: [2.5, 6, 15])
    }

    private func on(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (TriggerEngine) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        tokens.append((center, token))
    }

    /// Something happened after which the user has probably sat down at the Mac.
    func activation(_ reason: String, delays: [Double] = [0.8, 2.5, 6, 15]) {
        lastActivation = Date()
        lastBlockedReason = ""
        Log.write("event: \(reason)")
        pending.forEach { $0.cancel() }
        pending = delays.map { delay in
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.evaluate(reason) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func tick() {
        let now = Date()
        let gap = now.timeIntervalSince(lastTick)
        lastTick = now
        if gap > 90 {
            // The timer "overslept" — so the Mac was asleep. Works even if didWake never arrived.
            activation("gap \(Int(gap))s")
        } else {
            evaluate("timer")
        }
    }

    func evaluate(_ reason: String) {
        let now = Date()
        let settings = SettingsStore.shared.settings
        let shownToday = DataStore.shared.wasShown(on: now)
        let threshold = settings.threshold(on: now)

        if isVisible() {
            // Window left open since yesterday and a new morning came — count it as shown and refresh.
            if !shownToday && now >= threshold {
                DataStore.shared.markShown(now, reason: "carried-over")
                refreshVisible()
                Log.write("window already open — refreshed for the new day")
            }
            return
        }

        guard !shownToday else { return }
        guard settings.autoOpen else { return }
        guard !isPaused() else { return }
        guard now >= threshold else { return }
        if !settings.catchUpAtThreshold && lastActivation < threshold { return }

        guard SystemState.sessionUnlocked else { blocked("screen locked — waiting for unlock"); return }
        guard !SystemState.displayAsleep else { blocked("display asleep"); return }
        guard !screensaverRunning else { blocked("screensaver running"); return }

        // Counted only once it is really on screen, so a failed attempt is retried.
        if show(reason) { DataStore.shared.markShown(now, reason: reason) }
    }

    private func blocked(_ why: String) {
        guard why != lastBlockedReason else { return }
        lastBlockedReason = why
        Log.write("waiting: \(why)")
    }
}
