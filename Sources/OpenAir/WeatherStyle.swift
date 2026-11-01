import AppKit
import SwiftUI
import OpenAirCore

/// Shared surfaces and typography keep every window aligned with the popup.
struct WeatherCard<Content: View>: View {
    let title: String
    let symbol: String
    let accessory: String?
    let content: Content

    init(_ title: String, symbol: String, accessory: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: symbol).accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 0)
                if let accessory { Text(accessory) }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
        }
    }
}

struct AirReadingHeader: View {
    @ObservedObject var model: AirModel
    let reading: Reading
    var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(reading.city)
                .font(.system(size: expanded ? 17 : 15, weight: .semibold))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).help(reading.city)
            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(reading.aqi, format: .number)
                        .font(.system(size: expanded ? 72 : 64, weight: .thin)).monospacedDigit()
                        .minimumScaleFactor(0.65).lineLimit(1)
                    Text("AQI").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    Image(systemName: "aqi.medium")
                        .font(.system(size: expanded ? 34 : 28))
                        .foregroundStyle(model.dataIsCurrent ? Color(nsColor: model.menuDotColor) : .secondary)
                        .accessibilityHidden(true)
                    Text(reading.category)
                        .font(.system(size: expanded ? 17 : 14, weight: .semibold))
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: expanded ? 240 : 132, alignment: .trailing)
            }
            Text(model.freshnessMessage)
                .font(.system(size: expanded ? 12 : 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AirQualityScale(aqi: reading.aqi, current: model.dataIsCurrent, color: Color(nsColor: model.menuDotColor))
                .padding(.top, 4)
        }
    }
}

struct AirQualityScale: View {
    let aqi: Int
    let current: Bool
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let position = min(1, max(0, Double(aqi) / 500))
            let width = max(0, geometry.size.width - 10)
            if current {
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
                .overlay { Circle().strokeBorder(color, lineWidth: 2.5) }
                .frame(width: 10, height: 10)
                .offset(x: width * position)
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

struct WeatherEmptyState<Actions: View>: View {
    let title: String
    let symbol: String
    let description: String
    let actions: Actions

    init(_ title: String, symbol: String, description: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.symbol = symbol
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .ultraLight))
                .foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.system(size: 19, weight: .semibold))
            Text(description).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            actions.controlSize(.regular)
        }
        .frame(maxWidth: 320).padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

func aqiColor(_ aqi: Int) -> Color {
    switch aqi { case ...50: .green; case ...100: .yellow; case ...150: .orange; case ...200: .red; default: .purple }
}
