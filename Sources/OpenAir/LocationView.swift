import SwiftUI
import OpenAirCore

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
    init(model: AirModel, previewStations: [Station] = [], previewQuery: String = "") {
        self.model = model
        _stations = State(initialValue: previewStations)
        _query = State(initialValue: previewQuery)
        _searched = State(initialValue: !previewStations.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("City or station", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .onSubmit { search() }
            }
            .padding(13)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5) }
            .padding(24).padding(.bottom, -12)

            if searching {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 16)
            }
            if let error {
                WeatherEmptyState("Search Unavailable", symbol: "wifi.exclamationmark", description: error) { EmptyView() }
            } else if stations.isEmpty && !searching {
                WeatherEmptyState(searched ? "No Locations Found" : "Find a Location", symbol: "magnifyingglass",
                                  description: searched ? "Try another city or station name." : "Search for a city or air quality station.") { EmptyView() }
            } else {
                List(stations, selection: $selection) { station in
                    stationRow(station)
                        .padding(14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        .tag(station.id)
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .padding(.horizontal, 12).padding(.vertical, 8)
            }

            Divider().padding(.horizontal, 24)
            HStack {
                Button("Automatic Location", systemImage: "location") { model.select(nil); dismiss() }
                    .help("Find a nearby station using your internet connection")
                    .buttonStyle(.borderless)
                Spacer()
                Button("Use Location") {
                    if let station = stations.first(where: { $0.id == selection }) { model.select(station); dismiss() }
                }
                .disabled(selection == nil).keyboardShortcut(.defaultAction)
            }
            .font(.system(size: 12)).controlSize(.regular).padding(24)
        }
        .frame(minWidth: 440, minHeight: 360)
        .background(.regularMaterial)
        .onChange(of: query) { _, _ in search(debounce: true) }
        .onDisappear { searchTask?.cancel() }
    }

    private func stationRow(_ station: Station) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "aqi.medium")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(station.aqi.map(aqiColor) ?? .secondary)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(station.name).font(.system(size: 14, weight: .medium))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if model.preferences.city == "@\(station.id)" {
                    Text("Current Location").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(station.aqi.map { "\($0)" } ?? "—")
                    .font(.system(size: 28, weight: .thin)).monospacedDigit()
                Text("AQI").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
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

