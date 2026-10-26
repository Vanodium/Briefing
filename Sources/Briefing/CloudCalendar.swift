import AppKit
import CryptoKit
import Foundation
import Network
import Security

// MARK: - Providers

/// Calendars read straight from an online account, without adding it to macOS.
/// Each one needs an OAuth client of its own; build.sh writes its ID into Info.plist (see the README).
/// Without an ID the provider says it is not set up in this build, and nothing else changes.
enum CloudProvider: String, CaseIterable, Identifiable, Sendable {
    case google

    var id: String { rawValue }

    /// The calendar, as people call it.
    var name: String {
        switch self {
        case .google: return "Google Calendar"
        }
    }

    /// The account, as its owner calls it.
    var accountName: String {
        switch self {
        case .google: return "Google"
        }
    }

    /// Prefix for this provider's calendar IDs in `Settings.hiddenCalendars` and item IDs.
    var prefix: String {
        switch self {
        case .google: return "g:"
        }
    }

    var clientID: String { Self.value(infoKey + "ClientID") }
    /// Google issues a "secret" for desktop clients too. It is not a real secret (it ships inside the app),
    /// but its token endpoint asks for it.
    var clientSecret: String { Self.value(infoKey + "ClientSecret") }
    var isConfigured: Bool { !clientID.isEmpty }

    func isConnected(_ settings: Settings) -> Bool {
        isConfigured && !settings[keyPath: accountKey].isEmpty
    }

    /// Connected and switched on: its events belong on the dashboard.
    func isActive(_ settings: Settings) -> Bool {
        settings[keyPath: useKey] && isConnected(settings)
    }

    var useKey: WritableKeyPath<Settings, Bool> {
        switch self {
        case .google: return \.useGoogleCalendar
        }
    }

    var accountKey: WritableKeyPath<Settings, String> {
        switch self {
        case .google: return \.googleAccount
        }
    }

    var cacheFile: URL {
        switch self {
        case .google: return Paths.googleCache
        }
    }

    // MARK: OAuth

    var authURL: String {
        switch self {
        case .google: return "https://accounts.google.com/o/oauth2/v2/auth"
        }
    }

    var tokenURL: String {
        switch self {
        case .google: return "https://oauth2.googleapis.com/token"
        }
    }

    /// Where to tell the provider to forget the grant on disconnect.
    var revokeURL: String? {
        switch self {
        case .google: return "https://oauth2.googleapis.com/revoke"
        }
    }

    /// Read-only: Briefing never changes a calendar. openid + email only to show which account is connected.
    var scopes: String {
        switch self {
        case .google: return "openid email https://www.googleapis.com/auth/calendar.readonly"
        }
    }

    /// The loopback address the sign-in page sends the browser back to.
    var redirectHost: String {
        switch self {
        case .google: return "127.0.0.1"
        }
    }

    /// What it takes to be handed a refresh token.
    var offlineParams: [String: String] {
        switch self {
        case .google: return ["access_type": "offline", "prompt": "consent"]
        }
    }

    fileprivate var keychainService: String {
        switch self {
        case .google: return "Briefing.Google"
        }
    }

    var api: CalendarAPI {
        switch self {
        case .google: return GoogleCalendarAPI()
        }
    }

    /// Those with an OAuth client in this build.
    static var configured: [CloudProvider] { allCases.filter(\.isConfigured) }

    private var infoKey: String {
        switch self {
        case .google: return "Google"
        }
    }

    private static func value(_ key: String) -> String {
        ((Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CloudError: LocalizedError {
    case notConfigured, notConnected, denied(String), badResponse, noRefreshToken, timedOut, http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Sign-in is not set up in this build."
        case .notConnected: return "No account is connected."
        case .denied(let why): return why == "access_denied" ? "Access was not granted." : "The sign-in page said: \(why)."
        case .badResponse: return "The answer could not be understood."
        case .noRefreshToken: return "Lasting access was not granted. Try connecting again."
        case .timedOut: return "Sign-in took too long. Try again."
        case .http(let code, _): return code == 400 || code == 401
            ? "Access has expired. Connect the account again."
            : "The calendar is not reachable right now (\(code))."
        }
    }

    /// The account has to be connected again; retrying will not help.
    var needsReconnect: Bool {
        if case .http(let code, _) = self { return code == 400 || code == 401 }
        return false
    }
}

// MARK: - Keychain

/// Refresh tokens are the one thing that must not sit in a JSON file.
enum Keychain {
    static func read(_ account: String, service: String) -> String? {
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

    static func write(_ value: String?, _ account: String, service: String) {
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

/// Sign-in in the person's own browser (OAuth 2.0 for installed apps: PKCE + a loopback redirect).
@MainActor
final class CloudAccount: ObservableObject {
    static let google = CloudAccount(.google)

    static func shared(_ provider: CloudProvider) -> CloudAccount {
        switch provider {
        case .google: return google
        }
    }

    let provider: CloudProvider
    @Published private(set) var busy = false
    @Published var lastError: String?

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var server: LoopbackServer?
    private static let refreshKey = "refresh_token"

    private init(_ provider: CloudProvider) {
        self.provider = provider
    }

    var isConnected: Bool { provider.isConnected(SettingsStore.shared.settings) }

    private var log: String { "\(provider.rawValue):" }

    func connect() async {
        guard !busy else { return }
        guard provider.isConfigured else { lastError = CloudError.notConfigured.errorDescription; return }
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
            let redirect = "http://\(provider.redirectHost):\(port)"

            var c = URLComponents(string: provider.authURL)!
            c.queryItems = [
                URLQueryItem(name: "client_id", value: provider.clientID),
                URLQueryItem(name: "redirect_uri", value: redirect),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: provider.scopes),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state),
            ] + provider.offlineParams.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = c.url else { throw CloudError.badResponse }
            NSWorkspace.shared.open(url)

            let query = try await server.waitForRedirect(timeout: 300)
            self.server = nil
            if let error = query["error"] { throw CloudError.denied(error) }
            guard query["state"] == state, let code = query["code"] else { throw CloudError.badResponse }

            let token = try await exchange([
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": redirect,
                "grant_type": "authorization_code",
            ])
            guard let refresh = token.refresh_token else { throw CloudError.noRefreshToken }
            Keychain.write(refresh, Self.refreshKey, service: provider.keychainService)
            accessToken = token.access_token
            expiry = Date().addingTimeInterval(Double(token.expires_in ?? 3600) - 60)
            let email = token.id_token.flatMap(Self.email(fromIDToken:)) ?? "\(provider.accountName) account"

            let provider = self.provider
            SettingsStore.shared.update {
                $0[keyPath: provider.accountKey] = email
                $0[keyPath: provider.useKey] = true
            }
            Log.write("\(log) connected")
            NSAppActivate()
            // Calendars hidden in the provider's own app start hidden here too.
            let data = CloudCalendarService.shared(provider)
            await data.refreshCalendars(hideUnselected: true)
            await data.refresh(day: Date())
            // The dashboard, if open, picks the new events up.
            NotificationCenter.default.post(name: .briefingSettingsChanged, object: nil)
        } catch is CancellationError {
            self.server = nil
        } catch {
            self.server?.cancel()
            self.server = nil
            lastError = error.localizedDescription
            Log.write("\(log) sign-in failed — \(error)")
        }
    }

    func cancelConnect() {
        server?.cancel()
        server = nil
    }

    func disconnect() {
        if let refresh = Keychain.read(Self.refreshKey, service: provider.keychainService),
           let revoke = provider.revokeURL.flatMap(URL.init(string:)) {
            // Best effort: tell the provider to forget the grant too.
            var request = URLRequest(url: revoke)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["token": refresh]).data(using: .utf8)
            URLSession.shared.dataTask(with: request).resume()
        }
        Keychain.write(nil, Self.refreshKey, service: provider.keychainService)
        accessToken = nil
        expiry = .distantPast
        lastError = nil
        CloudCalendarService.shared(provider).clear()
        let provider = self.provider
        SettingsStore.shared.update {
            $0[keyPath: provider.accountKey] = ""
            $0[keyPath: provider.useKey] = false
            $0.hiddenCalendars.removeAll { $0.hasPrefix(provider.prefix) }
        }
        Log.write("\(log) disconnected")
    }

    /// A valid access token, refreshed when the old one has expired.
    func token() async throws -> String {
        if let t = accessToken, Date() < expiry { return t }
        guard isConnected, let refresh = Keychain.read(Self.refreshKey, service: provider.keychainService) else {
            throw CloudError.notConnected
        }
        let r = try await exchange(["refresh_token": refresh, "grant_type": "refresh_token"])
        // A provider may hand out a new refresh token; the old one then stops working.
        if let next = r.refresh_token, next != refresh {
            Keychain.write(next, Self.refreshKey, service: provider.keychainService)
        }
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

    private func exchange(_ fields: [String: String]) async throws -> TokenResponse {
        var all = fields
        all["client_id"] = provider.clientID
        if !provider.clientSecret.isEmpty { all["client_secret"] = provider.clientSecret }
        var request = URLRequest(url: URL(string: provider.tokenURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(all).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw CloudError.http(status, String(data: data, encoding: .utf8) ?? "")
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

/// A one-request web server on 127.0.0.1 that catches the redirect after sign-in.
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
            let work = DispatchWorkItem { [weak self] in self?.finish(.failure(CloudError.timedOut)) }
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

struct CloudCalendar: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let primary: Bool
    /// Ticked in the provider's own app.
    let selected: Bool
}

/// What a provider's calendar API has to answer.
protocol CalendarAPI: Sendable {
    func calendars(token: String) async throws -> [CloudCalendar]
    /// The day's events; each item's `calendar` is the calendar's ID without the provider prefix.
    func events(in calendar: CloudCalendar, day: Date, token: String, prefix: String) async throws -> [AgendaItem]
}

extension CalendarAPI {
    func get<T: Decodable>(_ url: URL, _ token: String, headers: [String: String] = [:], as type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CloudError.http(status, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A calendar ID made safe for a URL path.
    func pathID(_ id: String) -> String {
        var s = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        s.insert(charactersIn: "-._~@")
        return id.addingPercentEncoding(withAllowedCharacters: s) ?? id
    }
}

private struct CloudCache: Codable {
    var day = ""
    var fetchedAt: Date?
    var items: [AgendaItem] = []
    var calendars: [CloudCalendar] = []
}

@MainActor
final class CloudCalendarService: ObservableObject {
    static let google = CloudCalendarService(.google)

    static func shared(_ provider: CloudProvider) -> CloudCalendarService {
        switch provider {
        case .google: return google
        }
    }

    let provider: CloudProvider
    @Published private(set) var calendars: [CloudCalendar]
    @Published private(set) var lastFetch: Date?
    private var cache: CloudCache

    private init(_ provider: CloudProvider) {
        self.provider = provider
        cache = JSONFile.load(CloudCache.self, from: provider.cacheFile) ?? CloudCache()
        calendars = cache.calendars
        lastFetch = cache.fetchedAt
    }

    private var account: CloudAccount { CloudAccount.shared(provider) }

    /// Saved events for the day, minus calendars switched off in Settings.
    func cachedItems(for day: Date, settings: Settings) -> [AgendaItem] {
        guard cache.day == DayKey.day(day) else { return [] }
        return cache.items.filter { settings.calendarVisible(provider.prefix + ($0.calendar ?? "")) }
    }

    func clear() {
        cache = CloudCache()
        calendars = []
        lastFetch = nil
        JSONFile.save(cache, to: provider.cacheFile)
    }

    /// Fetches the day from every calendar on the account. True when it worked (or there is nothing to fetch).
    @discardableResult
    func refresh(day: Date) async -> Bool {
        guard provider.isActive(SettingsStore.shared.settings) else { return true }
        do {
            let token = try await account.token()
            let api = provider.api
            let list = try await api.calendars(token: token)
            var items: [AgendaItem] = []
            for cal in list {
                items += try await api.events(in: cal, day: day, token: token, prefix: provider.prefix)
            }
            cache = CloudCache(day: DayKey.day(day), fetchedAt: Date(), items: items, calendars: list)
            JSONFile.save(cache, to: provider.cacheFile)
            calendars = list
            lastFetch = cache.fetchedAt
            account.lastError = nil
            return true
        } catch {
            Log.write("\(provider.rawValue): fetch failed — \(error)")
            if (error as? CloudError)?.needsReconnect == true {
                account.lastError = error.localizedDescription
            }
            return false
        }
    }

    /// The list of calendars only (for Settings). Optionally hides those unticked in the provider's own app.
    func refreshCalendars(hideUnselected: Bool = false) async {
        do {
            let token = try await account.token()
            let list = try await provider.api.calendars(token: token)
            calendars = list
            cache.calendars = list
            JSONFile.save(cache, to: provider.cacheFile)
            if hideUnselected {
                let prefix = provider.prefix
                SettingsStore.shared.update { s in
                    for c in list where !c.selected { s.setCalendar(prefix + c.id, visible: false) }
                }
            }
        } catch {
            Log.write("\(provider.rawValue): calendar list failed — \(error)")
        }
    }
}
