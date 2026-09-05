import AppKit
import SwiftUI
import Charts
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
            reading = Reading(aqi: 42, city: "New York", stationTime: "Today, 11:00 AM", providers: ["Station provider"],
                values: ["t": 22, "h": 58, "w": 2.4, "p": 1016, "pm25": 42, "pm10": 18, "o3": 12], observedAt: Date().addingTimeInterval(-3600), stationTimeZone: .current, stationID: 1)
            points = (0..<24).map { index in
                let date = Date().addingTimeInterval(Double(index - 23) * 3600)
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
        .menuBarExtraStyle(.menu)
        Window("Air Quality", id: "details") {
            DetailView(model: model)
        }
        .defaultLaunchBehavior(CommandLine.arguments.contains("--background") ? .suppressed : .presented)
        .defaultSize(width: 560, height: 600)
        .windowResizability(.contentMinSize)
        Window("Locations", id: "locations") {
            LocationView(model: model)
        }
        .defaultSize(width: 520, height: 430)
        .windowResizability(.contentMinSize)
        Settings { SettingsView(model: model) }
    }
}

struct AirMenu: View {
    @ObservedObject var model: AirModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if let reading = model.reading {
            Text(reading.city.shortened(to: 48))
            Text("\(reading.aqi) AQI · \(reading.category)")
            Text(model.freshnessMessage)
        } else { Text(model.hasToken ? "Air Quality Unavailable" : "Welcome to OpenAir") }
        if model.error != nil { Text(model.hasToken ? "Unable to Update" : "Add an API key in Settings") }
        Divider()
        Button("Air Quality", systemImage: "chart.xyaxis.line") { show("details") }
        Button("Locations…", systemImage: "magnifyingglass") { show("locations") }
        Button(model.refreshing ? "Updating…" : "Refresh", systemImage: "arrow.clockwise") { model.refresh() }
            .disabled(model.refreshing).keyboardShortcut("r")
        Divider()
        SettingsLink { Label("Settings…", systemImage: "gearshape") }.keyboardShortcut(",")
        Divider()
        Button("Quit OpenAir") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
    private func show(_ id: String) { openWindow(id: id); NSApplication.shared.activate(ignoringOtherApps: true) }
}

struct DetailView: View {
    @ObservedObject var model: AirModel
    var preview = false
    @State private var showSources = false
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Group {
            if let reading = model.reading {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(reading.city).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(reading.city)
                        HStack(alignment: .center, spacing: 12) {
                            Circle().fill(model.dataIsCurrent ? aqiColor(reading.aqi) : .secondary)
                                .frame(width: 8, height: 8).accessibilityHidden(true)
                            Text(reading.aqi, format: .number)
                                .font(.system(size: 42, weight: .medium, design: .rounded)).monospacedDigit()
                            VStack(alignment: .leading, spacing: 3) {
                                Text(reading.category).font(.headline).lineLimit(2)
                                Text(model.freshnessMessage).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        if let error = model.error ?? model.historyWarning {
                            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true).help(error)
                        }
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            chart(reading)
                            Text(model.backfilling ? "Loading earlier readings…" : (model.backfillMessage ?? "Station observations · History fills in automatically"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.top, 4)
                    } label: { Text("Past 24 Hours").font(.headline) }
                    pollutants(reading)
                    GroupBox {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                            GridRow { metric("Temperature", symbol: "thermometer.medium", value: temperature(reading)); metric("Humidity", symbol: "humidity", value: value(reading,"h",suffix:"%")) }
                            Divider()
                            GridRow { metric("Wind", symbol: "wind", value: value(reading,"w",suffix:" m/s")); metric("Pressure", symbol: "barometer", value: value(reading,"p",suffix:" hPa")) }
                        }.padding(4)
                    } label: { Text("Weather").font(.headline) }
                    HStack {
                        Text("Checked \(reading.fetched.formatted(date: .omitted, time: .shortened)) · Refreshes every 5 minutes")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Data Sources", systemImage: "info.circle") { showSources.toggle() }
                            .popover(isPresented: $showSources) { sources(reading) }
                    }.controlSize(.small)
                    Spacer(minLength: 0)
                }.padding(20)
            } else {
                ContentUnavailableView {
                    Label(model.hasToken ? "No Air Quality Data" : "Set Up OpenAir", systemImage: "aqi.medium")
                } description: {
                    Text(model.error ?? "Your latest reading will appear here.")
                } actions: {
                    if model.hasToken { Button("Try Again") { model.refresh() }.disabled(model.refreshing) }
                    else { SettingsLink { Text("Open Settings") } }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 580)
        .toolbar {
            ToolbarItemGroup {
                Button("Locations", systemImage: "magnifyingglass") { openWindow(id: "locations") }.help("Find a location")
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }.disabled(model.refreshing).help("Refresh air quality")
            }
        }
    }
    private func chart(_ reading: Reading) -> some View {
        Chart {
            ForEach(Array(model.points.enumerated()), id: \.element.id) { index, point in
                let segment = segmentIndex(at: index)
                LineMark(x: .value("Time", point.date), y: .value("Air quality", point.aqi), series: .value("Segment", segment))
                    .foregroundStyle(aqiColor(point.aqi)).lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Time", point.date), y: .value("Air quality", point.aqi))
                    .foregroundStyle(aqiColor(point.aqi)).symbolSize(24)
            }
        }
        .chartXScale(domain: model.now.addingTimeInterval(-86400)...model.now)
        .chartYScale(domain: 0...max(50, (model.points.map(\.aqi).max() ?? 50) + 10))
        .chartXAxis { AxisMarks(values: chartTicks) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
        .frame(minHeight: 110, idealHeight: 135, maxHeight: 135)
        .overlay { if model.points.isEmpty { Text("No saved observations").font(.callout).foregroundStyle(.secondary) } }
        .accessibilityLabel("Actual station observations over the past 24 hours; missing hours are not estimated")
    }
    private var chartTicks: [Date] {
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: model.now)
        return (-4...4).compactMap { calendar.date(byAdding: .hour, value: $0 * 6, to: anchor) }
            .filter { $0 > model.now.addingTimeInterval(-86400 + 5400) && $0 < model.now.addingTimeInterval(-5400) }
    }
    private func segmentIndex(at index: Int) -> Int {
        guard index > 0 else { return 0 }
        return (1...index).filter { model.points[$0].date.timeIntervalSince(model.points[$0 - 1].date) > 3 * 3600 }.count
    }
    private func pollutants(_ reading: Reading) -> some View {
        GroupBox {
            HStack(spacing: 8) {
                ForEach(Array(zip(["PM₂.₅", "PM₁₀", "O₃", "NO₂", "SO₂", "CO"], ["pm25", "pm10", "o3", "no2", "so2", "co"])), id: \.0) { label, key in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                        Text(value(reading, key, suffix: "")).font(.body.weight(.medium)).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(pollutantName(key))
                    .accessibilityValue(reading.values[key] == nil ? "Unavailable" : value(reading, key, suffix: " AQI"))
                }
            }.padding(4)
        } label: {
            HStack {
                Text("Pollutants").font(.headline)
                Spacer()
                Text("US AQI").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func pollutantName(_ key: String) -> String {
        switch key {
        case "pm25": "Fine particulate matter, PM 2.5"
        case "pm10": "Particulate matter, PM 10"
        case "o3": "Ozone"
        case "no2": "Nitrogen dioxide"
        case "so2": "Sulfur dioxide"
        default: "Carbon monoxide"
        }
    }
    private func sources(_ reading: Reading) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Link("World Air Quality Index", destination: reading.sourceURL ?? URL(string: "https://aqicn.org/")!)
            Text(reading.providers.joined(separator: " · ")).font(.callout)
            Text("Station time: \(reading.stationTime)").font(.caption).textSelection(.enabled)
            Text("Current means observed today at the station, within 3 hours. Older or unverified readings have a neutral indicator.").font(.caption).foregroundStyle(.secondary)
            Text("Each refresh checks this station’s WAQI chart for earlier hourly readings. Historical air quality is the maximum of its reported pollutant indices, only at hours where all reported series are present. Missing hours stay empty.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 320)
    }
    private func temperature(_ reading: Reading) -> String { reading.temperature(fahrenheit: model.fahrenheit).map { "\(Int($0.rounded()))\(model.preferences.temperatureUnit)" } ?? "—" }
    private func value(_ reading: Reading, _ key: String, suffix: String) -> String { reading.values[key].map { $0.formatted(.number.precision(.fractionLength(0...1))) + suffix } ?? "—" }
    private func metric(_ name: String, symbol: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).foregroundStyle(.secondary).font(.caption)
                Text(value).font(.body.weight(.medium)).monospacedDigit()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func aqiColor(_ aqi: Int) -> Color {
    switch aqi { case ...50: .green; case ...100: .yellow; case ...150: .orange; case ...200: .red; default: .purple }
}

struct LocationView: View {
    @ObservedObject var model: AirModel
    @State private var query = ""
    @State private var stations: [Station] = []
    @State private var selection: Int?
    @State private var searching = false
    @State private var searched = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var generation = UUID()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            if searching { ProgressView().controlSize(.small).padding() }
            if let error { ContentUnavailableView("Search Unavailable", systemImage: "wifi.exclamationmark", description: Text(error)) }
            else if stations.isEmpty && !searching {
                ContentUnavailableView(searched ? "No Locations Found" : "Find a Location", systemImage: "magnifyingglass", description: Text(searched ? "Try another city or station name." : "Search for a city or air quality station."))
            } else {
                List(stations, selection: $selection) { station in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(station.name).lineLimit(2)
                            if model.preferences.city == "@\(station.id)" { Text("Current Location").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 16)
                        Text(station.aqi.map { "\($0) AQI" } ?? "—").foregroundStyle(.secondary).monospacedDigit()
                    }.padding(.vertical, 4).tag(station.id)
                }.listStyle(.inset)
            }
        }
        .frame(minWidth: 440, minHeight: 300)
        .searchable(text: $query, placement: .toolbar, prompt: "City or station")
        .onSubmit(of: .search) { search() }
        .onChange(of: query) { _, _ in search(debounce: true) }
        .onDisappear { searchTask?.cancel() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Automatic Location", systemImage: "location") { model.select(nil); dismiss() }
                    .help("Find a nearby station using your internet connection")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Use Location") {
                    if let station = stations.first(where: { $0.id == selection }) { model.select(station); dismiss() }
                }.disabled(selection == nil).keyboardShortcut(.defaultAction)
            }
        }
    }
    private func search(debounce: Bool = false) {
        searchTask?.cancel()
        let current = UUID(); generation = current
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        selection = nil; error = nil; searched = false; stations = []
        guard !text.isEmpty else { searching = false; return }
        searching = true
        searchTask = Task {
            do {
                if debounce { try await Task.sleep(for: .milliseconds(350)) }
                let results = try await WAQIClient().search(text)
                guard generation == current, !Task.isCancelled else { return }
                stations = results; searched = true
            } catch is CancellationError { return }
            catch {
                guard generation == current, !Task.isCancelled else { return }
                self.error = (error as? AirError)?.localizedDescription ?? AirError.connection.localizedDescription
            }
            if generation == current { searching = false }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AirModel
    @State private var apiKey = ""
    var body: some View {
        Form {
            Section("Menu Bar") {
                Toggle("Air quality", isOn: option("AQI"))
                Toggle("Temperature", isOn: option("Temperature"))
                Toggle("Humidity", isOn: option("Humidity"))
                Toggle("Location name", isOn: option("City"))
                Picker("Temperature", selection: $model.preferences.temperatureUnit) {
                    Text("Fahrenheit (°F)").tag("°F")
                    Text("Celsius (°C)").tag("°C")
                }
            }
            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                Text("Updates automatically every 5 minutes.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                SecureField(model.hasToken ? "Replace API key" : "API key", text: $apiKey)
                HStack {
                    Link("Get a WAQI API Key", destination: URL(string: "https://aqicn.org/data-platform/token/")!)
                    Spacer()
                    Button("Save") { model.saveKey(apiKey); apiKey = "" }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text(model.hasToken ? "Your API key is saved on this Mac." : "An API key is required to get air quality data.").font(.caption).foregroundStyle(.secondary)
            } header: { Text("Air Quality Data") }
            if let error = model.settingsError { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: model.preferences) { _, _ in model.savePreferences() }
    }
    private func option(_ key: String) -> Binding<Bool> { Binding(get: { model.preferences.formatOptions[key] ?? false }, set: { model.preferences.formatOptions[key] = $0 }) }
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


@MainActor
private func renderPreviews(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = AirModel(preview: true)
    for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark), ("compact-stale", ColorScheme.light)] {
        let width: CGFloat = name == "compact-stale" ? 520 : 560
        let height: CGFloat = name == "compact-stale" ? 580 : 600
        if name == "compact-stale" {
            model.reading = Reading(aqi: 145, city: "Northwest Monitoring Station, A Long Metropolitan District, California", stationTime: "Earlier today", providers: ["Station provider"],
                values: ["t": 22, "h": 58, "w": 2.4, "p": 1016, "pm25": 145, "pm10": 101.5, "o3": 75, "no2": 50, "so2": 12.5, "co": 0.4], observedAt: Date().addingTimeInterval(-4 * 3600), stationTimeZone: .current, stationID: 1)
            model.error = "Unable to connect. Showing the last station reading while OpenAir waits for the station to become available again."
            model.backfillMessage = "Earlier history is unavailable. Showing saved readings."
        }
        let content = DetailView(model: model, preview: true).frame(width: width, height: height, alignment: .top).background(.background).environment(\.colorScheme, scheme)
        let view = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AirError.storage }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AirError.storage }
        try data.write(to: directory.appending(path: "air-quality-\(name).png"))
    }
    print("Rendered light and dark content previews (sample data)")
}
