import AppKit
import EventKit
import SwiftUI

struct EditableItem: Identifiable, Equatable {
    let id: UUID
    var text: String

    init(_ text: String) {
        id = UUID()
        self.text = text
    }

    static func list(_ strings: [String]) -> [EditableItem] { strings.map(EditableItem.init) }
}

extension Array where Element == EditableItem {
    var cleaned: [String] {
        map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    // Data
    @Published var settings = SettingsStore.shared.settings
    @Published var weather: WeatherSnapshot?
    @Published var weatherFailed = false
    @Published var agenda: [AgendaItem] = []
    @Published var access = AgendaAccess(calendar: true, reminders: true)
    @Published var principles: [EditableItem] = []
    @Published var currentChallenges: [EditableItem] = []
    @Published var nextChallenges: [EditableItem] = []
    @Published var currentMonthKey = DayKey.month(Date())
    @Published var nextMonthKey = DayKey.month(DayKey.nextMonth(after: Date()))

    // Screen state
    enum Stage { case pre, top, full }
    /// pre — nothing visible yet; top — time, date, weather; full — the day laid out below.
    @Published var stage: Stage = .pre
    @Published var editing = false
    @Published var editingNextMonth = false
    @Published var now = Date()
    /// Room the Dock takes on the dashboard's screen (also when it is set to hide automatically).
    @Published var dock = EdgeInsets()
    private(set) var fullSince = Date.distantFuture

    private(set) var isActive = false
    private var challengesFile = ChallengesFile()
    private var mindsetFile = MindsetFile()
    private let weatherService = WeatherService()
    private var weatherTask: Task<Void, Never>?
    private var cloudTasks: [Task<Void, Never>] = []
    private var agendaReloadWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    // MARK: Lifecycle

    func activate() {
        isActive = true
        loadAll()
        stage = .pre
        fullSince = .distantFuture
        // Hold the empty frame for a beat: first only darkness, then the type arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.stage == .pre else { return }
                self.stage = .top
            }
        }
        // Then, once the upper block has landed, the day opens by itself (Space / Enter still skip ahead).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.9) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.stage == .top else { return }
                self.advance()
            }
        }
        observeChanges()
        reloadAgenda()
        startCloudLoops()
        startWeatherLoop()
    }

    func deactivate() {
        isActive = false
        if editing { endEditing() }
        weatherTask?.cancel()
        weatherTask = nil
        stopCloudLoops()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    /// A new day while the window is open (or the window was left open since yesterday).
    func refreshForNewDay() {
        loadAll()
        reloadAgenda()
        startCloudLoops()
        startWeatherLoop()
    }

    func loadAll() {
        SettingsStore.shared.reload()
        settings = SettingsStore.shared.settings
        now = Date()
        mindsetFile = DataStore.shared.loadMindset()
        principles = EditableItem.list(mindsetFile.principles)
        challengesFile = DataStore.shared.loadChallenges(now: now)
        currentMonthKey = DayKey.month(now)
        nextMonthKey = DayKey.month(DayKey.nextMonth(after: now))
        currentChallenges = EditableItem.list(challengesFile.months[currentMonthKey] ?? [])
        nextChallenges = EditableItem.list(challengesFile.months[nextMonthKey] ?? [])
        weather = weatherService.cached(for: settings)
        access = AgendaService.shared.access
    }

    private func observeChanges() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleAgendaReload() }
        })
        observers.append(nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshForNewDay() }
        })
        observers.append(nc.addObserver(forName: .briefingSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        })
    }

    /// Settings were changed (usually in the Settings window, with the dashboard behind it): apply at once.
    private func settingsChanged() {
        // Access may have just been granted from Settings, with nothing in settings.json changing.
        let newAccess = AgendaService.shared.access
        if newAccess != access {
            access = newAccess
            reloadAgenda()
        }
        let old = settings
        let new = SettingsStore.shared.settings
        guard new != old else { return }
        withAnimation(Curves.fade(0.8)) { settings = new }
        if new.city != old.city || new.latitude != old.latitude || new.longitude != old.longitude {
            weather = nil
            startWeatherLoop()
        }
        let cloudChanged = CloudProvider.allCases.contains {
            new[keyPath: $0.useKey] != old[keyPath: $0.useKey] || new[keyPath: $0.accountKey] != old[keyPath: $0.accountKey]
        }
        let sourcesChanged = new.useAppleCalendar != old.useAppleCalendar
            || new.useAppleReminders != old.useAppleReminders
            || new.hiddenCalendars != old.hiddenCalendars
            || cloudChanged
        if sourcesChanged {
            access = AgendaService.shared.access
            reloadAgenda()
            if cloudChanged { startCloudLoops() }
        }
        if editing && !canEdit { endEditing() }
    }

    // MARK: Blocks

    /// Edit mode needs something to edit: Principles or the month's challenge on screen.
    var canEdit: Bool { settings.shows(.principles) || settings.shows(.month) }

    /// Why the Today block has nothing to show, or nil when at least one source can be read.
    var agendaBlocked: String? {
        let s = settings
        let cloud = CloudProvider.allCases.contains { $0.isActive(s) }
        if (s.useAppleCalendar && access.calendar) || (s.useAppleReminders && access.reminders) || cloud {
            return nil
        }
        let cloudChosen = CloudProvider.configured.contains { s[keyPath: $0.useKey] }
        if !s.useAppleCalendar && !s.useAppleReminders && !cloudChosen {
            return "No calendar chosen."
        }
        return "No access to your calendar."
    }

    // MARK: Stages

    /// Space / Enter on the first screen: the rest of the day slides in.
    func advance() {
        guard stage != .full else { return }
        stage = .full
        fullSince = Date()
    }

    /// True once the cascade has had time to land — a second Enter should not cut it short.
    var canClose: Bool { stage == .full && Date().timeIntervalSince(fullSince) > 1.2 }

    // MARK: Calendar

    private func scheduleAgendaReload() {
        agendaReloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reloadAgenda() }
        }
        agendaReloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func reloadAgenda() {
        Task { @MainActor in
            let items = await AgendaService.shared.items(for: Date())
            self.access = AgendaService.shared.access
            self.agenda = items
            self.now = Date()
        }
    }

    private func stopCloudLoops() {
        cloudTasks.forEach { $0.cancel() }
        cloudTasks.removeAll()
    }

    /// Google: what was saved last time shows at once; a fresh copy follows once the network is up,
    /// then every quarter of an hour while the screen is open.
    private func startCloudLoops() {
        stopCloudLoops()
        for provider in CloudProvider.allCases where provider.isActive(settings) {
            cloudTasks.append(cloudLoop(CloudCalendarService.shared(provider)))
        }
    }

    private func cloudLoop(_ service: CloudCalendarService) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            let retries: [UInt64] = [0, 4, 12, 30, 90]
            for delay in retries {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                guard let self, !Task.isCancelled, self.isActive else { return }
                if await service.refresh(day: Date()) {
                    self.reloadAgenda()
                    break
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                guard let self, self.isActive, !Task.isCancelled else { return }
                if await service.refresh(day: Date()) { self.reloadAgenda() }
            }
        }
    }

    // MARK: Weather

    private func startWeatherLoop() {
        weatherTask?.cancel()
        weatherTask = Task { @MainActor [weak self] in
            // After wake the network takes a moment to come up — several attempts with pauses.
            let retries: [UInt64] = [0, 4, 12, 30, 90]
            for delay in retries {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                guard let self, !Task.isCancelled, self.isActive else { return }
                if await self.fetchWeather() { break }
            }
            // While the screen is open, refresh every half hour.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                guard let self, self.isActive, !Task.isCancelled else { return }
                _ = await self.fetchWeather()
            }
        }
    }

    private func fetchWeather() async -> Bool {
        guard settings.hasCity else { return true }   // nothing to look up
        do {
            let w = try await weatherService.fetch(settings: settings)
            guard w.isFor(settings) else { return true }   // the city changed while this was on its way
            weather = w
            weatherFailed = false
            return true
        } catch {
            weatherFailed = true
            Log.write("weather: \(error.localizedDescription)")
            return false
        }
    }

    var weatherIsStale: Bool {
        guard let w = weather else { return true }
        return weatherFailed && Date().timeIntervalSince(w.fetchedAt) > 2 * 3600
    }

    // MARK: Editing

    func beginEditing() {
        guard canEdit else { return }
        if stage != .full { advance() }
        editingNextMonth = DayKey.isLastDayOfMonth(Date())
        editing = true
    }

    func endEditing() {
        principles = principles.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        currentChallenges = currentChallenges.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        nextChallenges = nextChallenges.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        persist()
        editing = false
    }

    func persist() {
        mindsetFile.principles = principles.cleaned
        DataStore.shared.saveMindset(mindsetFile)

        let cur = currentChallenges.cleaned
        let next = nextChallenges.cleaned
        if cur.isEmpty { challengesFile.months.removeValue(forKey: currentMonthKey) } else { challengesFile.months[currentMonthKey] = cur }
        if next.isEmpty { challengesFile.months.removeValue(forKey: nextMonthKey) } else { challengesFile.months[nextMonthKey] = next }
        DataStore.shared.saveChallenges(challengesFile)
    }

    // MARK: Formatting

    static func monthName(_ key: String) -> String {
        guard let d = DayKey.date(fromMonthKey: key) else { return key }
        let f = DateFormatter()
        f.locale = Theme.locale
        f.dateFormat = "MMMM"
        return f.string(from: d)
    }
}
