import AppKit
import SwiftUI
import Charts
import OpenAirCore

struct DetailView: View {
    @ObservedObject var model: AirModel
    @State private var showSources = false
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Group {
            if let reading = model.reading {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        AirReadingHeader(model: model, reading: reading, expanded: true)
                            .padding(.horizontal, 4).padding(.bottom, 4)
                        if let error = model.error ?? model.historyWarning {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).help(error)
                        }
                        WeatherCard("Past 24 Hours", symbol: "chart.xyaxis.line") {
                            chart(reading)
                            Text(model.backfilling ? "Loading earlier readings…" : (model.backfillMessage ?? "Station observations · History fills in automatically"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        pollutants(reading)
                        WeatherCard("Weather", symbol: "cloud.sun") {
                            HStack(alignment: .top, spacing: 12) {
                                metric("Temperature", symbol: "thermometer.medium", value: temperature(reading))
                                metric("Humidity", symbol: "humidity", value: value(reading, "h", suffix: "%"))
                                metric("Wind", symbol: "wind", value: value(reading, "w", suffix: " m/s"))
                                metric("Pressure", symbol: "barometer", value: value(reading, "p", suffix: " hPa"))
                            }
                        }
                        HStack(alignment: .center, spacing: 12) {
                            Text("Checked \(reading.fetched.formatted(date: .omitted, time: .shortened)) · Refreshes every 5 minutes")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("Data Sources", systemImage: "info.circle") { showSources.toggle() }
                                .font(.system(size: 11)).buttonStyle(.borderless)
                                .popover(isPresented: $showSources) { DataSourcesView(reading: reading) }
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding(20)
                }
                .scrollIndicators(.automatic)
            } else {
                WeatherEmptyState(model.hasToken ? "No Air Quality Data" : "Set Up OpenAir", symbol: "aqi.medium",
                                  description: model.error ?? "Your latest reading will appear here.") {
                    if model.hasToken { Button("Try Again") { model.refresh() }.disabled(model.refreshing) }
                    else { SettingsLink { Text("Open Settings") } }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 580)
        .background(.regularMaterial)
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
                    .foregroundStyle(aqiColor(point.aqi)).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Time", point.date), y: .value("Air quality", point.aqi))
                    .foregroundStyle(aqiColor(point.aqi)).symbolSize(18)
            }
        }
        .chartXScale(domain: model.now.addingTimeInterval(-86400)...model.now)
        .chartYScale(domain: 0...max(50, (model.points.map(\.aqi).max() ?? 50) + 10))
        .chartXAxis { AxisMarks(values: chartTicks) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
        .frame(height: 110)
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
        WeatherCard("Pollutants", symbol: "aqi.medium", accessory: "US AQI") {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(zip(["PM₂.₅", "PM₁₀", "O₃", "NO₂", "SO₂", "CO"], ["pm25", "pm10", "o3", "no2", "so2", "co"])), id: \.0) { label, key in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(value(reading, key, suffix: ""))
                            .font(.system(size: 22, weight: .light)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(pollutantName(key))
                    .accessibilityValue(reading.values[key] == nil ? "Unavailable" : value(reading, key, suffix: " AQI"))
                }
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
    private func temperature(_ reading: Reading) -> String { reading.temperature(fahrenheit: model.fahrenheit).map { "\(Int($0.rounded()))\(model.preferences.temperatureUnit)" } ?? "—" }
    private func value(_ reading: Reading, _ key: String, suffix: String) -> String { reading.values[key].map { $0.formatted(.number.precision(.fractionLength(0...1))) + suffix } ?? "—" }
    private func metric(_ name: String, symbol: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary).accessibilityHidden(true)
            Text(value).font(.system(size: 21, weight: .light)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65)
            Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct DataSourcesView: View {
    let reading: Reading

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Link("World Air Quality Index", destination: reading.sourceURL ?? URL(string: "https://aqicn.org/")!)
            Text(reading.providers.joined(separator: " · ")).font(.callout)
            Text("Station time: \(reading.stationTime)").font(.caption).textSelection(.enabled)
            Text("Current means observed today at the station, within 3 hours. Older or unverified readings have a neutral indicator.").font(.caption).foregroundStyle(.secondary)
            Text("Each refresh checks this station’s WAQI chart for earlier hourly readings. Historical air quality is the maximum of its reported pollutant indices, only at hours where all reported series are present. Missing hours stay empty.").font(.caption).foregroundStyle(.secondary)
        }.font(.system(size: 13)).padding(24).frame(width: 340).background(.regularMaterial)
    }
}
