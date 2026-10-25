import Foundation
import SwiftUI

/// The three blocks of the lower half. Their order and visibility are the person's to choose.
enum BlockID: String, CaseIterable, Codable, Identifiable {
    case principles, today, month

    var id: String { rawValue }

    var name: String {
        switch self {
        case .principles: return "Principles"
        case .today: return "Today"
        case .month: return "Month challenge"
        }
    }

    var summary: String {
        switch self {
        case .principles: return "The lines you live by. Always the widest column."
        case .today: return "Calendar events and reminders for the day."
        case .month: return "This month\u{2019}s challenge and how far into it you are."
        }
    }

    /// Principles are set large, so they keep the wide column wherever they stand.
    var isWide: Bool { self == .principles }
}

struct Settings: Codable, Equatable {
    /// The dashboard never opens automatically before this time. Format "HH:mm".
    var triggerTime = "07:30"
    /// If the Mac is already awake when this time arrives, open exactly at that time.
    var catchUpAtThreshold = true
    /// Dim additional displays while the dashboard is open.
    var dimOtherScreens = true
    /// Strength of the morning sunlight on the background: 0 (off) to 1.
    var sun = 0.8
    /// Empty until the person names a city (onboarding). No city, no weather.
    var city = ""
    var latitude = 0.0
    var longitude = 0.0
    var timezone = TimeZone.current.identifier
    /// One of Palette.all — chosen during onboarding, editable here.
    var theme = "firstLight"
    /// Open by itself on the first wake of the day. Off: only from the menu or the hotkey.
    var autoOpen = true
    /// The first-launch onboarding has been completed.
    var onboarded = false

    // Blocks
    /// Every block, in the order they stand on screen (hidden ones keep their place).
    var blockOrder: [String] = BlockID.allCases.map(\.rawValue)
    var hiddenBlocks: [String] = []
    /// The weather in the upper right corner.
    var showWeather = true

    // Calendars
    var useAppleCalendar = true
    var useAppleReminders = true
    var useGoogleCalendar = false
    /// Calendars the person switched off. EventKit identifiers as they are, Google ones prefixed with "g:".
    var hiddenCalendars: [String] = []
    /// The connected Google account, for display only. The token itself lives in the Keychain.
    var googleAccount = ""

    // Keys
    /// Action → one or two key combinations. Missing actions fall back to their defaults.
    var shortcuts: [String: [KeyCombo]] = Shortcuts.defaults

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        triggerTime = (try? c.decodeIfPresent(String.self, forKey: .triggerTime)) ?? d.triggerTime
        catchUpAtThreshold = (try? c.decodeIfPresent(Bool.self, forKey: .catchUpAtThreshold)) ?? d.catchUpAtThreshold
        dimOtherScreens = (try? c.decodeIfPresent(Bool.self, forKey: .dimOtherScreens)) ?? d.dimOtherScreens
        sun = (try? c.decodeIfPresent(Double.self, forKey: .sun)) ?? d.sun
        city = (try? c.decodeIfPresent(String.self, forKey: .city)) ?? d.city
        latitude = (try? c.decodeIfPresent(Double.self, forKey: .latitude)) ?? d.latitude
        longitude = (try? c.decodeIfPresent(Double.self, forKey: .longitude)) ?? d.longitude
        timezone = (try? c.decodeIfPresent(String.self, forKey: .timezone)) ?? d.timezone
        theme = (try? c.decodeIfPresent(String.self, forKey: .theme)) ?? d.theme
        autoOpen = (try? c.decodeIfPresent(Bool.self, forKey: .autoOpen)) ?? d.autoOpen
        onboarded = (try? c.decodeIfPresent(Bool.self, forKey: .onboarded)) ?? d.onboarded
        blockOrder = (try? c.decodeIfPresent([String].self, forKey: .blockOrder)) ?? d.blockOrder
        hiddenBlocks = (try? c.decodeIfPresent([String].self, forKey: .hiddenBlocks)) ?? d.hiddenBlocks
        showWeather = (try? c.decodeIfPresent(Bool.self, forKey: .showWeather)) ?? d.showWeather
        useAppleCalendar = (try? c.decodeIfPresent(Bool.self, forKey: .useAppleCalendar)) ?? d.useAppleCalendar
        useAppleReminders = (try? c.decodeIfPresent(Bool.self, forKey: .useAppleReminders)) ?? d.useAppleReminders
        useGoogleCalendar = (try? c.decodeIfPresent(Bool.self, forKey: .useGoogleCalendar)) ?? d.useGoogleCalendar
        hiddenCalendars = (try? c.decodeIfPresent([String].self, forKey: .hiddenCalendars)) ?? d.hiddenCalendars
        googleAccount = (try? c.decodeIfPresent(String.self, forKey: .googleAccount)) ?? d.googleAccount
        shortcuts = (try? c.decodeIfPresent([String: [KeyCombo]].self, forKey: .shortcuts)) ?? d.shortcuts
        // Settings used to default to ⌘, — files saved back then move to the new default.
        if shortcuts[ShortcutAction.settings.rawValue] == [KeyCombo(keyCode: 43, modifiers: [.command])] {
            shortcuts[ShortcutAction.settings.rawValue] = d.shortcuts[ShortcutAction.settings.rawValue]
        }
    }

    var hasCity: Bool { !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var triggerHourMinute: (Int, Int) {
        let parts = triggerTime.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return (7, 30) }
        return (parts[0], parts[1])
    }

    func threshold(on date: Date) -> Date {
        let (h, m) = triggerHourMinute
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: date) ?? date
    }

    // MARK: Blocks

    /// Every block exactly once, in the saved order; unknown names are dropped, missing ones appended.
    var orderedBlocks: [BlockID] {
        var result: [BlockID] = []
        for raw in blockOrder {
            if let b = BlockID(rawValue: raw), !result.contains(b) { result.append(b) }
        }
        for b in BlockID.allCases where !result.contains(b) { result.append(b) }
        return result
    }

    /// The blocks on screen, left to right.
    var visibleBlocks: [BlockID] {
        orderedBlocks.filter { !hiddenBlocks.contains($0.rawValue) }
    }

    func shows(_ block: BlockID) -> Bool { !hiddenBlocks.contains(block.rawValue) }

    mutating func setBlock(_ block: BlockID, visible: Bool) {
        hiddenBlocks.removeAll { $0 == block.rawValue }
        if !visible { hiddenBlocks.append(block.rawValue) }
    }

    // MARK: Calendars

    func calendarVisible(_ id: String) -> Bool { !hiddenCalendars.contains(id) }

    mutating func setCalendar(_ id: String, visible: Bool) {
        hiddenCalendars.removeAll { $0 == id }
        if !visible { hiddenCalendars.append(id) }
    }

    // MARK: Keys

    func combos(_ action: ShortcutAction) -> [KeyCombo] {
        if let saved = shortcuts[action.rawValue], !saved.isEmpty { return Array(saved.prefix(action.maxCombos)) }
        return Shortcuts.defaults[action.rawValue] ?? []
    }

    /// "E", "⌃⌥⌘M" — the first combination of an action, as printed on screen.
    func keyLabel(_ action: ShortcutAction) -> String {
        combos(action).first?.display ?? "—"
    }

    /// The dashboard action a key press stands for, if any.
    func action(for combo: KeyCombo) -> ShortcutAction? {
        ShortcutAction.local.first { combos($0).contains(combo) }
    }
}

extension Notification.Name {
    /// Posted after every change made through SettingsStore.update.
    static let briefingSettingsChanged = Notification.Name("BriefingSettingsChanged")
}

final class SettingsStore {
    static let shared = SettingsStore()

    private(set) var settings: Settings

    private init() {
        if let s = JSONFile.load(Settings.self, from: Paths.settings) {
            settings = s
        } else {
            settings = Settings()
        }
        // Write back any missing keys so the file is easy to edit by hand.
        JSONFile.save(settings, to: Paths.settings)
    }

    func reload() {
        if let s = JSONFile.load(Settings.self, from: Paths.settings) { settings = s }
    }

    func update(_ change: (inout Settings) -> Void) {
        let before = settings
        change(&settings)
        JSONFile.save(settings, to: Paths.settings)
        if settings != before {
            NotificationCenter.default.post(name: .briefingSettingsChanged, object: nil)
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
