import SwiftUI

enum AppStyle {
    static let background = Color(.systemGroupedBackground)
    static let surface = Color(.secondarySystemGroupedBackground)
    static let insetSurface = Color(.tertiarySystemGroupedBackground)
    static let separator = Color(.separator)
    static let radius: CGFloat = 10

    static var currencyCode: String {
        Locale.current.currency?.identifier ?? "AUD"
    }

    static func genderColor(for gender: String) -> Color {
        switch gender {
        case "Female": return .pink
        case "Male": return .blue
        default: return .gray
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(tint.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.radius)
                .fill(AppStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.radius)
                .stroke(AppStyle.separator.opacity(0.16), lineWidth: 0.5)
        )
    }
}
