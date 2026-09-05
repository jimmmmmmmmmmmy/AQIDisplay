import Foundation
import Darwin
import CSQLite

public enum AirError: Error, LocalizedError, Sendable {
    case token, connection, station, storage
    public var errorDescription: String? {
        switch self {
        case .token: "Add your API key in Settings."
        case .connection: "Unable to connect. Try again."
        case .station: "No reading is available for this station."
        case .storage: "Unable to save local history."
        }
    }
}

public enum Paths {
    public static var directory: URL {
        let override = ProcessInfo.processInfo.environment["OPENAIR_DATA_DIR"]
        return override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/OpenAir", directoryHint: .isDirectory)
    }
    public static func prepare(_ directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public static func token(in directory: URL = directory) -> String {
        let value = ProcessInfo.processInfo.environment["WAQI_API_TOKEN"]
            ?? (try? String(contentsOf: directory.appending(path: "waqi-token"), encoding: .utf8)) ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func saveToken(_ token: String, in directory: URL = directory) throws {
        try prepare(directory)
        let url = directory.appending(path: "waqi-token")
        // Atomic replacement with restrictive permissions before writing secret bytes.
        let temporary = directory.appending(path: UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw AirError.storage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            try handle.close()
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw AirError.storage }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw AirError.storage
        }
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var city = "here"
    public var temperatureUnit = "°F"
    public var formatOptions: [String: Bool] = ["City": false, "AQI": true, "Temperature": true, "Humidity": false]
    enum CodingKeys: String, CodingKey { case city; case temperatureUnit = "temperature_unit"; case formatOptions = "format_options" }
    public init() {}
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        city = try values.decodeIfPresent(String.self, forKey: .city) ?? "here"
        temperatureUnit = try values.decodeIfPresent(String.self, forKey: .temperatureUnit) ?? "°F"
        formatOptions = try values.decodeIfPresent([String: Bool].self, forKey: .formatOptions) ?? ["AQI": true, "Temperature": true]
    }
    public static func load(from directory: URL = Paths.directory) -> Self {
        guard let data = try? Data(contentsOf: directory.appending(path: "settings.json")),
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if value.city.isEmpty { value.city = "here" }
        if !["°F", "°C"].contains(value.temperatureUnit) { value.temperatureUnit = "°F" }
        return value
    }
    public func save(to directory: URL = Paths.directory) throws {
        try Paths.prepare(directory)
        // Preserve settings keys belonging to another version of the app.
        let url = directory.appending(path: "settings.json")
        let existing = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        var merged = existing
        let new = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
        merged.merge(new) { _, latest in latest }
        try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum ReadingFreshness: Sendable, Equatable {
    case current, stale, differentDay, future, unverified
    public var isCurrent: Bool { self == .current }
}

public struct Reading: Sendable, Equatable {
    public let aqi: Int
    public let city: String
    public let stationTime: String
    public let sourceURL: URL?
    public let providers: [String]
    public let values: [String: Double]
    public let fetched: Date
    public let observedAt: Date?
    public let stationTimeZone: TimeZone?
    public let stationID: Int?
    public init(aqi: Int, city: String, stationTime: String = "", sourceURL: URL? = nil, providers: [String] = [], values: [String: Double] = [:], fetched: Date = Date(), observedAt: Date? = nil, stationTimeZone: TimeZone? = nil, stationID: Int? = nil) {
        self.aqi = aqi; self.city = city; self.stationTime = stationTime; self.sourceURL = sourceURL
        self.providers = providers; self.values = values; self.fetched = fetched
        self.observedAt = observedAt; self.stationTimeZone = stationTimeZone; self.stationID = stationID
    }
    public var category: String {
        switch aqi { case ...50: "Good"; case ...100: "Moderate"; case ...150: "Unhealthy for Sensitive Groups"
        case ...200: "Unhealthy"; case ...300: "Very Unhealthy"; default: "Hazardous" }
    }
    public func temperature(fahrenheit: Bool) -> Double? { values["t"].map { fahrenheit ? $0 * 9 / 5 + 32 : $0 } }
    public func freshness(at now: Date = Date()) -> ReadingFreshness {
        guard let observedAt, let stationTimeZone,
              observedAt.timeIntervalSinceReferenceDate.isFinite, now.timeIntervalSinceReferenceDate.isFinite else { return .unverified }
        let age = now.timeIntervalSince(observedAt)
        guard age >= -600 else { return .future }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = stationTimeZone
        guard calendar.isDate(observedAt, inSameDayAs: now) else { return .differentDay }
        return age <= 3 * 3600 ? .current : .stale
    }
}

// WAQI's epoch-like `time.v` is not reliably UTC. Only use a timestamp whose
// timezone is explicit; never infer the station's time from this Mac's timezone.
private enum ObservationTime {
    static func parse(_ time: [String: Any]) -> (date: Date, zone: TimeZone)? {
        if let iso = time["iso"] as? String,
           let match = captures(#"^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$"#, in: iso),
           let zone = zone(match[4]), let date = wallTime(match[1] + " " + match[2], zone: zone) {
            let fraction = Double("0" + match[3]) ?? 0
            return (date.addingTimeInterval(fraction), zone)
        }
        guard let string = time["s"] as? String,
              let timeZone = time["tz"] as? String, let zone = zone(timeZone),
              let date = wallTime(string, zone: zone) else { return nil }
        return (date, zone)
    }
    private static func zone(_ string: String) -> TimeZone? {
        if ["Z", "UTC", "GMT"].contains(string) { return TimeZone(secondsFromGMT: 0) }
        if let match = captures(#"^([+-])([0-9]{2}):?([0-9]{2})$"#, in: string),
           let hours = Int(match[2]), let minutes = Int(match[3]), hours <= 14, minutes < 60,
           hours < 14 || minutes == 0 {
            // RFC 3339 -00:00 means the local offset is unknown.
            guard match[1] != "-" || hours != 0 || minutes != 0 else { return nil }
            return TimeZone(secondsFromGMT: (hours * 3600 + minutes * 60) * (match[1] == "-" ? -1 : 1))
        }
        // Allow explicit IANA identifiers, but avoid ambiguous abbreviations.
        return string.contains("/") ? TimeZone(identifier: string) : nil
    }
    private static func wallTime(_ string: String, zone: TimeZone) -> Date? {
        guard captures(#"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$"#, in: string) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        guard let date = formatter.date(from: string), formatter.string(from: date) == string else { return nil }
        return date
    }
    private static func captures(_ pattern: String, in string: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: string).map { String(string[$0]) } ?? ""
        }
    }
}

public struct Station: Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let aqi: Int?
    public init(id: Int, name: String, aqi: Int?) { self.id = id; self.name = name; self.aqi = aqi }
}

public struct WAQIClient: Sendable {
    private let token: String
    private let session: URLSession
    public init(token: String = Paths.token(), session: URLSession = .shared) { self.token = token; self.session = session }
    public func url(path: String, keyword: String? = nil) throws -> URL {
        guard !token.isEmpty else { throw AirError.token }
        var components = URLComponents()
        components.scheme = "https"; components.host = "api.waqi.info"; components.path = path
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        if let keyword { components.queryItems?.append(URLQueryItem(name: "keyword", value: keyword)) }
        guard let url = components.url else { throw AirError.station }
        return url
    }
    private func request(path: String, keyword: String? = nil) async throws -> Data {
        var request = URLRequest(url: try url(path: path, keyword: keyword))
        request.timeoutInterval = 20
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw AirError.connection }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw AirError.connection }
    }
    public func feed(_ location: String) async throws -> Reading {
        let location = location.contains(";") && !location.hasPrefix("geo:") ? "geo:" + location : location
        return try Self.parseFeed(await request(path: "/feed/\(location)/"))
    }
    public func search(_ keyword: String) async throws -> [Station] {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        return try Self.parseSearch(await request(path: "/search/", keyword: keyword))
    }
    private static func body(_ data: Data) throws -> Any {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value["status"] as? String == "ok", let body = value["data"] else { throw AirError.station }
        return body
    }
    private static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let number = value as? NSNumber { result = number.doubleValue }
        else if let string = value as? String { result = Double(string) }
        else { result = nil }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
    public static func parseFeed(_ data: Data) throws -> Reading {
        guard let body = try body(data) as? [String: Any], let aqi = number(body["aqi"]), aqi >= 0, aqi < Double(Int.max),
              let city = body["city"] as? [String: Any], let name = city["name"] as? String, !name.isEmpty else { throw AirError.station }
        let raw = body["iaqi"] as? [String: [String: Any]] ?? [:]
        let values = raw.compactMapValues { number($0["v"]) }
        let time = body["time"] as? [String: Any] ?? [:]
        let stationTime = time["s"] as? String ?? time["iso"] as? String ?? ""
        let observation = ObservationTime.parse(time)
        let providers = (body["attributions"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let source = (city["url"] as? String).flatMap(URL.init(string:))
        return Reading(aqi: Int(aqi.rounded()), city: name, stationTime: stationTime,
                       sourceURL: source?.scheme == "https" ? source : nil, providers: providers, values: values,
                       observedAt: observation?.date, stationTimeZone: observation?.zone,
                       stationID: (body["idx"] as? Int).flatMap { $0 > 0 ? $0 : nil })
    }
    public static func parseSearch(_ data: Data) throws -> [Station] {
        guard let rows = try body(data) as? [[String: Any]] else { throw AirError.station }
        var seen = Set<Int>()
        return rows.compactMap { row in
            guard let uid = row["uid"] as? Int, seen.insert(uid).inserted,
                  let station = row["station"] as? [String: Any], let name = station["name"] as? String else { return nil }
            let aqi = number(row["aqi"]).flatMap { $0 >= 0 && $0 < Double(Int.max) ? Int($0.rounded()) : nil }
            return Station(id: uid, name: name, aqi: aqi)
        }
    }
}

public struct HistoryPoint: Identifiable, Sendable {
    public var id: String { timestamp }
    public let timestamp: String
    public let date: Date
    public let aqi: Int
    public let temperature: Double?
    public init(timestamp: String, date: Date, aqi: Int, temperature: Double?) {
        self.timestamp = timestamp; self.date = date; self.aqi = aqi; self.temperature = temperature
    }
}

public final class History {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw AirError.storage }
        sqlite3_busy_timeout(db, 2000)
        try execute("CREATE TABLE IF NOT EXISTS aqi_data (timestamp TEXT PRIMARY KEY, city TEXT, aqi INTEGER, pm25 REAL, pm10 REAL, o3 REAL, no2 REAL, so2 REAL, co REAL, temperature REAL, pressure REAL, humidity REAL, wind REAL)")
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AirError.storage } }
    public func store(_ reading: Reading) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO aqi_data VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw AirError.storage }
        defer { sqlite3_finalize(statement) }
        var date = reading.fetched
        for _ in 0..<100 {
            sqlite3_reset(statement)
            let timestamp = Self.format(date)
            sqlite3_bind_text(statement, 1, timestamp, -1, transient)
            sqlite3_bind_text(statement, 2, reading.city, -1, transient)
            sqlite3_bind_int64(statement, 3, Int64(reading.aqi))
            for (index, key) in ["pm25","pm10","o3","no2","so2","co","t","p","h","w"].enumerated() {
                if let value = reading.values[key] { sqlite3_bind_double(statement, Int32(index + 4), value) }
                else { sqlite3_bind_null(statement, Int32(index + 4)) }
            }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_CONSTRAINT else { throw AirError.storage }
            date = date.addingTimeInterval(0.001)
        }
        throw AirError.storage
    }
    public func recent(city: String, now: Date = Date()) throws -> [HistoryPoint] {
        var statement: OpaquePointer?
        let query = """
        WITH readings AS (SELECT *, ROW_NUMBER() OVER (
          PARTITION BY strftime('%Y-%m-%d %H', timestamp) ORDER BY timestamp DESC) AS rn
          FROM aqi_data WHERE city = ? AND timestamp > ?)
        SELECT timestamp, aqi, temperature FROM readings WHERE rn = 1 ORDER BY timestamp ASC
        """
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw AirError.storage }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, city, -1, transient)
        sqlite3_bind_text(statement, 2, Self.format(now.addingTimeInterval(-86400)), -1, transient)
        var rows: [HistoryPoint] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let timestamp = String(cString: sqlite3_column_text(statement, 0))
            if let date = Self.parse(timestamp) {
                rows.append(HistoryPoint(timestamp: timestamp, date: date, aqi: Int(sqlite3_column_int64(statement, 1)),
                    temperature: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2)))
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw AirError.storage }
        return rows
    }
    public static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return formatter.string(from: date)
    }
    public static func parse(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        if let date = formatter.date(from: string) { return date }
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: string)
    }
}

public final class InstanceLock {
    private var descriptor: Int32 = -1
    public init() {}
    public func acquire(in directory: URL = Paths.directory) throws -> Bool {
        if descriptor >= 0 { return true }
        try Paths.prepare(directory)
        let fd = Darwin.open(directory.appending(path: "openair.lock").path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw AirError.storage }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        descriptor = fd
        return true
    }
    deinit { if descriptor >= 0 { close(descriptor) } }
}
