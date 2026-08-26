import SwiftUI

enum AppStorageKey {
    static let trsBookingContactPhone = "trsBookingContactPhone"
}

enum AustralianPhoneNumber {
    static func international(from value: String) -> String {
        let digits = localDigits(from: value)
        guard !digits.isEmpty else { return "" }
        return "+61" + digits
    }

    static func groupedLocal(from value: String) -> String {
        let digits = localDigits(from: value)
        guard !digits.isEmpty else { return "" }

        var groups = [String(digits.prefix(3))]
        if digits.count > 3 {
            groups.append(String(digits.dropFirst(3).prefix(3)))
        }
        if digits.count > 6 {
            groups.append(String(digits.dropFirst(6)))
        }
        return groups.joined(separator: " ")
    }

    static func localDigits(from value: String) -> String {
        let digits = value.filter(\.isNumber)
        let withoutCountryCode = digits.hasPrefix("61")
            ? String(digits.dropFirst(2))
            : digits
        let withoutLeadingZero = withoutCountryCode.hasPrefix("0")
            ? String(withoutCountryCode.dropFirst())
            : withoutCountryCode
        return String(withoutLeadingZero.prefix(9))
    }

    static func whatsappDigits(from value: String) -> String? {
        let digits = localDigits(from: value)
        guard digits.count == 9 else { return nil }
        return "61" + digits
    }
}

enum AppStyle {
    static let background = Color(.systemGroupedBackground)
    static let surface = Color(.secondarySystemGroupedBackground)
    static let insetSurface = Color(.tertiarySystemGroupedBackground)
    static let separator = Color(.separator)
    static let radius: CGFloat = 10

    static func timeGridFont(size: CGFloat, weight: Font.Weight) -> Font {
#if targetEnvironment(macCatalyst)
        .system(size: size * 1.25, weight: weight)
#else
        .system(size: size, weight: weight)
#endif
    }

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

extension View {
    @ViewBuilder
    func desktopReadableTypography() -> some View {
#if targetEnvironment(macCatalyst)
        dynamicTypeSize(.xxLarge ... .accessibility5)
#else
        self
#endif
    }

    @ViewBuilder
    func desktopContentWidth(_ maxWidth: CGFloat) -> some View {
#if targetEnvironment(macCatalyst)
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
#else
        self
#endif
    }

    @ViewBuilder
    func desktopSheetSize(width: CGFloat, height: CGFloat) -> some View {
#if targetEnvironment(macCatalyst)
        frame(minWidth: width, minHeight: height)
#else
        self
#endif
    }
}
