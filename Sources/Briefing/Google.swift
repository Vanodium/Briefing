import AppKit
import CryptoKit
import Foundation
import Network
import Security

// MARK: - Configuration

/// Google sign-in needs an OAuth client of type "Desktop app" from Google Cloud Console.
/// Put its ID and secret into Resources/Info.plist (GoogleClientID, GoogleClientSecret).
/// Without them the Google option says it is not set up in this build, and nothing else changes.
enum GoogleConfig {
    static var clientID: String { value("GoogleClientID") }
    /// Google issues a "secret" for desktop clients too. It is not a real secret (it ships inside the app),
    /// but the token endpoint asks for it.
    static var clientSecret: String { value("GoogleClientSecret") }
    /// Google Calendar is switched off for now: Apple Calendar and Reminders only.
    /// Flip to true to bring back sign-in, the Settings section and the onboarding row.
    static let enabled = false
    static var isConfigured: Bool { enabled && !clientID.isEmpty }

    /// Read-only: Briefing never changes a calendar. openid + email only to show which account is connected.
    static let scopes = "openid email https://www.googleapis.com/auth/calendar.readonly"

    static func isConnected(_ settings: Settings) -> Bool {
        isConfigured && !settings.googleAccount.isEmpty
    }

    private static func value(_ key: String) -> String {
        ((Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum GoogleError: LocalizedError {
    case notConfigured, notConnected, denied(String), badResponse, noRefreshToken, timedOut, http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Google sign-in is not set up in this build."
        case .notConnected: return "No Google account is connected."
        case .denied(let why): return why == "access_denied" ? "Access was not granted." : "Google said: \(why)."
        case .badResponse: return "Google sent an answer Briefing did not understand."
        case .noRefreshToken: return "Google did not grant lasting access. Try connecting again."
        case .timedOut: return "Sign-in took too long. Try again."
        case .http(let code, _): return code == 400 || code == 401
            ? "Google access has expired. Connect the account again."
            : "Google is not reachable right now (\(code))."
        }
    }
}

// MARK: - Keychain

/// The refresh token is the one thing that must not sit in a JSON file.
enum Keychain {
    private static let service = "Briefing.Google"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?, _ account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Log.write("keychain: could not save (\(status))") }
    }
}

// MARK: - Account

/// Sign-in with Google in the person's own browser (OAuth 2.0 for installed apps: PKCE + a loopback redirect).
@MainActor
final class GoogleAccount: ObservableObject {
    static let shared = GoogleAccount()

    @Published private(set) var busy = false
    @Published var lastError: String?

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var server: LoopbackServer?
    private static let refreshKey = "refresh_token"

    var isConnected: Bool { GoogleConfig.isConnected(SettingsStore.shared.settings) }

    func connect() async {
        guard !busy else { return }
        guard GoogleConfig.isConfigured else { lastError = GoogleError.notConfigured.errorDescription; return }
        busy = true
        lastError = nil
        defer { busy = false }
        do {
            let verifier = Self.randomURLSafe(32)
            let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            let state = Self.randomURLSafe(16)

            let server = LoopbackServer()
            self.server = server
            let port = try await server.start()
            let redirect = "http://127.0.0.1:\(port)"

            var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            c.queryItems = [
                URLQueryItem(name: "client_id", value: GoogleConfig.clientID),
                URLQueryItem(name: "redirect_uri", value: redirect),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: GoogleConfig.scopes),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
            ]
            guard let url = c.url else { throw GoogleError.badResponse }
            NSWorkspace.shared.open(url)

            let query = try await server.waitForRedirect(timeout: 300)
            self.server = nil
            if let error = query["error"] { throw GoogleError.denied(error) }
            guard query["state"] == state, let code = query["code"] else { throw GoogleError.badResponse }

            let token = try await Self.exchange([
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": redirect,
                "grant_type": "authorization_code",
            ])
            guard let refresh = token.refresh_token else { throw GoogleError.noRefreshToken }
            Keychain.write(refresh, Self.refreshKey)
            accessToken = token.access_token
            expiry = Date().addingTimeInterval(Double(token.expires_in ?? 3600) - 60)
            let email = token.id_token.flatMap(Self.email(fromIDToken:)) ?? "Google account"

            SettingsStore.shared.update {
                $0.googleAccount = email
                $0.useGoogleCalendar = true
            }
            Log.write("google: connected")
            NSAppActivate()
            // Calendars hidden in Google Calendar itself start hidden here too.
            await GoogleCalendarService.shared.refreshCalendars(hideUnselected: true)
            await GoogleCalendarService.shared.refresh(day: Date())
            // The dashboard, if open, picks the new events up.
            NotificationCenter.default.post(name: .briefingSettingsChanged, object: nil)
        } catch is CancellationError {
            self.server = nil
        } catch {
            self.server?.cancel()
            self.server = nil
            lastError = error.localizedDescription
            Log.write("google: sign-in failed — \(error)")
        }
    }

    func cancelConnect() {
        server?.cancel()
        server = nil
    }

    func disconnect() {
        if let refresh = Keychain.read(Self.refreshKey) {
            // Best effort: tell Google to forget the grant too.
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["token": refresh]).data(using: .utf8)
            URLSession.shared.dataTask(with: request).resume()
        }
        Keychain.write(nil, Self.refreshKey)
        accessToken = nil
        expiry = .distantPast
        lastError = nil
        GoogleCalendarService.shared.clear()
        SettingsStore.shared.update {
            $0.googleAccount = ""
            $0.useGoogleCalendar = false
            $0.hiddenCalendars.removeAll { $0.hasPrefix("g:") }
        }
        Log.write("google: disconnected")
    }

    /// A valid access token, refreshed when the old one has expired.
    func token() async throws -> String {
        if let t = accessToken, Date() < expiry { return t }
        guard isConnected, let refresh = Keychain.read(Self.refreshKey) else { throw GoogleError.notConnected }
        let r = try await Self.exchange(["refresh_token": refresh, "grant_type": "refresh_token"])
        accessToken = r.access_token
        expiry = Date().addingTimeInterval(Double(r.expires_in ?? 3600) - 60)
        return r.access_token
    }

    // MARK: Token endpoint

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
        let id_token: String?
    }

    private static func exchange(_ fields: [String: String]) async throws -> TokenResponse {
        var all = fields
        all["client_id"] = GoogleConfig.clientID
        if !GoogleConfig.clientSecret.isEmpty { all["client_secret"] = GoogleConfig.clientSecret }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(all).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw GoogleError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    static func form(_ fields: [String: String]) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    // MARK: Helpers

    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The email inside the ID token's payload. Shown in Settings only; never used to decide access.
    private static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }
}

// MARK: - Loopback redirect

/// A one-request web server on 127.0.0.1 that catches Google's redirect after sign-in.
final class LoopbackServer {
    private var listener: NWListener?
    private var portContinuation: CheckedContinuation<UInt16, Error>?
    private var redirectContinuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?
    private var timeout: DispatchWorkItem?

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            self.portContinuation = cont
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = listener?.port?.rawValue {
                        self.portContinuation?.resume(returning: port)
                        self.portContinuation = nil
                    }
                case .failed(let error):
                    self.portContinuation?.resume(throwing: error)
                    self.portContinuation = nil
                    self.finish(.failure(error))
                case .cancelled:
                    self.portContinuation?.resume(throwing: CancellationError())
                    self.portContinuation = nil
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    func waitForRedirect(timeout seconds: Double) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
            if let p = pending {
                pending = nil
                cont.resume(with: p)
                return
            }
            redirectContinuation = cont
            let work = DispatchWorkItem { [weak self] in self?.finish(.failure(GoogleError.timedOut)) }
            timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<[String: String], Error>) {
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        if let c = redirectContinuation {
            redirectContinuation = nil
            c.resume(with: result)
        } else if pending == nil {
            pending = result
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let line = text.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            var query: [String: String] = [:]
            if parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + String(parts[1])) {
                for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }
            }
            let relevant = query["code"] != nil || query["error"] != nil
            let body = relevant ? Self.page(success: query["code"] != nil) : "Not found"
            let status = relevant ? "200 OK" : "404 Not Found"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if relevant { self?.finish(.success(query)) }
        }
    }

    private static func page(success: Bool) -> String {
        let title = success ? "Briefing is connected." : "Briefing was not connected."
        let note = success ? "You can close this tab and go back to Briefing." : "Close this tab and try again from Briefing\u{2019}s Settings."
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Briefing</title>
        <style>body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
        background:#111;color:#fff;font:16px -apple-system,Helvetica Neue,sans-serif}
        h1{font-weight:500;font-size:40px;letter-spacing:-1px;margin:0 0 12px}p{opacity:.6;margin:0}</style>
        </head><body><div><h1>\(title)</h1><p>\(note)</p></div></body></html>
        """
    }
}

// MARK: - Calendar data

struct GoogleCalendar: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let primary: Bool
    /// Ticked in Google Calendar's own sidebar.
    let selectedInGoogle: Bool
}

private struct GoogleCache: Codable {
    var day = ""
    var fetchedAt: Date?
    var items: [AgendaItem] = []
    var calendars: [GoogleCalendar] = []
}

@MainActor
final class GoogleCalendarService: ObservableObject {
    static let shared = GoogleCalendarService()

    @Published private(set) var calendars: [GoogleCalendar]
    @Published private(set) var lastFetch: Date?
    private var cache: GoogleCache

    private init() {
        cache = JSONFile.load(GoogleCache.self, from: Paths.googleCache) ?? GoogleCache()
        calendars = cache.calendars
        lastFetch = cache.fetchedAt
    }

    /// Saved events for the day, minus calendars switched off in Settings.
    func cachedItems(for day: Date, settings: Settings) -> [AgendaItem] {
        guard cache.day == DayKey.day(day) else { return [] }
        return cache.items.filter { settings.calendarVisible("g:" + ($0.calendar ?? "")) }
    }

    func clear() {
        cache = GoogleCache()
        calendars = []
        lastFetch = nil
        JSONFile.save(cache, to: Paths.googleCache)
    }

    /// Fetches the day from every calendar on the account. True when it worked (or there is nothing to fetch).
    @discardableResult
    func refresh(day: Date) async -> Bool {
        let settings = SettingsStore.shared.settings
        guard settings.useGoogleCalendar, GoogleConfig.isConnected(settings) else { return true }
        do {
            let token = try await GoogleAccount.shared.token()
            let list = try await fetchCalendars(token)
            var items: [AgendaItem] = []
            for cal in list {
                items += try await fetchEvents(cal, day: day, token: token)
            }
            cache = GoogleCache(day: DayKey.day(day), fetchedAt: Date(), items: items, calendars: list)
            JSONFile.save(cache, to: Paths.googleCache)
            calendars = list
            lastFetch = cache.fetchedAt
            GoogleAccount.shared.lastError = nil
            return true
        } catch {
            Log.write("google: fetch failed — \(error)")
            if let g = error as? GoogleError, case .http(let code, _) = g, code == 400 || code == 401 {
                GoogleAccount.shared.lastError = error.localizedDescription
            }
            return false
        }
    }

    /// The list of calendars only (for Settings). Optionally hides those unticked in Google itself.
    func refreshCalendars(hideUnselected: Bool = false) async {
        do {
            let token = try await GoogleAccount.shared.token()
            let list = try await fetchCalendars(token)
            calendars = list
            cache.calendars = list
            JSONFile.save(cache, to: Paths.googleCache)
            if hideUnselected {
                SettingsStore.shared.update { s in
                    for c in list where !c.selectedInGoogle { s.setCalendar("g:" + c.id, visible: false) }
                }
            }
        } catch {
            Log.write("google: calendar list failed — \(error)")
        }
    }

    // MARK: API

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

    private func get<T: Decodable>(_ url: URL, _ token: String, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw GoogleError.http(status, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func fetchCalendars(_ token: String) async throws -> [GoogleCalendar] {
        var c = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        c.queryItems = [URLQueryItem(name: "maxResults", value: "250")]
        let list = try await get(c.url!, token, as: CalendarList.self)
        return (list.items ?? [])
            .filter { $0.deleted != true }
            .map { GoogleCalendar(id: $0.id,
                                  name: $0.summaryOverride ?? $0.summary ?? $0.id,
                                  primary: $0.primary ?? false,
                                  selectedInGoogle: $0.selected ?? false) }
            .sorted { a, b in
                if a.primary != b.primary { return a.primary }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    private static let idAllowed: CharacterSet = {
        var s = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        s.insert(charactersIn: "-._~@")
        return s
    }()

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

    private func fetchEvents(_ cal: GoogleCalendar, day: Date, token: String) async throws -> [AgendaItem] {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? day
        let id = cal.id.addingPercentEncoding(withAllowedCharacters: Self.idAllowed) ?? cal.id
        guard var c = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(id)/events") else {
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
                    id: "g:\(cal.id):\(e.id)",
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
                    id: "g:\(cal.id):\(e.id)",
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
