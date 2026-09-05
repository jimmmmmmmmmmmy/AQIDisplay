import Foundation
import CSQLite
import OpenAirCore

final class CoreTests {
    var teardown: [() throws -> Void] = []
    func addTeardownBlock(_ block: @escaping () throws -> Void) { teardown.append(block) }
    deinit { for block in teardown { try? block() } }
    func fixture(_ body: String) -> Data { Data(body.utf8) }
    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Paths.prepare(directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func testMissingAQIRejected() {
        for aqi in ["\"-\"", "null", "-1", "\"NaN\""] {
            XCTAssertThrowsError(try WAQIClient.parseFeed(fixture("{\"status\":\"ok\",\"data\":{\"aqi\":\(aqi),\"city\":{\"name\":\"A\"}}}")))
        }
    }
    func testMissingWeatherIsNotZero() throws {
        let reading = try WAQIClient.parseFeed(fixture(#"{"status":"ok","data":{"aqi":21,"city":{"name":"A"},"iaqi":{"t":{"v":"-"},"w":{"v":0}}}}"#))
        XCTAssertNil(reading.values["t"])
        XCTAssertEqual(reading.values["w"], 0)
    }
    func testTemperatureAndCategories() {
        XCTAssertEqual(Reading(aqi: 50, city: "A", values: ["t":20]).temperature(fahrenheit: true),68)
        XCTAssertEqual(Reading(aqi: 50, city: "A").category,"Good")
        XCTAssertEqual(Reading(aqi: 51, city: "A").category,"Moderate")
        XCTAssertEqual(Reading(aqi: 151, city: "A").category,"Unhealthy")
        XCTAssertEqual(Reading(aqi: 501, city: "A").category,"Hazardous")
    }
    func readingWithTime(_ time: [String: Any]) throws -> Reading {
        try WAQIClient.parseFeed(JSONSerialization.data(withJSONObject: [
            "status": "ok", "data": ["aqi": 21, "idx": 218, "city": ["name": "Austin"], "time": time]
        ]))
    }
    func observationDate(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
    func testObservationUsesExplicitISOOffsetAndKeepsFetchTime() throws {
        let beforeFetch = Date()
        let reading = try readingWithTime([
            "iso": "2026-09-05T08:00:00.125-06:00", "s": "2026-09-05 08:00:00", "tz": "-06:00", "v": 1788595200
        ])
        XCTAssertEqual(reading.observedAt, observationDate("2026-09-05T14:00:00Z").addingTimeInterval(0.125))
        XCTAssertEqual(reading.stationTimeZone?.secondsFromGMT(), -6 * 3600)
        XCTAssertEqual(reading.stationID, 218)
        XCTAssertTrue(reading.fetched >= beforeFetch && reading.fetched <= Date())
        // ISO's explicit offset wins over contradictory secondary fields.
        let conflicting = try readingWithTime(["iso": "2026-09-05T08:00:00-06:00", "s": "2026-09-04 08:00:00", "tz": "+02:00"])
        XCTAssertEqual(conflicting.observedAt, observationDate("2026-09-05T14:00:00Z"))
        XCTAssertEqual(conflicting.stationTimeZone?.secondsFromGMT(), -6 * 3600)
    }
    func testObservationFallsBackToWallTimeWithExplicitTimeZone() throws {
        let nepal = try readingWithTime(["iso": "invalid", "s": "2026-09-05 08:00:00", "tz": "+05:45"])
        XCTAssertEqual(nepal.observedAt, observationDate("2026-09-05T02:15:00Z"))
        let standard = try readingWithTime(["s": "2026-09-05 08:00:00", "tz": "-0600"])
        XCTAssertEqual(standard.observedAt, observationDate("2026-09-05T14:00:00Z"))
        let named = try readingWithTime(["s": "2026-09-05 08:00:00", "tz": "America/Chicago"])
        XCTAssertEqual(named.observedAt, observationDate("2026-09-05T13:00:00Z"))
        let utc = try readingWithTime(["iso": "2026-09-05T08:00:00Z"])
        XCTAssertEqual(utc.observedAt, observationDate("2026-09-05T08:00:00Z"))
    }
    func testMalformedObservationRemainsUnverified() throws {
        let invalid: [[String: Any]] = [
            [:], ["v": 1788595200], ["s": "2026-09-05 08:00:00"],
            ["s": "2026-09-05 08:00:00", "tz": "unknown"],
            ["s": "2026-09-05 08:00:00", "tz": "Bogus/Location"],
            ["s": "2026-09-05 08:00:00", "tz": "EST"],
            ["iso": "2026-09-05T08:00:00"], ["iso": "2026-02-30T08:00:00Z"],
            ["iso": "2026-09-05T24:00:00Z"], ["iso": "2026-09-05T08:00:00-00:00"],
            ["iso": "2026-09-05T08:00:00+15:00"], ["iso": "2026-09-05T08:00:00+14:15"],
            ["s": "2026-02-30 08:00:00", "tz": "+00:00"],
            ["s": "2026-03-08 02:30:00", "tz": "America/Chicago"]
        ]
        for time in invalid {
            let reading = try readingWithTime(time)
            XCTAssertNil(reading.observedAt)
            XCTAssertEqual(reading.freshness(), .unverified)
        }
    }
    func testFreshnessAgeAndFutureBoundaries() {
        let now = observationDate("2026-09-05T14:00:00Z")
        let cases: [(TimeInterval, ReadingFreshness)] = [(0, .current), (10800, .current), (10801, .stale), (-600, .current), (-601, .future)]
        for (age, expected) in cases {
            let reading = Reading(aqi: 21, city: "A", fetched: now,
                observedAt: now.addingTimeInterval(-age), stationTimeZone: TimeZone(secondsFromGMT: 0))
            XCTAssertEqual(reading.freshness(at: now), expected)
            XCTAssertEqual(reading.freshness(at: now).isCurrent, expected == .current)
        }
        XCTAssertEqual(Reading(aqi: 21, city: "A", fetched: now).freshness(at: now), .unverified)
        XCTAssertEqual(Reading(aqi: 21, city: "A", observedAt: now).freshness(at: now), .unverified)
    }
    func testFreshnessUsesStationCalendarDay() {
        let now = observationDate("2026-09-05T00:30:00Z")
        // Crossing UTC midnight is still the same local day in Texas.
        let sameLocalDay = Reading(aqi: 21, city: "A",
            observedAt: now.addingTimeInterval(-3600), stationTimeZone: TimeZone(secondsFromGMT: -6 * 3600))
        XCTAssertEqual(sameLocalDay.freshness(at: now), .current)
        // A one-hour-old UTC observation crossed the station's local midnight.
        let previousDay = Reading(aqi: 21, city: "A",
            observedAt: now.addingTimeInterval(-3600), stationTimeZone: TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(previousDay.freshness(at: now), .differentDay)
        let previousYear = Reading(aqi: 21, city: "A", fetched: now,
            observedAt: observationDate("2025-09-05T00:00:00Z"), stationTimeZone: TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(previousYear.freshness(at: now), .differentDay)
        let invalidFuture = Reading(aqi: 21, city: "A",
            observedAt: now.addingTimeInterval(86400), stationTimeZone: TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(invalidFuture.freshness(at: now), .future)
    }
    func testMalformedAndErrorResponsesAreSafe() {
        for text in ["bad", "[]", #"{"status":"error","data":"token=secret"}"#, #"{"status":"ok","data":null}"#] {
            XCTAssertThrowsError(try WAQIClient.parseFeed(fixture(text))) { error in
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
    }
    func testSearchDeduplicatesAndHandlesUnavailableAQI() throws {
        let result = try WAQIClient.parseSearch(fixture(#"{"status":"ok","data":[{}, {"uid":1,"station":{"name":"A"},"aqi":"-"},{"uid":1,"station":{"name":"A"}}]}"#))
        XCTAssertEqual(result.count,1)
        XCTAssertNil(result[0].aqi)
    }
    func testURLCorrectlyEncodesSearchAndToken() throws {
        let url = try WAQIClient(token:"a&b").url(path:"/search/",keyword:"New York & Queens")
        let components = try XCTUnwrap(URLComponents(url:url,resolvingAgainstBaseURL:false))
        XCTAssertEqual(components.queryItems?.first(where:{$0.name == "token"})?.value,"a&b")
        XCTAssertEqual(components.queryItems?.first(where:{$0.name == "keyword"})?.value,"New York & Queens")
        XCTAssertThrowsError(try WAQIClient(token:"").url(path:"/feed/here/"))
    }
    func testTokenIsPrivateAndReplaceable() throws {
        let directory = try temporaryDirectory()
        try Paths.saveToken(" first ",in:directory)
        try Paths.saveToken("second",in:directory)
        let url = directory.appending(path:"waqi-token")
        XCTAssertEqual(try String(contentsOf:url,encoding:.utf8),"second")
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
    func testPreferencesRetainUnknownSettings() throws {
        let directory = try temporaryDirectory()
        let url = directory.appending(path:"settings.json")
        try fixture(#"{"future_setting":true}"#).write(to:url)
        var preferences = Preferences()
        preferences.city = "@123"; preferences.temperatureUnit = "°C"
        try preferences.save(to:directory)
        XCTAssertEqual(Preferences.load(from:directory),preferences)
        let raw = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]
        XCTAssertEqual(raw?["future_setting"] as? Bool,true)
    }
    func testHistoryKeepsAllRowsAndSeparatesCities() throws {
        let directory = try temporaryDirectory()
        let url = directory.appending(path:"aqi_data.db")
        let history = try History(url:url)
        let now = Date()
        try history.store(Reading(aqi:10,city:"Old",fetched:now.addingTimeInterval(-86400*500)))
        try history.store(Reading(aqi:20,city:"A",fetched:now))
        try history.store(Reading(aqi:30,city:"B",fetched:now))
        try history.store(Reading(aqi:40,city:"A",fetched:now))
        XCTAssertEqual(try history.recent(city:"A",now:now).map(\.aqi),[40])
        XCTAssertEqual(try history.recent(city:"B",now:now).map(\.aqi),[30])
        XCTAssertNil(try history.recent(city:"A",now:now).first?.temperature)
        var db: OpaquePointer?; var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path,&db),SQLITE_OK)
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_prepare_v2(db,"SELECT COUNT(*) FROM aqi_data",-1,&statement,nil),SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement),SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement,0),4)
    }
    func testLegacyPythonTimestampParses() {
        XCTAssertNotNil(History.parse("2025-03-26T14:20:21.123456"))
        XCTAssertNotNil(History.parse("2025-03-26T14:20:21"))
    }
    func testSingleInstanceLoserDoesNotReleaseOwner() throws {
        let directory = try temporaryDirectory()
        let first = InstanceLock()
        XCTAssertTrue(try first.acquire(in:directory))
        do { let second = InstanceLock(); XCTAssertFalse(try second.acquire(in:directory)) }
        let third = InstanceLock()
        XCTAssertFalse(try third.acquire(in:directory))
        withExtendedLifetime(first) {}
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let status = url.path.contains("failure") ? 503 : 200
        let body = Data(#"{"status":"ok","data":{"aqi":25,"city":{"name":"Fixture Station"}}}"#.utf8)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class NetworkTests {
    func testAsyncFeedAndSafeHTTPFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration:configuration)
        defer { session.invalidateAndCancel() }
        let client = WAQIClient(token:"secret",session:session)
        let reading = try await client.feed("@123")
        XCTAssertEqual(reading.aqi,25)
        do { _ = try await client.feed("failure"); XCTFail("Expected HTTP failure") }
        catch { XCTAssertEqual(error.localizedDescription,AirError.connection.localizedDescription); XCTAssertFalse(error.localizedDescription.contains("secret")) }
    }
}

private func XCTAssertTrue(_ value: Bool) { precondition(value) }
private func XCTAssertFalse(_ value: Bool) { precondition(!value) }
private func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
private func XCTAssertNotNil<T>(_ value: T?) { precondition(value != nil) }
private func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b, "Expected equal values") }
private func XCTFail(_ message: String) { fatalError(message) }
private func XCTUnwrap<T>(_ value: T?) throws -> T { guard let value else { throw AirError.storage }; return value }
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ handler: (Error) -> Void = { _ in }) {
    do { _ = try expression(); fatalError("Expected an error") } catch { handler(error) }
}

@main struct Checks {
    @MainActor static func main() async throws {
        let tests = CoreTests()
        let cases: [(String, () throws -> Void)] = [
            ("Missing AQI", tests.testMissingAQIRejected),
            ("Missing weather", tests.testMissingWeatherIsNotZero),
            ("Temperature and AQI categories", tests.testTemperatureAndCategories),
            ("Observation ISO offset and fetch time", tests.testObservationUsesExplicitISOOffsetAndKeepsFetchTime),
            ("Observation wall time and timezone", tests.testObservationFallsBackToWallTimeWithExplicitTimeZone),
            ("Malformed observation times", tests.testMalformedObservationRemainsUnverified),
            ("Freshness age and future boundaries", tests.testFreshnessAgeAndFutureBoundaries),
            ("Freshness station calendar day", tests.testFreshnessUsesStationCalendarDay),
            ("Safe response errors", tests.testMalformedAndErrorResponsesAreSafe),
            ("Station search validation", tests.testSearchDeduplicatesAndHandlesUnavailableAQI),
            ("URL encoding and missing token", tests.testURLCorrectlyEncodesSearchAndToken),
            ("Private token replacement", tests.testTokenIsPrivateAndReplaceable),
            ("Preferences preservation", tests.testPreferencesRetainUnknownSettings),
            ("History retention and city separation", tests.testHistoryKeepsAllRowsAndSeparatesCities),
            ("Legacy timestamps", tests.testLegacyPythonTimestampParses),
            ("Instance lock ownership", tests.testSingleInstanceLoserDoesNotReleaseOwner)
        ]
        for (name, test) in cases { try test(); print("PASS: \(name)") }
        try await NetworkTests().testAsyncFeedAndSafeHTTPFailure()
        print("PASS: Async feed and HTTP errors")
        if CommandLine.arguments.contains("--live") {
            let client = WAQIClient()
            let reading = try await client.feed(Preferences.load().city)
            let stations = try await client.search("New York")
            print("PASS: Live feed (AQI \(reading.aqi)) and search (\(stations.count) stations)")
            let earlier = try await StationHistoryClient().fetch(for: reading)
            precondition(earlier.allSatisfy { $0.stationID == reading.stationID && $0.observedAt! < reading.observedAt! })
            print("PASS: Live station backfill (\(earlier.count) earlier observations)")
        }
        let observationChecks = try runObservationChecks()
        let mergeChecks = try runMergeChecks()
        let backfillChecks = try runBackfillChecks()
        print("\(cases.count + 1 + observationChecks + mergeChecks + backfillChecks) native checks passed")
    }
}
