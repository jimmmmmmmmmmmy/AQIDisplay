import Foundation
import OpenAirCore

func runMergeChecks() throws -> Int {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".db")
    defer { try? FileManager.default.removeItem(at: url) }
    let history = try ObservationHistory(url: url)
    let now = Date()
    let measured = now.addingTimeInterval(-3600)
    let zone = TimeZone(secondsFromGMT: 0)!
    let live = Reading(aqi: 60, city: "A", fetched: now, observedAt: measured, stationTimeZone: zone, stationID: 1)
    try history.store(live)
    let conflicting = Reading(aqi: 20, city: "A", fetched: now.addingTimeInterval(1), observedAt: measured, stationTimeZone: zone, stationID: 1)
    try history.storeBackfill(conflicting)
    let firstLive = try history.recent(stationID: 1, now: now).first?.aqi
    precondition(firstLive == 60, "Backfill must not replace a live observation")
    let earlier = Reading(aqi: 35, city: "A", fetched: now, observedAt: now.addingTimeInterval(-7200), stationTimeZone: zone, stationID: 1)
    try history.storeBackfill(earlier)
    try history.storeBackfill(earlier)
    let rows = try history.recent(stationID: 1, now: now)
    precondition(rows.map(\.aqi) == [35, 60], "Backfill should add one older observation and keep the live one")
    print("PASS: Backfill fills gaps without replacing live observations or duplicating points")
    let revisedLive = Reading(aqi: 40, city: "A", fetched: now.addingTimeInterval(5), observedAt: earlier.observedAt, stationTimeZone: zone, stationID: 1)
    try history.store(revisedLive)
    let corrected = try history.recent(stationID: 1, now: now).first?.aqi
    precondition(corrected == 40, "A live correction should replace a historical reconstruction")
    print("PASS: Live observations can correct a historical reconstruction")
    return 2
}
