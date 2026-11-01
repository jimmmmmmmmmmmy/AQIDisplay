import SwiftUI
import OpenAirCore

struct SettingsView: View {
    @ObservedObject var model: AirModel
    @State private var apiKey = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                WeatherCard("Menu Bar", symbol: "menubar.rectangle") {
                    VStack(spacing: 0) {
                        settingToggle("Air quality", binding: option("AQI"))
                        Divider()
                        settingToggle("Temperature", binding: option("Temperature"))
                        Divider()
                        settingToggle("Humidity", binding: option("Humidity"))
                        Divider()
                        settingToggle("Location name", binding: option("City"))
                        Divider()
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Picker("Temperature", selection: $model.preferences.temperatureUnit) {
                                Text("Fahrenheit (°F)").tag("°F")
                                Text("Celsius (°C)").tag("°C")
                            }
                            .labelsHidden().pickerStyle(.menu)
                        }
                        .padding(.vertical, 8)
                    }
                }
                WeatherCard("General", symbol: "gearshape") {
                    VStack(alignment: .leading, spacing: 8) {
                        settingToggle("Open at login", binding: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                        Text("Updates automatically every 5 minutes.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                WeatherCard("Air Quality Data", symbol: "aqi.medium") {
                    SecureField(model.hasToken ? "Replace API key" : "API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder).controlSize(.large)
                    HStack {
                        Link("Get a WAQI API Key", destination: URL(string: "https://aqicn.org/data-platform/token/")!)
                            .font(.system(size: 12))
                        Spacer()
                        Button("Save") { model.saveKey(apiKey); apiKey = "" }
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text(model.hasToken ? "Your API key is saved on this Mac." : "An API key is required to get air quality data.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let error = model.settingsError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 13)).padding(24)
        }
        .scrollIndicators(.automatic)
        .frame(width: 480, height: 660)
        .background(.regularMaterial)
        .onChange(of: model.preferences) { _, _ in model.savePreferences() }
    }

    private func settingToggle(_ title: String, binding: Binding<Bool>) -> some View {
        HStack {
            Text(title).accessibilityHidden(true)
            Spacer()
            Toggle(title, isOn: binding)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.vertical, 8)
    }

    private func option(_ key: String) -> Binding<Bool> {
        Binding(get: { model.preferences.formatOptions[key] ?? false }, set: { model.preferences.formatOptions[key] = $0 })
    }
}
