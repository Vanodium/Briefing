import Foundation

// MARK: - Paths

enum Paths {
    static let support: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Briefing", isDirectory: true)
        // The app was called Morning before: its data folder moves over once.
        let old = base.appendingPathComponent("Morning", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var settings: URL { support.appendingPathComponent("settings.json") }
    static var mindset: URL { support.appendingPathComponent("mindset.json") }
    static var challenges: URL { support.appendingPathComponent("challenges.json") }
    static var archive: URL { support.appendingPathComponent("challenges-archive.md") }
    static var state: URL { support.appendingPathComponent("state.json") }
    static var weatherCache: URL { support.appendingPathComponent("weather-cache.json") }
    static var googleCache: URL { support.appendingPathComponent("google-cache.json") }
    static var fonts: URL { support.appendingPathComponent("Fonts", isDirectory: true) }

    static let log: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("Morning.log"))   // from before the rename
        return dir.appendingPathComponent("Briefing.log")
    }()
}

// MARK: - Log (to verify that the trigger fires reliably)

enum Log {
    private static let queue = DispatchQueue(label: "briefing.log")

    static func write(_ message: String) {
        let line = "\(timestamp()) \(message)\n"
        queue.async {
            let url = Paths.log
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > 512_000 {
                try? FileManager.default.removeItem(at: url)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}

// MARK: - JSON

enum JSONFile {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Log.write("json: could not read \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.write("json: could not write \(url.lastPathComponent): \(error)")
        }
    }
}

// MARK: - Day and month keys

enum DayKey {
    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func month(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func nextMonth(after date: Date) -> Date {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
        return cal.date(byAdding: .month, value: 1, to: start) ?? date
    }

    static func date(fromMonthKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
    }

    static func isLastDayOfMonth(_ date: Date) -> Bool {
        let cal = Calendar.current
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: date) else { return false }
        return cal.component(.month, from: tomorrow) != cal.component(.month, from: date)
    }
}

// MARK: - File models

struct MindsetFile: Codable {
    var principles: [String] = ["Keep my word."]
    var lines: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        principles = (try? c.decodeIfPresent([String].self, forKey: .principles)) ?? []
        lines = (try? c.decodeIfPresent([String].self, forKey: .lines)) ?? []
    }
}

struct ChallengesFile: Codable {
    /// "2026-10": ["Drink more water", ...]
    var months: [String: [String]] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        months = (try? c.decodeIfPresent([String: [String]].self, forKey: .months)) ?? [:]
    }
}

struct AppState: Codable {
    var lastShownDay: String?
    var lastShownAt: Date?
    var lastShownReason: String?
}

// MARK: - Data store

final class DataStore {
    static let shared = DataStore()

    private(set) var state: AppState

    private init() {
        state = JSONFile.load(AppState.self, from: Paths.state) ?? AppState()
    }

    // "Shown today" marker — survives restarts and reboots.
    func wasShown(on date: Date) -> Bool {
        state.lastShownDay == DayKey.day(date)
    }

    func markShown(_ date: Date, reason: String) {
        state.lastShownDay = DayKey.day(date)
        state.lastShownAt = date
        state.lastShownReason = reason
        JSONFile.save(state, to: Paths.state)
    }

    func resetShown() {
        state = AppState()
        JSONFile.save(state, to: Paths.state)
    }

    // Mindset
    func loadMindset() -> MindsetFile {
        if let m = JSONFile.load(MindsetFile.self, from: Paths.mindset) { return m }
        let seed = MindsetFile()
        if !FileManager.default.fileExists(atPath: Paths.mindset.path) {
            JSONFile.save(seed, to: Paths.mindset)
        }
        return seed
    }

    func saveMindset(_ m: MindsetFile) {
        JSONFile.save(m, to: Paths.mindset)
    }

    // Challenges: on load, past months are moved to the archive.
    func loadChallenges(now: Date = Date()) -> ChallengesFile {
        var file = JSONFile.load(ChallengesFile.self, from: Paths.challenges) ?? ChallengesFile()
        let current = DayKey.month(now)
        let expired = file.months.keys.filter { $0 < current }.sorted()
        if !expired.isEmpty {
            for key in expired {
                let items = file.months[key] ?? []
                if !items.isEmpty { appendToArchive(monthKey: key, items: items) }
                file.months.removeValue(forKey: key)
            }
            JSONFile.save(file, to: Paths.challenges)
            Log.write("challenges: archived \(expired.joined(separator: ", "))")
        }
        return file
    }

    func saveChallenges(_ file: ChallengesFile) {
        JSONFile.save(file, to: Paths.challenges)
    }

    private func appendToArchive(monthKey: String, items: [String]) {
        var title = monthKey
        if let d = DayKey.date(fromMonthKey: monthKey) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "MMMM yyyy"
            title = f.string(from: d)
        }
        var text = "## \(title)\n"
        for item in items { text += "- \(item)\n" }
        text += "\n"
        let url = Paths.archive
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? "# Challenge archive\n\n"
        try? (existing + text).write(to: url, atomically: true, encoding: .utf8)
    }
}
