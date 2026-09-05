import Foundation
import CSQLite
import OpenAirCore

private struct ObservationCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func observationRequire(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ObservationCheckFailure(description: message) }
}

private func withObservationDatabase(_ check: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "openair-observation-check-\(UUID().uuidString)")
    try Paths.prepare(directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try check(directory.appending(path: "aqi_data.db"))
}

private let observationCheckNow = Date(timeIntervalSince1970: 1_788_624_000)

private func observationFixture(station: Int? = 218, aqi: Int = 21, offset: TimeInterval = -3600,
                                fetchedOffset: TimeInterval = 0, city: String = "Same Name") -> Reading {
    Reading(aqi: aqi, city: city, values: ["t": 22],
            fetched: observationCheckNow.addingTimeInterval(fetchedOffset),
            observedAt: observationCheckNow.addingTimeInterval(offset), stationTimeZone: TimeZone(secondsFromGMT: -21600), stationID: station)
}

/// Returns the number of independent history regression checks completed.
func runObservationChecks() throws -> Int {
    let checks: [(String, (URL) throws -> Void)] = [
        ("Observation history uses measured time and survives reopening", { url in
            let observed = observationCheckNow.addingTimeInterval(-7200)
            do {
                let history = try ObservationHistory(url: url)
                try history.store(observationFixture(aqi: 30, offset: -3600))
                try history.store(observationFixture(aqi: 20, offset: -7200))
            }
            let reopened = try ObservationHistory(url: url)
            let points = try reopened.recent(stationID: 218, now: observationCheckNow)
            try observationRequire(points.map(\.aqi) == [20, 30], "Observed readings must remain sorted after reopening")
            try observationRequire(points.first?.date == observed, "Chart must use observation time, not download time")
            try observationRequire(points.first?.temperature == 22, "Observed weather must be retained")
        }),
        ("Repeated polls deduplicate and accept provider corrections", { url in
            let history = try ObservationHistory(url: url)
            try history.store(observationFixture(aqi: 21))
            try history.store(observationFixture(aqi: 21, fetchedOffset: 300))
            try history.store(observationFixture(aqi: 22, fetchedOffset: 600))
            try history.store(observationFixture(aqi: 19, fetchedOffset: -300))
            let points = try history.recent(stationID: 218, now: observationCheckNow)
            try observationRequire(points.map(\.aqi) == [22], "Repeated observations must produce one point with the latest correction")
            try observationRequire(points.first?.date == observationCheckNow.addingTimeInterval(-3600), "Repolling must not move the observation")
        }),
        ("Stations with matching names and timestamps remain separate", { url in
            let history = try ObservationHistory(url: url)
            try history.store(observationFixture(station: 218, aqi: 21))
            try history.store(observationFixture(station: 219, aqi: 99))
            try history.store(observationFixture(station: 218, aqi: 22, offset: -1800, city: "Renamed Station"))
            try observationRequire(try history.recent(stationID: 218, now: observationCheckNow).map(\.aqi) == [21, 22], "Station history must survive a name change")
            try observationRequire(try history.recent(stationID: 219, now: observationCheckNow).map(\.aqi) == [99], "A nearby station must not mix into history")
        }),
        ("Unverified and invalid observations do not become history", { url in
            let history = try ObservationHistory(url: url)
            try history.store(observationFixture(station: nil))
            try history.store(observationFixture(station: 0))
            try history.store(Reading(aqi: 21, city: "A", fetched: observationCheckNow, stationID: 218))
            try history.store(Reading(aqi: 21, city: "A", fetched: observationCheckNow, observedAt: observationCheckNow, stationID: 218))
            let malformed = try WAQIClient.parseFeed(Data(#"{"status":"ok","data":{"idx":218,"aqi":21,"city":{"name":"A"},"time":{"s":"not a date","tz":"-06:00"}}}"#.utf8))
            try history.store(malformed)
            try history.store(observationFixture(offset: 601))
            try observationRequire(try history.recent(stationID: 218, now: observationCheckNow.addingTimeInterval(1200)).isEmpty, "Unknown or implausibly future observations must be ignored")
        }),
        ("Past 24 hours uses observation boundaries and excludes future points", { url in
            let history = try ObservationHistory(url: url)
            try history.store(observationFixture(aqi: 10, offset: -86401))
            try history.store(observationFixture(aqi: 20, offset: -86400))
            try history.store(observationFixture(aqi: 30, offset: -14400))
            try history.store(observationFixture(aqi: 40, offset: 0))
            try history.store(observationFixture(aqi: 50, offset: 600))
            try observationRequire(try history.recent(stationID: 218, now: observationCheckNow).map(\.aqi) == [20, 30, 40], "Chart must include real stale readings in range and exclude future observations")
            try observationRequire(try history.recent(stationID: 218, now: observationCheckNow.addingTimeInterval(600)).map(\.aqi) == [30, 40, 50], "A tolerated clock-skew observation may appear only when its time arrives")
        }),
        ("Observation storage leaves every legacy row unchanged", { url in
            let legacy = try History(url: url)
            let old = Reading(aqi: 18, city: "Archived Station", values: ["t": 17], fetched: observationCheckNow.addingTimeInterval(-86400 * 500))
            let recent = Reading(aqi: 25, city: "Same Name", values: ["t": 19], fetched: observationCheckNow)
            try legacy.store(old)
            try legacy.store(recent)
            let history = try ObservationHistory(url: url)
            try history.store(observationFixture())
            var db: OpaquePointer?
            try observationRequire(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, "Legacy database must stay readable")
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            try observationRequire(sqlite3_prepare_v2(db, "SELECT timestamp, city, aqi, temperature FROM aqi_data ORDER BY timestamp", -1, &statement, nil) == SQLITE_OK, "Legacy schema must remain intact")
            defer { sqlite3_finalize(statement) }
            for reading in [old, recent] {
                try observationRequire(sqlite3_step(statement) == SQLITE_ROW, "Every legacy row must remain")
                try observationRequire(String(cString: sqlite3_column_text(statement, 0)) == History.format(reading.fetched), "Legacy timestamps must not be rewritten")
                try observationRequire(String(cString: sqlite3_column_text(statement, 1)) == reading.city, "Legacy city must not change")
                try observationRequire(Int(sqlite3_column_int64(statement, 2)) == reading.aqi, "Legacy AQI must not change")
                try observationRequire(sqlite3_column_double(statement, 3) == reading.values["t"], "Legacy weather must not change")
            }
            try observationRequire(sqlite3_step(statement) == SQLITE_DONE, "New observations must not be inserted as legacy poll records")
            try observationRequire(try history.recent(stationID: 218, now: observationCheckNow).count == 1, "Legacy polls must not masquerade as station observations")
        })
    ]
    for (name, check) in checks {
        try withObservationDatabase(check)
        print("PASS: \(name)")
    }
    return checks.count
}
