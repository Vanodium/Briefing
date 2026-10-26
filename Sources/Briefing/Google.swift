import Foundation

/// Google Calendar API v3, read only.
struct GoogleCalendarAPI: CalendarAPI {
    private struct CalendarList: Decodable {
        struct Item: Decodable {
            let id: String
            let summary: String?
            let summaryOverride: String?
            let primary: Bool?
            let selected: Bool?
            let deleted: Bool?
        }
        let items: [Item]?
    }

    private struct EventList: Decodable {
        struct When: Decodable {
            let date: String?
            let dateTime: String?
        }
        struct Attendee: Decodable {
            let isSelf: Bool?
            let responseStatus: String?
            enum CodingKeys: String, CodingKey {
                case isSelf = "self"
                case responseStatus
            }
        }
        struct Item: Decodable {
            let id: String
            let status: String?
            let summary: String?
            let start: When?
            let end: When?
            let attendees: [Attendee]?
            let iCalUID: String?
            let eventType: String?
        }
        let items: [Item]?
    }

    func calendars(token: String) async throws -> [CloudCalendar] {
        var c = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        c.queryItems = [URLQueryItem(name: "maxResults", value: "250")]
        let list = try await get(c.url!, token, as: CalendarList.self)
        return (list.items ?? [])
            .filter { $0.deleted != true }
            .map { CloudCalendar(id: $0.id,
                                 name: $0.summaryOverride ?? $0.summary ?? $0.id,
                                 primary: $0.primary ?? false,
                                 selected: $0.selected ?? false) }
            .sorted { a, b in
                if a.primary != b.primary { return a.primary }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    private static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let rfc3339Fraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parse(_ s: String) -> Date? {
        rfc3339.date(from: s) ?? rfc3339Fraction.date(from: s)
    }

    func events(in cal: CloudCalendar, day: Date, token: String, prefix: String) async throws -> [AgendaItem] {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? day
        guard var c = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(pathID(cal.id))/events") else {
            return []
        }
        c.queryItems = [
            URLQueryItem(name: "timeMin", value: Self.rfc3339.string(from: start)),
            URLQueryItem(name: "timeMax", value: Self.rfc3339.string(from: end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "100"),
        ]
        guard let url = c.url else { return [] }
        let list = try await get(url, token, as: EventList.self)

        var items: [AgendaItem] = []
        for e in list.items ?? [] {
            if e.status == "cancelled" { continue }
            if e.eventType == "workingLocation" { continue }
            if e.attendees?.contains(where: { $0.isSelf == true && $0.responseStatus == "declined" }) == true { continue }
            let title = (e.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            if let dt = e.start?.dateTime, let begins = Self.parse(dt) {
                items.append(AgendaItem(
                    id: "\(prefix)\(cal.id):\(e.id)",
                    title: title,
                    start: begins,
                    end: e.end?.dateTime.flatMap { Self.parse($0) },
                    allDay: false,
                    isReminder: false,
                    overdueSince: nil,
                    externalID: e.iCalUID,
                    calendar: cal.id
                ))
            } else if e.start?.date != nil {
                items.append(AgendaItem(
                    id: "\(prefix)\(cal.id):\(e.id)",
                    title: title,
                    start: nil,
                    end: nil,
                    allDay: true,
                    isReminder: false,
                    overdueSince: nil,
                    externalID: e.iCalUID,
                    calendar: cal.id
                ))
            }
        }
        return items
    }
}
