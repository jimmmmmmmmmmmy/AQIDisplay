import AppKit
import SwiftUI
import OpenAirCore


@MainActor
func renderPreviews(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark), ("compact-stale", .light), ("empty", .light)] {
        let model = AirModel(preview: true)
        let size = CGSize(width: name == "compact-stale" ? 520 : 600, height: name == "compact-stale" ? 580 : 740)
        if name == "compact-stale" {
            model.reading = Reading(aqi: 145, city: "Northwest Monitoring Station, A Long Metropolitan District, California", stationTime: "Earlier today", providers: ["Station provider"],
                values: ["t": 22, "h": 58, "w": 2.4, "p": 1016, "pm25": 145, "pm10": 101.5, "o3": 75, "no2": 50, "so2": 12.5, "co": 0.4], observedAt: Date().addingTimeInterval(-4 * 3600), stationTimeZone: .current, stationID: 1)
            model.error = "Unable to connect. Showing the last station reading while OpenAir waits for the station to become available again."
            model.backfillMessage = "Earlier history is unavailable. Showing saved readings."
        } else if name == "empty" {
            model.reading = nil
        }
        try render(DetailView(model: model), name: "air-quality-\(name)", scheme: scheme, size: size, to: directory)
    }
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
        let model = AirModel(preview: true)
        model.preferences = Preferences()
        model.preferences.city = "@1"
        let stations = [
            Station(id: 1, name: "New York", aqi: 42),
            Station(id: 2, name: "Los Angeles-North Main Street", aqi: 17),
            Station(id: 3, name: "Northwest Monitoring Station, A Long Metropolitan District, California", aqi: 145),
            Station(id: 4, name: "San Francisco", aqi: nil)
        ]
        try render(LocationView(model: model, previewStations: stations), name: "locations-\(name)", scheme: scheme,
                   size: CGSize(width: 540, height: 520), to: directory)
        try render(LocationView(model: model), name: "locations-empty-\(name)", scheme: scheme,
                   size: CGSize(width: 440, height: 360), to: directory)
        try render(SettingsView(model: model), name: "settings-\(name)", scheme: scheme, to: directory)
        model.hasToken = false
        model.settingsError = "Unable to save settings."
        try render(SettingsView(model: model), name: "settings-error-\(name)", scheme: scheme, to: directory)
        if let reading = model.reading {
            try render(DataSourcesView(reading: reading), name: "sources-\(name)", scheme: scheme, to: directory)
        }
    }
    print("Rendered light and dark content previews (sample data)")
    try renderPopupPreviews(to: directory)
}

@MainActor
private func renderPopupPreviews(to directory: URL) throws {
    for (name, scheme) in [
        ("light", ColorScheme.light), ("dark", .dark), ("stale", .light),
        ("long-name", .light), ("unavailable", .light), ("setup", .dark),
        ("missing-weather", .light), ("no-history", .light)
    ] {
        let model = AirModel(preview: true)
        if name == "stale" || name == "long-name" {
            model.reading = Reading(aqi: 145,
                city: "Northwest Monitoring Station, A Long Metropolitan District, California",
                values: ["t": 22, "h": 58],
                observedAt: model.now.addingTimeInterval(name == "stale" ? -4 * 3600 : -3600),
                stationTimeZone: .current, stationID: 1)
            if name == "stale" { model.error = AirError.connection.localizedDescription }
        } else if name == "unavailable" || name == "setup" {
            model.reading = nil
            model.hasToken = name != "setup"
            model.error = AirError.connection.localizedDescription
        } else if name == "missing-weather" {
            model.reading = Reading(aqi: 520, city: "Los Angeles-North Main Street",
                observedAt: model.now.addingTimeInterval(-3600), stationTimeZone: .current, stationID: 1)
        } else if name == "no-history" {
            model.points = []
        }
        try render(AirMenu(model: model), name: "popup-\(name)", scheme: scheme, to: directory)
    }
    print("Rendered popup previews (sample data)")
}

@MainActor
private func render<Content: View>(_ content: Content, name: String, scheme: ColorScheme, size: CGSize? = nil, to directory: URL) throws {
    let view = NSHostingView(rootView: content.environment(\.colorScheme, scheme))
    let size = size ?? view.fittingSize
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AirError.storage }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AirError.storage }
    try data.write(to: directory.appending(path: "\(name).png"))
}
