import Foundation
import OpenAirCore

private struct BackfillCheckFailure: Error, CustomStringConvertible { let description: String }
private func backfillRequire(_ condition: Bool, _ message: String) throws {
    guard condition else { throw BackfillCheckFailure(description: message) }
}
private let backfillNow = ISO8601DateFormatter().date(from: "2026-09-05T17:00:00Z")!
private let backfillAnchor = ISO8601DateFormatter().date(from: "2026-09-05T14:00:00Z")!
private let backfillZone = TimeZone(secondsFromGMT: -21600)!
private func backfillReading(source: String = "https://aqicn.org/city/texas/austin/austin-northwest/",
                             values: [String: Double] = ["pm25": 21, "o3": 6.4]) -> Reading {
    Reading(aqi: 21, city: "Austin Northwest", sourceURL: URL(string: source), values: values,
            fetched: backfillNow, observedAt: backfillAnchor, stationTimeZone: backfillZone, stationID: 218)
}
private func backfillSeries(_ key: String, _ tokens: [Any], base: String = "2026/09/05 08:00:00", divisor: Int = 1) -> [String: Any] {
    ["p": key, "h": [base, divisor, tokens]]
}
private func backfillPage(_ series: [[String: Any]], station: Int = 218) throws -> Data {
    let model: [String: Any] = ["city": ["idx": station, "name": "Escaped \" braces } { station"], "iaqi": series,
                               "forecast": ["daily": ["pm25": [["avg": 999, "day": "2026-09-04"]]]]]
    let json = try JSONSerialization.data(withJSONObject: model)
    return Data(("<html><script>try { setWidgetAqiGraphModel(" + String(decoding: json, as: UTF8.self) + "); } catch(e) {}</script></html>").utf8)
}
private func backfillMustThrow(_ operation: () throws -> Void) throws {
    do { try operation() } catch is BackfillCheckFailure { throw BackfillCheckFailure(description: "Unexpected check failure") }
    catch { return }
    throw BackfillCheckFailure(description: "Unverified history must be rejected")
}

func runBackfillChecks() throws -> Int {
    let checks: [(String, () throws -> Void)] = [
        ("Backfill decodes measured hourly deltas in the station timezone", {
            let page = try backfillPage([
                backfillSeries("pm25", [[0, 21], "jEHH"]),
                backfillSeries("o3", [[0, 64], -16, 16, "aa"], divisor: 10)
            ])
            let readings = try StationHistoryClient.parsePage(page, for: backfillReading(), now: backfillNow)
            try backfillRequire(readings.map(\.aqi) == [9, 17, 25, 30], "History must decode descending deltas, then sort ascending")
            try backfillRequire(readings.last?.observedAt == backfillAnchor.addingTimeInterval(-3600), "07:00 at station UTC−6 must be 13:00Z")
            try backfillRequire(readings.last?.stationID == 218 && readings.last?.stationTimeZone == backfillZone, "Station identity and zone must be retained")
            try backfillRequire(readings.allSatisfy { $0.fetched == backfillNow && $0.values["t"] == nil }, "Download time and absent historical weather must not be fabricated")
        }),
        ("Backfill preserves missing hours and requires all pollutant observations", {
            let page = try backfillPage([
                backfillSeries("pm25", [[0, 21], "j", [3, -5], "H"]),
                backfillSeries("o3", [[0, 20], "abc", [2, 4]])
            ])
            let rows = try StationHistoryClient.parsePage(page, for: backfillReading(), now: backfillNow)
            try backfillRequire(rows.map(\.aqi) == [27, 30], "Only common timestamps may combine; missing PM2.5 must not become low ozone-only AQI")
            try backfillRequire(rows.map { backfillAnchor.timeIntervalSince($0.observedAt!) } == [18000, 3600], "Encoded multi-hour spans must stay gaps")
        }),
        ("Backfill uses highest simultaneous pollutant and ignores forecasts/weather", {
            let page = try backfillPage([
                backfillSeries("pm25", [[0, 21], -16]),
                backfillSeries("o3", [[0, 264], 17], divisor: 10),
                backfillSeries("t", [[0, 99], 99])
            ])
            let rows = try StationHistoryClient.parsePage(page, for: backfillReading(), now: backfillNow)
            try backfillRequire(rows.map(\.aqi) == [28], "AQI must round the highest simultaneous pollutant subindex, not PM2.5 alone")
        }),
        ("Backfill bounds historical data without replacing the current observation", {
            let page = try backfillPage([
                backfillSeries("pm25", [[0, 20], "a", [21, 10], "b", [24, 4]], base: "2026/09/05 09:00:00")
            ])
            let rows = try StationHistoryClient.parsePage(page, for: backfillReading(values: ["pm25": 21]), now: backfillNow)
            try backfillRequire(rows.count == 1 && rows.first?.aqi == 30, "Exclude future-of-feed/current-anchor points and data older than the chart's past 24 hours")
            try backfillRequire(rows.first?.observedAt == backfillNow.addingTimeInterval(-86400), "Exact 24-hour boundary must remain eligible")
        }),
        ("Backfill rejects the wrong station and incomplete pollutant coverage", {
            let series = [backfillSeries("pm25", [[0, 21], "j"])]
            try backfillMustThrow { _ = try StationHistoryClient.parsePage(try backfillPage(series, station: 219), for: backfillReading(), now: backfillNow) }
            try backfillMustThrow { _ = try StationHistoryClient.parsePage(try backfillPage(series), for: backfillReading(), now: backfillNow) }
        }),
        ("Backfill requests stay anonymous and on the selected WAQI page", {
            let cleaned = try StationHistoryClient.pageURL(for: backfillReading(source: "https://aqicn.org/city/a/?token=never-send#details"))
            try backfillRequire(cleaned.absoluteString == "https://aqicn.org/city/a/", "Queries and fragments must not accompany history requests")
            for source in ["http://aqicn.org/city/a/", "https://aqicn.org.evil.example/city/a/", "https://user:password@aqicn.org/city/a/", "https://aqicn.org:8443/city/a/", "https://api.waqi.info/feed/@218/", "https://aqicn.org/data-platform/"] {
                try backfillMustThrow { _ = try StationHistoryClient.pageURL(for: backfillReading(source: source)) }
            }
        }),
        ("Backfill fails safely when public page data changes or becomes malformed", {
            for series in [
                backfillSeries("pm25", [[0, 21], "!"]),
                backfillSeries("pm25", [[0, 21], [-1, 2]]),
                backfillSeries("pm25", [[0, 21], [0, 2]]),
                backfillSeries("pm25", [[0, 21]], divisor: 0),
                backfillSeries("pm25", [[0, 21]], base: "2026/02/31 08:00:00"),
                backfillSeries("pm25", [true])
            ] {
                try backfillMustThrow { _ = try StationHistoryClient.parsePage(try backfillPage([series]), for: backfillReading(values: ["pm25": 21]), now: backfillNow) }
            }
            try backfillMustThrow { _ = try StationHistoryClient.parsePage(Data("<html>No station data</html>".utf8), for: backfillReading(), now: backfillNow) }
            try backfillMustThrow { _ = try StationHistoryClient.parsePage(Data(repeating: 0, count: StationHistoryClient.maximumPageBytes + 1), for: backfillReading(), now: backfillNow) }
        }),
        ("Recorded Austin public chart observations backfill without interpolation", {
            // Public station chart captured September 5, 2026, without a token.
            // https://aqicn.org/city/texas/austin/austin-northwest/
            let page = try backfillPage([
                backfillSeries("pm25", [[0, 21], "jEHHemL", [4, 25], "HET", 41, "en", -42]),
                backfillSeries("o3", [[0, 104], -40, "Pqaaqqq", [3, 96], "izxrpX", -31, -57], base: "2026/09/05 09:00:00", divisor: 10),
                backfillSeries("no2", [[0, 38], -8, -16, 3, 1, 0, 0, 19, [3, -8], 3, -11, -9, 0, -1, 7, 3, 8], divisor: 10),
                backfillSeries("so2", [[0, 2], [3, 0], 0, [6, 1], 0, 2, 0, 0, -3, 0], base: "2026/09/05 06:00:00", divisor: 10)
            ])
            let reading = backfillReading(values: ["pm25": 21, "o3": 10.4, "no2": 3.8, "so2": 0.2])
            let rows = try StationHistoryClient.parsePage(page, for: reading, now: backfillNow)
            try backfillRequire(rows.last?.stationTime == "2026/09/05 06:00:00" && rows.last?.aqi == 25, "Published 06:00 PM2.5=25 must win its simultaneous gas indices")
            try backfillRequire(rows.contains { $0.stationTime == "2026/09/04 15:00:00" && $0.aqi == 63 }, "Published previous-day station observations must backfill")
            try backfillRequire(!rows.contains { $0.stationTime == "2026/09/05 07:00:00" }, "A missing gas observation must not be forward-filled")
        })
    ]
    for (name, check) in checks { try check(); print("PASS: \(name)") }
    return checks.count
}
