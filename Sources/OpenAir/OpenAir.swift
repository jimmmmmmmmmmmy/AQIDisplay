import AppKit
import SwiftUI
import OpenAirCore

@MainActor
final class AirModel: ObservableObject {
    static let shared = AirModel()
    @Published var reading: Reading?
    @Published var points: [HistoryPoint] = []
    @Published var preferences = Preferences.load()
    @Published var refreshing = false
    @Published var error: String?
    @Published var historyWarning: String?
    @Published var backfilling = false
    @Published var backfillMessage: String?
    @Published var hasToken = !Paths.token().isEmpty
    @Published var loginEnabled = LoginItem.isEnabled
    @Published var settingsError: String?
    private var history: ObservationHistory?
    @Published var now = Date()
    private var ageTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var generation = UUID()
    private var instance = InstanceLock()
    init(preview: Bool = false) {
        if preview {
            hasToken = true
            let latest = Calendar.current.dateInterval(of: .hour, for: now.addingTimeInterval(-3600))!.start
            reading = Reading(aqi: 42, city: "New York", stationTime: "Today, 11:00 AM", providers: ["Station provider"],
                values: ["t": 22, "h": 58, "w": 2.4, "p": 1016, "pm25": 42, "pm10": 18, "o3": 12], observedAt: latest, stationTimeZone: .current, stationID: 1)
            points = (0..<24).map { index in
                let date = latest.addingTimeInterval(Double(index - 23) * 3600)
                return HistoryPoint(timestamp: String(index), date: date, aqi: index == 23 ? 42 : 30 + Int(12 * sin(Double(index) / 3)) + index / 2, temperature: 22)
            }
            return
        }
        do {
            guard try instance.acquire() else { NSApplication.shared.terminate(nil); return }
            history = try ObservationHistory(url: Paths.directory.appending(path: "aqi_data.db"))
        } catch { self.historyWarning = AirError.storage.localizedDescription }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in AirModel.shared.refresh() }
        }
        ageTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in AirModel.shared.now = Date() }
        }
        refresh()
    }
    var freshness: ReadingFreshness { reading?.freshness(at: now) ?? .unverified }
    var dataIsCurrent: Bool { freshness.isCurrent && error == nil }
    var freshnessMessage: String {
        switch freshness {
        case .current: return "Current · " + observationAge
        case .stale: return "Older reading · " + observationAge
        case .differentDay: return "Not from today · " + observationAge
        case .future: return "Station timestamp is in the future"
        case .unverified: return "Station timestamp could not be verified"
        }
    }
    var observationAge: String {
        guard let date = reading?.observedAt else { return "Time unknown" }
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) hr \(minutes % 60) min ago"
    }
    var accessibilitySummary: String {
        guard let reading else { return "OpenAir, " + menuTitle }
        return "OpenAir, air quality \(reading.aqi), \(reading.category), \(freshnessMessage), \(menuTitle)"
    }
    var menuDotColor: NSColor {
        guard dataIsCurrent, let reading else { return .secondaryLabelColor }
        switch reading.aqi {
        case ...50: return .systemGreen
        case ...100: return .systemYellow
        case ...150: return .systemOrange
        case ...200: return .systemRed
        default: return .systemPurple
        }
    }
    var fahrenheit: Bool { preferences.temperatureUnit == "°F" }
    var menuTitle: String {
        guard let reading else { return hasToken ? (refreshing ? "Loading…" : "Unavailable") : "Set Up" }
        var parts: [String] = []
        if preferences.formatOptions["City"] == true { parts.append(reading.city.shortened(to: 16)) }
        if preferences.formatOptions["AQI"] == true { parts.append("\(reading.aqi)") }
        if preferences.formatOptions["Temperature"] == true, let t = reading.temperature(fahrenheit: fahrenheit) { parts.append("\(Int(t.rounded()))°") }
        if preferences.formatOptions["Humidity"] == true, let h = reading.values["h"] { parts.append("\(Int(h.rounded()))%") }
        let title = parts.isEmpty ? "OpenAir" : parts.joined(separator: " · ")
        let suffix: String
        if error != nil { suffix = " · Offline" }
        else {
            switch freshness {
            case .current: suffix = ""
            case .stale, .differentDay: suffix = " · Old"
            case .future, .unverified: suffix = " · Unverified"
            }
        }
        return title.shortened(to: 36) + suffix
    }
    func refresh() {
        guard !refreshing else { return }
        hasToken = !Paths.token().isEmpty
        now = Date()
        backfillMessage = nil
        refreshing = true
        let current = generation
        let city = preferences.city
        refreshTask = Task {
            do {
                let result = try await WAQIClient().feed(city)
                guard current == generation, !Task.isCancelled else { return }
                if reading?.stationID != result.stationID { points = [] }
                reading = result
                now = Date()
                error = nil
                do {
                    try history?.store(result)
                    points = try result.stationID.flatMap { try history?.recent(stationID: $0) } ?? []
                    if history != nil { historyWarning = nil }
                } catch { self.historyWarning = AirError.storage.localizedDescription }
                if history != nil {
                    backfilling = true
                    do {
                        let earlier = try await StationHistoryClient().fetch(for: result)
                        guard current == generation, !Task.isCancelled else { return }
                        for sample in earlier {
                            if let observed = sample.observedAt, let latest = result.observedAt, observed < latest {
                                try history?.storeBackfill(sample)
                            }
                        }
                        points = try result.stationID.flatMap { try history?.recent(stationID: $0) } ?? []
                        backfillMessage = earlier.isEmpty ? "No earlier complete observations are available." : nil
                    } catch is CancellationError { return }
                    catch {
                        guard current == generation, !Task.isCancelled else { return }
                        backfillMessage = "Earlier history is unavailable. Showing saved readings."
                    }
                    if current == generation { backfilling = false }
                }
            } catch is CancellationError { return }
            catch {
                guard current == generation, !Task.isCancelled else { return }
                self.error = (error as? AirError)?.localizedDescription ?? AirError.connection.localizedDescription
            }
            if current == generation { refreshing = false }
        }
    }
    func select(_ station: Station?) {
        refreshTask?.cancel()
        generation = UUID()
        refreshing = false
        backfilling = false
        backfillMessage = nil
        reading = nil
        points = (try? station.flatMap { try history?.recent(stationID: $0.id) }) ?? []
        error = nil
        preferences.city = station.map { "@\($0.id)" } ?? "here"
        savePreferences()
        refresh()
    }
    func savePreferences() {
        do { try preferences.save(); settingsError = nil }
        catch { settingsError = "Unable to save settings." }
    }
    func saveKey(_ value: String) {
        do {
            try Paths.saveToken(value)
            hasToken = !Paths.token().isEmpty
            settingsError = nil
            refreshTask?.cancel(); generation = UUID(); refreshing = false; backfilling = false
            refresh()
        }
        catch { settingsError = "Unable to save the API key." }
    }
    func setLogin(_ enabled: Bool) {
        do { try LoginItem.setEnabled(enabled); loginEnabled = LoginItem.isEnabled; settingsError = nil }
        catch { loginEnabled = LoginItem.isEnabled; settingsError = "Unable to change login settings." }
    }
}

extension String {
    func shortened(to count: Int) -> String { self.count > count ? String(prefix(count - 1)) + "…" : self }
}

@MainActor
enum LoginItem {
    static let label = "com.user.openair"
    static var domain: String { "gui/\(getuid())" }
    static var service: String { "\(domain)/\(label)" }
    static func run(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }
    static var isEnabled: Bool { (try? run(["print", service])) == 0 }
    static func setEnabled(_ enabled: Bool) throws {
        if !enabled {
            guard try run(["disable", service]) == 0 else { throw AirError.storage }
            if isEnabled { guard try run(["bootout", service]) == 0 else { throw AirError.storage } }
            return
        }
        guard let executable = Bundle.main.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else { throw AirError.storage }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plist = directory.appending(path: "\(label).plist")
        if FileManager.default.fileExists(atPath: plist.path) {
            try FileManager.default.copyItem(at: plist, to: directory.appending(path: "\(label).plist.backup-\(UUID().uuidString)"))
        }
        let configuration: [String: Any] = ["Label": label, "ProgramArguments": [executable.path, "--background"], "RunAtLoad": true, "KeepAlive": false, "ProcessType": "Interactive"]
        let data = try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0)
        if isEnabled { guard try run(["bootout", service]) == 0 else { throw AirError.storage } }
        try data.write(to: plist, options: .atomic)
        guard try run(["enable", service]) == 0, try run(["bootstrap", domain, plist.path]) == 0 else { throw AirError.storage }
    }
}

struct OpenAirUI: App {
    @StateObject private var model = AirModel.shared
    var body: some Scene {
        MenuBarExtra {
            AirMenu(model: model)
        } label: {
            QualityMenuLabel(color: model.menuDotColor, title: model.menuTitle)
                .accessibilityLabel(model.accessibilitySummary)
        }
        .menuBarExtraStyle(.window)
        Window("Air Quality", id: "details") {
            DetailView(model: model)
        }
        .defaultLaunchBehavior(CommandLine.arguments.contains("--background") ? .suppressed : .presented)
        .defaultSize(width: 600, height: 740)
        .windowResizability(.contentMinSize)
        Window("Locations", id: "locations") {
            LocationView(model: model)
        }
        .defaultSize(width: 540, height: 520)
        .windowResizability(.contentMinSize)
        Settings { SettingsView(model: model) }
    }
}

@main
struct Entry {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.count > index + 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            do { try renderPreviews(to: directory) } catch { print("Preview rendering failed"); exit(1) }
            return
        }
        OpenAirUI.main()
    }
}
