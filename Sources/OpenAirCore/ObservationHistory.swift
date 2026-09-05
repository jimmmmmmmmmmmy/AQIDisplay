import Foundation
import CSQLite

/// Observation time is separate from download time. The legacy `aqi_data` table
/// contains download timestamps and is deliberately left intact.
public final class ObservationHistory {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            throw AirError.storage
        }
        sqlite3_busy_timeout(db, 2000)
        let schema = """
        CREATE TABLE IF NOT EXISTS station_observations (
            station_id INTEGER NOT NULL,
            observed_at REAL NOT NULL,
            city TEXT NOT NULL,
            aqi INTEGER NOT NULL,
            temperature REAL,
            station_time_zone TEXT NOT NULL,
            fetched_at REAL NOT NULL,
            PRIMARY KEY (station_id, observed_at)
        )
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            throw AirError.storage
        }
    }

    deinit { sqlite3_close(db) }

    public func store(_ reading: Reading) throws {
        try save(reading, allowCorrections: true)
    }

    /// Historical chart samples fill gaps; they never replace a live observation.
    public func storeBackfill(_ reading: Reading) throws {
        try save(reading, allowCorrections: false)
    }

    private func save(_ reading: Reading, allowCorrections: Bool) throws {
        guard let stationID = reading.stationID, stationID > 0,
              let observedAt = reading.observedAt,
              let timeZone = reading.stationTimeZone,
              observedAt.timeIntervalSince1970.isFinite,
              reading.fetched.timeIntervalSince1970.isFinite,
              observedAt <= reading.fetched.addingTimeInterval(600),
              reading.aqi >= 0 else { return }

        let conflict = allowCorrections ? """
        ON CONFLICT(station_id, observed_at) DO UPDATE SET
            city = excluded.city,
            aqi = excluded.aqi,
            temperature = excluded.temperature,
            station_time_zone = excluded.station_time_zone,
            fetched_at = excluded.fetched_at
        WHERE excluded.fetched_at >= station_observations.fetched_at
        """ : "ON CONFLICT(station_id, observed_at) DO NOTHING"
        let query = """
        INSERT INTO station_observations
            (station_id, observed_at, city, aqi, temperature, station_time_zone, fetched_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        \(conflict)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw AirError.storage }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(stationID))
        sqlite3_bind_double(statement, 2, observedAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, reading.city, -1, transient)
        sqlite3_bind_int64(statement, 4, Int64(reading.aqi))
        if let temperature = reading.values["t"], temperature.isFinite { sqlite3_bind_double(statement, 5, temperature) }
        else { sqlite3_bind_null(statement, 5) }
        sqlite3_bind_text(statement, 6, timeZone.identifier, -1, transient)
        sqlite3_bind_double(statement, 7, reading.fetched.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AirError.storage }
    }

    public func recent(stationID: Int, now: Date = Date()) throws -> [HistoryPoint] {
        guard stationID > 0, now.timeIntervalSince1970.isFinite else { return [] }
        let query = """
        SELECT observed_at, aqi, temperature FROM station_observations
        WHERE station_id = ? AND observed_at >= ? AND observed_at <= ?
        ORDER BY observed_at ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw AirError.storage }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(stationID))
        sqlite3_bind_double(statement, 2, now.addingTimeInterval(-86400).timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var rows: [HistoryPoint] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            rows.append(HistoryPoint(timestamp: formatter.string(from: date), date: date,
                                     aqi: Int(sqlite3_column_int64(statement, 1)),
                                     temperature: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw AirError.storage }
        return rows
    }
}
