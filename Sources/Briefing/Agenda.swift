import AppKit
import EventKit
import Foundation

struct AgendaItem: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let title: String
    let start: Date?
    let end: Date?
    let allDay: Bool
    let isReminder: Bool
    let overdueSince: Date?
    /// The event's iCalendar UID — the same event seen through Apple Calendar and Google shares it.
    var externalID: String? = nil
    /// Google calendar the item came from (nil for Apple items).
    var calendar: String? = nil
}

struct AgendaAccess: Equatable {
    var calendar: Bool
    var reminders: Bool
}

@MainActor
final class AgendaService {
    static let shared = AgendaService()

    let store = EKEventStore()

    var access: AgendaAccess {
        AgendaAccess(
            calendar: Self.granted(EKEventStore.authorizationStatus(for: .event)),
            reminders: Self.granted(EKEventStore.authorizationStatus(for: .reminder))
        )
    }

    private static func granted(_ status: EKAuthorizationStatus) -> Bool {
        status == .fullAccess
    }

    /// Apple calendars (or reminder lists) the person can switch on and off in Settings.
    func calendars(for type: EKEntityType) -> [EKCalendar] {
        let allowed = type == .event ? access.calendar : access.reminders
        guard allowed else { return [] }
        return store.calendars(for: type).sorted {
            let a = $0.source?.title ?? "", b = $1.source?.title ?? ""
            if a != b { return a < b }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func items(for day: Date) async -> [AgendaItem] {
        let settings = SettingsStore.shared.settings
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? day
        var result: [AgendaItem] = []

        if settings.useAppleCalendar && access.calendar {
            let calendars = store.calendars(for: .event).filter { settings.calendarVisible($0.calendarIdentifier) }
            if !calendars.isEmpty {
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
                let events = store.events(matching: predicate)
                    .filter { $0.status != .canceled && !Self.isDeclined($0) }
                for e in events {
                    result.append(AgendaItem(
                        id: "e:" + (e.eventIdentifier ?? UUID().uuidString) + "\(e.startDate.timeIntervalSince1970)",
                        title: (e.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        start: e.isAllDay ? nil : e.startDate,
                        end: e.isAllDay ? nil : e.endDate,
                        allDay: e.isAllDay,
                        isReminder: false,
                        overdueSince: nil,
                        externalID: e.calendarItemExternalIdentifier
                    ))
                }
            }
        }

        if settings.useAppleReminders && access.reminders {
            let lists = store.calendars(for: .reminder).filter { settings.calendarVisible($0.calendarIdentifier) }
            if !lists.isEmpty {
                let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: lists)
                let reminders: [AgendaItem] = await withCheckedContinuation { continuation in
                    store.fetchReminders(matching: predicate) { list in
                        let mapped: [AgendaItem] = (list ?? []).compactMap { r in
                            guard let comps = r.dueDateComponents,
                                  let due = Calendar.current.date(from: comps) else { return nil }
                            let hasTime = comps.hour != nil
                            let overdue = due < start
                            return AgendaItem(
                                id: "r:" + r.calendarItemIdentifier,
                                title: (r.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                start: (hasTime && !overdue) ? due : nil,
                                end: nil,
                                allDay: false,
                                isReminder: true,
                                overdueSince: overdue ? due : nil
                            )
                        }
                        continuation.resume(returning: mapped)
                    }
                }
                result.append(contentsOf: reminders)
            }
        }

        // Google: what was saved at the last fetch, so the morning screen never waits for the network.
        for provider in CloudProvider.allCases where provider.isActive(settings) {
            let cloud = CloudCalendarService.shared(provider).cachedItems(for: day, settings: settings)
            // The same account may also be added to macOS — then each event would come twice.
            let seen = result
            result.append(contentsOf: cloud.filter { !Self.isDuplicate($0, in: seen) })
        }

        return result
            .filter { !$0.title.isEmpty }
            .sorted(by: Self.order)
    }

    private static func isDuplicate(_ g: AgendaItem, in items: [AgendaItem]) -> Bool {
        items.contains { e in
            guard !e.isReminder, e.allDay == g.allDay, e.start == g.start else { return false }
            if let a = e.externalID, let b = g.externalID, a == b { return true }
            return e.title.caseInsensitiveCompare(g.title) == .orderedSame
        }
    }

    /// Plan order: all-day events → timed → untimed → carried over.
    private static func order(_ a: AgendaItem, _ b: AgendaItem) -> Bool {
        func rank(_ i: AgendaItem) -> Int {
            if i.allDay { return 0 }
            if i.start != nil { return 1 }
            if i.overdueSince == nil { return 2 }
            return 3
        }
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb }
        if let sa = a.start, let sb = b.start, sa != sb { return sa < sb }
        if let oa = a.overdueSince, let ob = b.overdueSince, oa != ob { return oa > ob }
        return a.title < b.title
    }

    private static func isDeclined(_ event: EKEvent) -> Bool {
        guard let attendees = event.attendees else { return false }
        return attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined }
    }
}

@MainActor
func NSAppActivate() {
    if #available(macOS 14.0, *) {
        NSApp.activate()
    } else {
        NSApp.activate(ignoringOtherApps: true)
    }
}
