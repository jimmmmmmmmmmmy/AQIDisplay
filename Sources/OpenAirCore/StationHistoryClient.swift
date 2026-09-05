import Foundation
import CoreFoundation

public enum StationHistoryError: Error, LocalizedError, Sendable {
    case unavailable, invalidPage, wrongStation
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Earlier readings are unavailable for this station."
        case .invalidPage: "Earlier station readings could not be verified."
        case .wrongStation: "The history source returned a different station."
        }
    }
}

/// Imports the measured pollutant histories used by WAQI's public station chart.
/// This is a best-effort page adapter, not the WAQI current-reading API. It never
/// sends the API token, executes page JavaScript, or substitutes forecast data.
public struct StationHistoryClient: Sendable {
    public static let maximumPageBytes = 2_000_000
    private static let pollutantKeys: Set<String> = ["pm25", "pm10", "o3", "no2", "so2", "co"]
    // A single anonymous session avoids retaining a new delegate/session pair on
    // every five-minute refresh. No per-user authentication state is attached.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: StationPageRedirectPolicy(), delegateQueue: nil)
    }()

    public init() {}

    public func fetch(for reading: Reading) async throws -> [Reading] {
        var request = URLRequest(url: try Self.pageURL(for: reading))
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let url = response.url, Self.allowedPageURL(url),
              response.expectedContentLength <= Int64(Self.maximumPageBytes),
              response.mimeType?.lowercased() == "text/html" else { throw StationHistoryError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maximumPageBytes else { throw StationHistoryError.invalidPage }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try Self.parsePage(data, for: reading)
    }

    public static func pageURL(for reading: Reading) throws -> URL {
        guard reading.stationID.map({ $0 > 0 }) == true,
              reading.observedAt != nil, reading.stationTimeZone != nil,
              let source = reading.sourceURL, allowedPageURL(source),
              var components = URLComponents(url: source, resolvingAgainstBaseURL: false) else {
            throw StationHistoryError.unavailable
        }
        // No query, fragment, credentials, or API token is ever carried across.
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw StationHistoryError.unavailable }
        return url
    }

    fileprivate static func allowedPageURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "aqicn.org"
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
            && url.path.hasPrefix("/city/")
    }

    public static func parsePage(_ data: Data, for reading: Reading, now: Date = Date()) throws -> [Reading] {
        _ = try pageURL(for: reading)
        guard data.count <= maximumPageBytes, let html = String(data: data, encoding: .utf8),
              let anchor = reading.observedAt, let zone = reading.stationTimeZone,
              now.timeIntervalSince1970.isFinite, anchor.timeIntervalSince1970.isFinite else {
            throw StationHistoryError.invalidPage
        }
        let model = try embeddedModel(in: html)
        guard let city = model["city"] as? [String: Any],
              let station = integer(city["idx"]), station == reading.stationID else {
            throw StationHistoryError.wrongStation
        }
        guard let series = model["iaqi"] as? [[String: Any]], !series.isEmpty else {
            throw StationHistoryError.unavailable
        }
        let currentPollutants = Set(reading.values.keys).intersection(pollutantKeys)
        var decoded: [String: [Date: Double]] = [:]
        for item in series {
            guard let key = item["p"] as? String, pollutantKeys.contains(key) else { continue }
            guard decoded[key] == nil else { throw StationHistoryError.invalidPage }
            decoded[key] = try decodeHistory(item["h"], zone: zone)
        }
        guard !decoded.isEmpty, currentPollutants.isSubset(of: Set(decoded.keys)) else {
            throw StationHistoryError.unavailable
        }
        // A missing pollutant can hide the highest index. Only combine exact
        // simultaneous observations present in every advertised pollutant series.
        // A multi-hour gap stays a gap: never repeat the last known reading.
        var commonTimes = Set(decoded.values.first!.keys)
        for values in decoded.values { commonTimes.formIntersection(values.keys) }
        let lower = now.addingTimeInterval(-86400)
        let upper = min(now, anchor)
        let formatter = wallFormatter(zone: zone)
        return commonTimes.sorted().compactMap { date in
            guard date >= lower, date < upper else { return nil }
            let values = decoded.mapValues { $0[date]! }
            guard let index = values.values.max(), index.isFinite, index >= 0, index <= 10_000 else { return nil }
            return Reading(aqi: Int(index.rounded()), city: reading.city,
                           stationTime: formatter.string(from: date), sourceURL: reading.sourceURL,
                           providers: reading.providers, values: values, fetched: now,
                           observedAt: date, stationTimeZone: zone, stationID: station)
        }
    }

    private static func embeddedModel(in html: String) throws -> [String: Any] {
        // Extract one balanced JSON object, respecting strings/escapes. Do not
        // evaluate the surrounding script or use a greedy HTML regular expression.
        guard let marker = html.range(of: "setWidgetAqiGraphModel("),
              let start = html[marker.upperBound...].firstIndex(where: { !$0.isWhitespace }),
              html[start] == "{" else { throw StationHistoryError.unavailable }
        var depth = 0, quoted = false, escaped = false
        var end: String.Index?
        for index in html[start...].indices {
            let character = html[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { end = html.index(after: index); break }
            }
        }
        guard let end,
              let object = try? JSONSerialization.jsonObject(with: Data(html[start..<end].utf8)) as? [String: Any] else {
            throw StationHistoryError.invalidPage
        }
        return object
    }

    private static func decodeHistory(_ raw: Any?, zone: TimeZone) throws -> [Date: Double] {
        guard let history = raw as? [Any], history.count == 3,
              let wall = history[0] as? String,
              let divisor = number(history[1]), divisor > 0, divisor <= 1_000_000,
              let tokens = history[2] as? [Any], tokens.count <= 10_000 else {
            throw StationHistoryError.invalidPage
        }
        let formatter = wallFormatter(zone: zone)
        guard let base = formatter.date(from: wall), formatter.string(from: base) == wall else {
            throw StationHistoryError.invalidPage
        }
        var cursor = base, cumulative = 0.0, result: [Date: Double] = [:], count = 0
        func append(hours: Int, delta: Double) throws {
            guard hours >= 0, hours <= 24 * 366, hours > 0 || count == 0,
                  delta.isFinite, count < 10_000 else { throw StationHistoryError.invalidPage }
            cursor = cursor.addingTimeInterval(-Double(hours) * 3600)
            cumulative += delta
            let value = cumulative / divisor
            guard value.isFinite else { throw StationHistoryError.invalidPage }
            if value >= 0, value <= 10_000 { result[cursor] = value }
            count += 1
        }
        // The public chart decoder uses descending, delta-encoded observations:
        // https://aqicn.org/air-cache/header/bundle.min.js (AqiGraphFactory.init).
        for token in tokens {
            if let text = token as? String {
                for scalar in text.unicodeScalars {
                    let code = scalar.value
                    guard (65...90).contains(code) || (97...122).contains(code) else { throw StationHistoryError.invalidPage }
                    try append(hours: 1, delta: code >= 97 ? Double(code - 97) : -Double(code - 65 + 1))
                }
            } else if let pair = token as? [Any] {
                guard pair.count == 2, let hours = integer(pair[0]), let delta = number(pair[1]) else {
                    throw StationHistoryError.invalidPage
                }
                try append(hours: hours, delta: delta)
            } else if let delta = number(token) {
                try append(hours: 1, delta: delta)
            } else { throw StationHistoryError.invalidPage }
        }
        return result
    }

    private static func wallFormatter(zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        formatter.isLenient = false
        return formatter
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    private static func integer(_ raw: Any?) -> Int? {
        guard let value = number(raw), value.rounded() == value, value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }
}

private final class StationPageRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, StationHistoryClient.allowedPageURL(url),
              url.query == nil, url.fragment == nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}
