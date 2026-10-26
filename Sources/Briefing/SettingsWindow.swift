import AppKit
import CoreLocation
import EventKit
import SwiftUI

// MARK: - Tabs

enum SettingsTab: Int, CaseIterable {
    case general, appearance, blocks, calendars, shortcuts

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .blocks: return "Blocks"
        case .calendars: return "Calendars"
        case .shortcuts: return "Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .blocks: return "rectangle.split.3x1"
        case .calendars: return "calendar"
        case .shortcuts: return "keyboard"
        }
    }
}

// MARK: - Model

/// The Settings window's view of settings.json. Every change is saved at once and posted,
/// so a dashboard open behind the window follows along live.
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var s = SettingsStore.shared.settings
    var showOnboarding: () -> Void = {}
    var timeChanged: () -> Void = {}
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .briefingSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        SettingsStore.shared.reload()
        let latest = SettingsStore.shared.settings
        if latest != s { s = latest }
    }

    func change(_ edit: (inout Settings) -> Void) {
        SettingsStore.shared.update(edit)
        s = SettingsStore.shared.settings
    }

    func binding<T>(_ path: WritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(get: { self.s[keyPath: path] },
                set: { value in self.change { $0[keyPath: path] = value } })
    }

    /// "Not before" as a Date for the time picker.
    var time: Binding<Date> {
        Binding(
            get: {
                let (h, m) = self.s.triggerHourMinute
                return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let value = String(format: "%02d:%02d", c.hour ?? 7, c.minute ?? 30)
                guard value != self.s.triggerTime else { return }
                self.change { $0.triggerTime = value }
                Log.write("ritual time: \(value)")
                self.timeChanged()
            }
        )
    }

    func moveBlock(_ block: BlockID, by delta: Int) {
        var order = s.orderedBlocks
        guard let i = order.firstIndex(of: block) else { return }
        let j = i + delta
        guard order.indices.contains(j) else { return }
        order.swapAt(i, j)
        change { $0.blockOrder = order.map(\.rawValue) }
    }

    func calendar(_ id: String) -> Binding<Bool> {
        Binding(get: { self.s.calendarVisible(id) },
                set: { on in self.change { $0.setCalendar(id, visible: on) } })
    }

    func block(_ b: BlockID) -> Binding<Bool> {
        Binding(get: { self.s.shows(b) },
                set: { on in self.change { $0.setBlock(b, visible: on) } })
    }

    func resetShortcuts() {
        change { $0.shortcuts = Shortcuts.defaults }
        HotKeyCenter.shared.reload()
    }
}

// MARK: - Window

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    private var model: SettingsModel?
    private var savedMenu: NSMenu?
    private var madeRegular = false

    var isDashboardVisible: () -> Bool = { false }
    var isOnboardingVisible: () -> Bool = { false }
    var showOnboarding: () -> Void = {}
    var timeChanged: () -> Void = {}
    /// Called after the window closes (the dashboard takes the keyboard back).
    var onClose: () -> Void = {}

    var isVisible: Bool { window != nil }

    func show(_ tab: SettingsTab = .general) {
        if window == nil { build() }
        guard let window, let tabs else { return }
        tabs.selectedTabViewItemIndex = tab.rawValue
        model?.refresh()

        // On its own, Briefing behaves like a normal app while Settings is open: a Dock icon, ⌘-Tab, an Edit menu.
        if !isDashboardVisible() && !isOnboardingVisible() && NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            madeRegular = true
        }
        if savedMenu == nil {
            savedMenu = NSApp.mainMenu
            NSApp.mainMenu = AppMenu.make()
        }
        window.makeKeyAndOrderFront(nil)
        NSAppActivate()
    }

    private func build() {
        let model = SettingsModel()
        model.showOnboarding = { [weak self] in
            self?.window?.close()
            self?.showOnboarding()
        }
        model.timeChanged = { [weak self] in self?.timeChanged() }
        self.model = model

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: SettingsPage(tab: tab, model: model))
            host.sizingOptions = [.preferredContentSize]
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        self.tabs = tabs

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.center()
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        if madeRegular && !isOnboardingVisible() {
            NSApp.setActivationPolicy(.accessory)
        }
        madeRegular = false
        if let savedMenu, !isOnboardingVisible() { NSApp.mainMenu = savedMenu }
        savedMenu = nil
        window?.delegate = nil
        window = nil
        tabs = nil
        model = nil
        onClose()
    }
}

/// The menu Briefing shows while one of its own windows is in front (onboarding, Settings),
/// so copy and paste work in the text fields and ⌘W closes the window.
enum AppMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "Hide Briefing", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Briefing", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        return main
    }
}

// MARK: - Pages

private struct SettingsPage: View {
    let tab: SettingsTab
    @ObservedObject var model: SettingsModel

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralPage(model: model)
            case .appearance: AppearancePage(model: model)
            case .blocks: BlocksPage(model: model)
            case .calendars: CalendarsPage(model: model)
            case .shortcuts: ShortcutsPage(model: model)
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 580)
    }
}

// MARK: General

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var autoUpdates = false
    @StateObject private var city = CityLookup()

    var body: some View {
        Form {
            Section("Opening") {
                Toggle("Open by itself on the first wake of the day", isOn: model.binding(\.autoOpen))
                DatePicker("Not before", selection: model.time, displayedComponents: .hourAndMinute)
                    .disabled(!model.s.autoOpen)
                Toggle("Open at that time if the Mac is already awake", isOn: model.binding(\.catchUpAtThreshold))
                    .disabled(!model.s.autoOpen)
                Toggle("Open Briefing at login", isOn: Binding(
                    get: { openAtLogin },
                    set: { on in
                        LoginItem.set(on)
                        openAtLogin = LoginItem.isEnabled
                    }
                ))
            }

            Section("Displays") {
                Toggle("Dim other displays while Briefing is open", isOn: model.binding(\.dimOtherScreens))
            }

            Section {
                HStack {
                    TextField("City", text: $city.text, prompt: Text("Belgrade"))
                        .onSubmit { city.lookUp(into: model) }
                    Button("Look Up") { city.lookUp(into: model) }
                        .disabled(city.text.trimmingCharacters(in: .whitespaces).isEmpty || city.status == .looking)
                }
            } header: {
                Text("Weather")
            } footer: {
                Text(city.note(current: model.s))
                    .foregroundStyle(city.status == .notFound ? Color.red : Color.secondary)
            }

            Section {
                Button("Show Onboarding Again\u{2026}") { model.showOnboarding() }
            }

            if Updates.shared.isAvailable {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { autoUpdates },
                        set: { on in
                            Updates.shared.automaticChecks = on
                            autoUpdates = on
                        }
                    ))
                    HStack {
                        Text("Version \(Updates.shared.version)").foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Now") { Updates.shared.checkNow() }
                    }
                }
            }

            Section {
                HStack {
                    Text("Briefing is free. If it makes your mornings better, you can support it.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("Support on Ko-fi", destination: URL(string: "https://ko-fi.com/vanodium")!)
                }
            } footer: {
                Link("Weather data by Open-Meteo.com", destination: URL(string: "https://open-meteo.com/")!)
                    .font(.footnote)
            }
        }
        .onAppear {
            city.text = model.s.city
            openAtLogin = LoginItem.isEnabled
            autoUpdates = Updates.shared.automaticChecks
        }
    }
}

/// Typed city → coordinates and time zone, looked up in English like in onboarding.
@MainActor
private final class CityLookup: ObservableObject {
    @Published var text = ""
    @Published var status: CityStatus = .idle

    func note(current s: Settings) -> String {
        switch status {
        case .looking: return "Looking it up\u{2026}"
        case .notFound: return "Not found. Try adding the country."
        case .found(let label): return "Weather for \(label)."
        case .idle: return s.hasCity ? "Weather for \(s.city)." : "Type a city, in any language, for the weather."
        }
    }

    func lookUp(into model: SettingsModel) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            model.change { $0.city = "" }
            status = .idle
            return
        }
        status = .looking
        Task { @MainActor in
            let english = Locale(identifier: "en_US")
            guard let found = try? await CLGeocoder().geocodeAddressString(typed, in: nil, preferredLocale: english).first,
                  let location = found.location else {
                status = .notFound
                return
            }
            let name = found.locality ?? found.name ?? typed
            model.change { s in
                s.city = name
                s.latitude = location.coordinate.latitude
                s.longitude = location.coordinate.longitude
                if let tz = found.timeZone?.identifier { s.timezone = tz }
            }
            text = name
            status = .found([name, found.country].compactMap { $0 }.joined(separator: ", "))
            Log.write("settings: city \(name)")
        }
    }
}

// MARK: Appearance

private struct AppearancePage: View {
    @ObservedObject var model: SettingsModel

    private var selected: Palette { Palette.byID(model.s.theme) }

    var body: some View {
        Form {
            Section {
                themeGrid("Dark", Palette.all.filter { !$0.isLight }, first: 0)
                themeGrid("Light", Palette.all.filter(\.isLight), first: Palette.all.filter { !$0.isLight }.count)
            } header: {
                Text("Theme")
            } footer: {
                Text("\(selected.name): \(selected.summary)")
            }
        }
    }

    private func themeGrid(_ title: String, _ palettes: [Palette], first: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 4),
                      alignment: .leading, spacing: 14) {
                ForEach(Array(palettes.enumerated()), id: \.element.id) { i, p in
                    ThemeChoice(palette: p, number: first + i + 1, selected: p.id == model.s.theme) {
                        model.change { $0.theme = p.id }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ThemeChoice: View {
    let palette: Palette
    let number: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ThemeSwatch(palette: palette, number: number, s: 0.7)
                    .aspectRatio(1512 / 982, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15),
                                          lineWidth: selected ? 2.5 : 1)
                    )
                Text(palette.name)
                    .font(.callout)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(palette.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One theme in miniature: its ground and light, the index number in its ink, one rule in its rule colour.
/// Shared by onboarding and Settings.
struct ThemeSwatch: View {
    let palette: Palette
    let number: Int
    let s: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                Backdrop(sunVisible: true, sunStrength: 0.8, palette: palette, followsPointer: false)
                Text(String(format: "%02d", number))
                    .font(Theme.font(12 * s))
                    .tracking(1 * s)
                    .foregroundStyle(palette.accent ?? palette.inkColor())
                    .offset(x: 9 * s, y: 8 * s)
                Rectangle()
                    .fill(palette.rule ?? palette.inkColor(0.3))
                    .frame(width: w, height: 1)
                    .offset(y: h * 0.62)
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .clipped()
        }
        .accessibilityHidden(true)
    }
}

// MARK: Blocks

private struct BlocksPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LayoutPreview(blocks: model.s.visibleBlocks)
                    .frame(height: 64)
                    .padding(.vertical, 4)
            } header: {
                Text("Layout")
            }

            Section {
                let order = model.s.orderedBlocks
                ForEach(Array(order.enumerated()), id: \.element) { i, block in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(block.name)
                            Text(block.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.moveBlock(block, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(i == 0)
                            .help("Move left")
                        Button { model.moveBlock(block, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(i == order.count - 1)
                            .help("Move right")
                        Toggle("Show \(block.name)", isOn: model.block(block))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            } header: {
                Text("Blocks, left to right")
            } footer: {
                Text("Principles always take the wide column. Hide Today if you don\u{2019}t keep a calendar: Briefing then never asks for calendar access.")
            }

            Section {
                Toggle("Weather in the upper right corner", isOn: model.binding(\.showWeather))
            } header: {
                Text("Header")
            } footer: {
                Text(model.s.hasCity ? "Weather for \(model.s.city). Change the city in General."
                                     : "No city yet: set one in General.")
            }
        }
    }
}

/// The 12-column grid in miniature, showing where each visible block will stand.
private struct LayoutPreview: View {
    let blocks: [BlockID]

    var body: some View {
        let slots = BlockSlot.layout(blocks)
        let used = slots.reduce(0) { $0 + $1.span }
        GeometryReader { geo in
            let gap: CGFloat = 6
            let unit = (geo.size.width - 11 * gap) / 12
            HStack(spacing: gap) {
                ForEach(slots, id: \.block) { slot in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.09))
                        .overlay(alignment: .topLeading) {
                            Text(String(format: "%03d  ", slot.number) + slot.block.name.uppercased())
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(6)
                        }
                        .frame(width: unit * CGFloat(slot.span) + gap * CGFloat(slot.span - 1))
                }
                if used < 12 {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .overlay {
                            if slots.isEmpty {
                                Text("Only the day, the time and the weather.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .animation(.easeInOut(duration: 0.3), value: blocks)
    }
}

// MARK: Calendars

private struct CalendarsPage: View {
    @ObservedObject var model: SettingsModel
    @State private var eventCalendars: [EKCalendar] = []
    @State private var reminderLists: [EKCalendar] = []
    @State private var eventStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var reminderStatus = EKEventStore.authorizationStatus(for: .reminder)

    var body: some View {
        Form {
            if !model.s.shows(.today) {
                Section {
                    HStack {
                        Image(systemName: "eye.slash").foregroundStyle(.secondary)
                        Text("The Today block is hidden, so none of this shows on the dashboard.")
                        Spacer()
                        Button("Show Today") { model.change { $0.setBlock(.today, visible: true) } }
                    }
                }
            }

            Section {
                Toggle("Calendar events", isOn: model.binding(\.useAppleCalendar))
                if model.s.useAppleCalendar {
                    accessRow(.event, status: eventStatus)
                    calendarList(eventCalendars)
                }
                Toggle("Reminders", isOn: model.binding(\.useAppleReminders))
                if model.s.useAppleReminders {
                    accessRow(.reminder, status: reminderStatus)
                    calendarList(reminderLists)
                }
            } header: {
                Text("Apple Calendar & Reminders")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Every account added to your Mac — iCloud, Google, Exchange — shows up here.")
                    Button("Open Internet Accounts\u{2026}") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }
            }

            ForEach(CloudProvider.allCases) { provider in
                CloudSection(model: model, provider: provider)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    private func reload() {
        eventStatus = EKEventStore.authorizationStatus(for: .event)
        reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
        eventCalendars = AgendaService.shared.calendars(for: .event)
        reminderLists = AgendaService.shared.calendars(for: .reminder)
        for provider in CloudProvider.allCases where CloudAccount.shared(provider).isConnected {
            let data = CloudCalendarService.shared(provider)
            if data.calendars.isEmpty { Task { await data.refreshCalendars() } }
        }
    }

    @ViewBuilder
    private func accessRow(_ type: EKEntityType, status: EKAuthorizationStatus) -> some View {
        let what = type == .event ? "your calendar" : "your reminders"
        switch status {
        case .fullAccess, .authorized:
            EmptyView()
        case .notDetermined:
            HStack {
                Text("Briefing can\u{2019}t read \(what) yet.").foregroundStyle(.secondary)
                Spacer()
                Button("Allow Access") { request(type) }
            }
        default:
            HStack {
                Text("Access to \(what) is turned off in System Settings.").foregroundStyle(.secondary)
                Spacer()
                Button("Open Privacy Settings") {
                    let anchor = type == .event ? "Privacy_Calendars" : "Privacy_Reminders"
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func request(_ type: EKEntityType) {
        Task { @MainActor in
            let store = AgendaService.shared.store
            if type == .event {
                _ = try? await store.requestFullAccessToEvents()
            } else {
                _ = try? await store.requestFullAccessToReminders()
            }
            NSAppActivate()
            reload()
            NotificationCenter.default.post(name: .briefingSettingsChanged, object: nil)
        }
    }

    @ViewBuilder
    private func calendarList(_ calendars: [EKCalendar]) -> some View {
        ForEach(calendars, id: \.calendarIdentifier) { cal in
            Toggle(isOn: model.calendar(cal.calendarIdentifier)) {
                HStack(spacing: 8) {
                    Circle().fill(Color(nsColor: cal.color ?? .gray)).frame(width: 9, height: 9)
                    Text(cal.title)
                    if let source = cal.source?.title {
                        Text(source).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .padding(.leading, 16)
        }
    }
}

/// An online account (Google), signed in directly.
private struct CloudSection: View {
    @ObservedObject var model: SettingsModel
    let provider: CloudProvider
    @ObservedObject private var account: CloudAccount
    @ObservedObject private var data: CloudCalendarService

    init(model: SettingsModel, provider: CloudProvider) {
        self.model = model
        self.provider = provider
        account = CloudAccount.shared(provider)
        data = CloudCalendarService.shared(provider)
    }

    var body: some View {
        Section {
            content
        } header: {
            Text(provider.name)
        } footer: {
            if let error = account.lastError {
                Text(error).foregroundStyle(.red)
            } else if provider.isConfigured {
                Text("Read only. Briefing never changes your calendars. Events are kept on this Mac so the morning screen never waits for the network.")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !provider.isConfigured {
            VStack(alignment: .leading, spacing: 6) {
                Text("Direct \(provider.accountName) sign-in is not set up in this build of Briefing.")
                Text("You can still see \(provider.name): add your \(provider.accountName) account in Internet Accounts (above) and its calendars appear under Apple Calendar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if account.isConnected {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.s[keyPath: provider.accountKey])
                    if let at = data.lastFetch {
                        Text("Updated \(at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Disconnect") { account.disconnect() }
            }
            Toggle("Show \(provider.name) events", isOn: model.binding(provider.useKey))
            if model.s[keyPath: provider.useKey] {
                if data.calendars.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading calendars\u{2026}").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(data.calendars) { cal in
                        Toggle(cal.name, isOn: model.calendar(provider.prefix + cal.id))
                            .toggleStyle(.checkbox)
                            .padding(.leading, 16)
                    }
                }
            }
        } else {
            HStack {
                Text("Read a \(provider.accountName) account\u{2019}s calendars directly, without adding it to macOS.")
                Spacer()
                if account.busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { account.cancelConnect() }
                } else {
                    Button("Connect \(provider.accountName) Account\u{2026}") { Task { await account.connect() } }
                }
            }
            if account.busy {
                Text("Finish signing in in your browser, then come back here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Shortcuts

private struct ShortcutsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    ShortcutRow(model: model, action: action)
                }
            } footer: {
                Text("Click a field and press the new keys. Esc cancels; Delete removes an alternative. Esc always leaves editing, and Return and the keypad Enter count as one key.")
            }
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { model.resetShortcuts() }
                }
            }
        }
    }
}

private struct ShortcutRow: View {
    @ObservedObject var model: SettingsModel
    let action: ShortcutAction
    @State private var problem: String?

    private var combos: [KeyCombo] { model.s.combos(action) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                    if let note = action.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ShortcutRecorder(combo: combos.first, onRecord: { set($0, slot: 0) })
                    .frame(width: 128, height: 24)
                if action.maxCombos > 1 {
                    ShortcutRecorder(combo: combos.count > 1 ? combos[1] : nil,
                                     placeholder: "Alternative",
                                     onRecord: { set($0, slot: 1) },
                                     onClear: { clearAlternative() })
                        .frame(width: 128, height: 24)
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func set(_ combo: KeyCombo, slot: Int) {
        if let p = Shortcuts.problem(with: combo, for: action, slot: slot, in: model.s) {
            problem = p
            return
        }
        var list = combos
        if slot < list.count { list[slot] = combo } else { list.append(combo) }
        if action.isGlobal {
            guard HotKeyCenter.shared.register(combo) else {
                problem = "\(combo.display) is already taken by macOS or another app."
                HotKeyCenter.shared.reload()
                return
            }
        }
        problem = nil
        model.change { $0.shortcuts[action.rawValue] = list }
    }

    private func clearAlternative() {
        guard combos.count > 1 else { return }
        problem = nil
        let first = combos[0]
        model.change { $0.shortcuts[action.rawValue] = [first] }
    }
}
