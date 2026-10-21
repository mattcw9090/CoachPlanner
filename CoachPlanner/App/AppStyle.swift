import SwiftUI

enum AppStorageKey {
    static let trsBookingContactPhone = "trsBookingContactPhone"
    static let autoSyncOnLaunch = "autoSyncOnLaunch"
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

    static func timeGridFont(size: CGFloat, weight: Font.Weight, dynamicTypeSize: DynamicTypeSize) -> Font {
        .system(
            size: TimetableTextScale.pointSize(base: size, scale: TimetableTextScale(dynamicTypeSize)),
            weight: weight
        )
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

extension TimetableTextScale {
    init(_ size: DynamicTypeSize) {
        switch size {
        case .xSmall: self = .xSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .xLarge: self = .xLarge
        case .xxLarge: self = .xxLarge
        case .xxxLarge: self = .xxxLarge
        default: self = .accessibility
        }
    }
}

/// The date range and previous/next controls shared by Students, Sessions, and Socials.
struct WeekRangeControls: View {
    let weekStart: Date
    let onMove: (Int) -> Void

    private var weekEnd: Date {
        Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
    }

    private var weekRangeText: String {
        let formatter = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return "\(weekStart.formatted(formatter)) – \(weekEnd.formatted(formatter))"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(weekRangeText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button {
                    onMove(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Previous week")

                Button {
                    onMove(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Next week")
            }
        }
    }
}
