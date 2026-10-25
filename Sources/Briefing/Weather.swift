import Foundation

struct WeatherSnapshot: Codable, Equatable, Sendable {
    var temperature: Double
    var minimum: Double
    var maximum: Double
    var code: Int
    var isDay: Bool
    var precipitationProbability: Int?
    var day: String        // "yyyy-MM-dd", the day the low/high belong to
    var fetchedAt: Date
    /// Where it was fetched for; nil in caches written by earlier builds.
    var latitude: Double?
    var longitude: Double?

    /// Same place as the city in Settings (to about a kilometre).
    func isFor(_ s: Settings) -> Bool {
        guard let latitude, let longitude else { return false }
        return abs(latitude - s.latitude) < 0.01 && abs(longitude - s.longitude) < 0.01
    }

    var isSnow: Bool { [71, 73, 75, 77, 85, 86].contains(code) }

    var conditions: String {
        switch code {
        case 0: return isDay ? "Clear" : "Clear night"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71: return "Light snow"
        case 73: return "Snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80, 81: return "Showers"
        case 82: return "Heavy showers"
        case 85, 86: return "Snowfall"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm, hail"
        default: return "—"
        }
    }

    /// Fahrenheit if that is what the Mac is set to (System Settings → Language & Region → Temperature).
    static var usesFahrenheit: Bool {
        if let unit = UserDefaults.standard.string(forKey: "AppleTemperatureUnit") { return unit == "Fahrenheit" }
        return Locale.autoupdatingCurrent.measurementSystem == .us
    }

    /// Celsius in, the person's own unit out.
    static func format(_ celsius: Double) -> String {
        let t = usesFahrenheit ? celsius * 9 / 5 + 32 : celsius
        let v = Int(t.rounded())
        if v < 0 { return "\u{2212}\(abs(v))°" }  // a true minus sign
        return "\(v)°"
    }
}

final class WeatherService {
    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int?
        }
        struct Daily: Decodable {
            let time: [String]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
            let precipitation_probability_max: [Int?]?
        }
        let current: Current
        let daily: Daily
    }

    /// The last weather saved, only if it belongs to the city now set.
    func cached(for settings: Settings) -> WeatherSnapshot? {
        guard let w = JSONFile.load(WeatherSnapshot.self, from: Paths.weatherCache), w.isFor(settings) else { return nil }
        return w
    }

    func fetch(settings: Settings) async throws -> WeatherSnapshot {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(settings.latitude)),
            URLQueryItem(name: "longitude", value: String(settings.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: settings.timezone),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let r = try JSONDecoder().decode(Response.self, from: data)
        let snapshot = WeatherSnapshot(
            temperature: r.current.temperature_2m,
            minimum: r.daily.temperature_2m_min.first.flatMap { $0 } ?? r.current.temperature_2m,
            maximum: r.daily.temperature_2m_max.first.flatMap { $0 } ?? r.current.temperature_2m,
            code: r.current.weather_code,
            isDay: (r.current.is_day ?? 1) == 1,
            precipitationProbability: r.daily.precipitation_probability_max?.first.flatMap { $0 },
            day: r.daily.time.first ?? DayKey.day(Date()),
            fetchedAt: Date(),
            latitude: settings.latitude,
            longitude: settings.longitude
        )
        JSONFile.save(snapshot, to: Paths.weatherCache)
        return snapshot
    }
}
