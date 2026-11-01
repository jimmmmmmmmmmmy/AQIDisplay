import AppKit
import SwiftUI
import OpenAirCore

struct AirMenu: View {
    @ObservedObject var model: AirModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                if let reading = model.reading {
                    header(reading)
                    if model.error != nil {
                        Label(model.hasToken ? "Unable to Update" : "Add an API key in Settings", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    weather(reading)
                    if !recentPoints.isEmpty {
                        Divider()
                        history(reading)
                    }
                } else {
                    Image(systemName: "aqi.medium")
                        .font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(model.hasToken ? "Air Quality Unavailable" : "Welcome to OpenAir")
                        .font(.headline)
                    if model.error != nil {
                        Text(model.hasToken ? "Unable to Update" : "Add an API key in Settings")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)

            Divider().padding(.horizontal, 20)
            Button { show("details") } label: { navigationRow("Air Quality") }
                .buttonStyle(PopupRowStyle())
            Divider().padding(.horizontal, 20)
            Button { show("locations") } label: { navigationRow("Locations…") }
                .buttonStyle(PopupRowStyle())
            Divider().padding(.horizontal, 20)

            HStack(spacing: 8) {
                Button(model.refreshing ? "Updating…" : "Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                    .disabled(model.refreshing).keyboardShortcut("r")
                Spacer(minLength: 0)
                Button("Settings…", systemImage: "gearshape") {
                    openSettings()
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    dismiss()
                }
                    .keyboardShortcut(",")
            }
            .font(.system(size: 12))
            .buttonStyle(.borderless)
            .padding(.horizontal, 20).padding(.vertical, 14)

            Divider().padding(.horizontal, 20)
            Button { NSApplication.shared.terminate(nil) } label: {
                Text("Quit OpenAir")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 11)
                    .contentShape(Rectangle())
            }
                .buttonStyle(PopupRowStyle())
                .keyboardShortcut("q")
        }
        .foregroundStyle(.primary)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
    }

    private func header(_ reading: Reading) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(reading.city)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .help(reading.city)
            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(reading.aqi, format: .number)
                        .font(.system(size: 64, weight: .thin)).monospacedDigit()
                        .minimumScaleFactor(0.65).lineLimit(1)
                    Text("AQI").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    Image(systemName: "aqi.medium")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(model.dataIsCurrent ? Color(nsColor: model.menuDotColor) : .secondary)
                        .accessibilityHidden(true)
                    Text(reading.category)
                        .font(.system(size: 14, weight: .semibold))
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 132, alignment: .trailing)
            }
            Text(model.freshnessMessage)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            qualityScale(reading)
                .padding(.top, 4)
        }
    }

    private func qualityScale(_ reading: Reading) -> some View {
        GeometryReader { geometry in
            // US AQI breakpoints share a numeric 0...500 scale. Old or
            // unverified readings retain the app's neutral status treatment.
            let position = min(1, max(0, Double(reading.aqi) / 500))
            let width = max(0, geometry.size.width - 10)
            if model.dataIsCurrent {
                Capsule()
                .fill(LinearGradient(stops: [
                    .init(color: .green, location: 0),
                    .init(color: .yellow, location: 0.1),
                    .init(color: .orange, location: 0.2),
                    .init(color: .red, location: 0.3),
                    .init(color: .purple, location: 0.4),
                    .init(color: Color(red: 0.5, green: 0.15, blue: 0.24), location: 0.6),
                    .init(color: Color(red: 0.5, green: 0.15, blue: 0.24), location: 1)
                ], startPoint: .leading, endPoint: .trailing))
                    .opacity(0.85)
                    .frame(height: 5).frame(maxHeight: .infinity)
            } else {
                Capsule().fill(.quaternary).frame(height: 5).frame(maxHeight: .infinity)
            }
            Circle()
                .fill(.background)
                .overlay { Circle().strokeBorder(model.dataIsCurrent ? Color(nsColor: model.menuDotColor) : .secondary, lineWidth: 2.5) }
                .frame(width: 10, height: 10)
                .offset(x: width * position)
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private func weather(_ reading: Reading) -> some View {
        HStack(spacing: 20) {
            weatherMetric("Temperature", symbol: "thermometer.medium", value: reading.temperature(fahrenheit: model.fahrenheit).map {
                "\(Int($0.rounded()))\(model.preferences.temperatureUnit)"
            } ?? "—")
            Spacer(minLength: 0)
            weatherMetric("Humidity", symbol: "humidity", value: reading.values["h"].map {
                "\(Int($0.rounded()))%"
            } ?? "—")
        }
    }

    private func weatherMetric(_ title: String, symbol: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20, weight: .light))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 18, weight: .medium)).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var recentPoints: [HistoryPoint] {
        Array(model.points.filter {
            $0.date > model.now.addingTimeInterval(-86400) && $0.date <= model.now
        }.sorted { $0.date < $1.date }.suffix(5))
    }

    private func history(_ reading: Reading) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Past 24 Hours").font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                ForEach(recentPoints) { point in
                    VStack(spacing: 12) {
                        Text(point.date, format: Date.FormatStyle(timeZone: reading.stationTimeZone ?? .current).hour())
                            .font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        Circle().fill(historyColor(point.aqi)).frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(point.aqi, format: .number)
                            .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func historyColor(_ aqi: Int) -> Color {
        switch aqi {
        case ...50: .green
        case ...100: .yellow
        case ...150: .orange
        case ...200: .red
        default: .purple
        }
    }

    private func navigationRow(_ title: String) -> some View {
        HStack {
            Text(title).font(.system(size: 14))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
        dismiss()
    }
}

private struct PopupRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.1 : (hovering ? 0.05 : 0)))
            .onHover { hovering = $0 }
    }
}
