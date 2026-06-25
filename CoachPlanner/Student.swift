import Foundation
import SwiftData

enum ContactPreference: String, CaseIterable, Identifiable {
    case instagram = "Instagram"
    case whatsApp = "WhatsApp"
    case fbMessenger = "Fb Messenger"
    case sms = "SMS"

    var id: String { rawValue }

    var detailLabel: String {
        switch self {
        case .instagram:
            return "Instagram Handle"
        case .whatsApp, .sms:
            return "Mobile Number"
        case .fbMessenger:
            return "Facebook Profile Link"
        }
    }

    var placeholder: String {
        switch self {
        case .instagram:
            return "@username"
        case .whatsApp, .sms:
            return "+61 400 000 000"
        case .fbMessenger:
            return "https://facebook.com/username"
        }
    }

    var iconName: String {
        switch self {
        case .instagram:
            return "camera.circle.fill"
        case .whatsApp:
            return "phone.bubble.left.fill"
        case .fbMessenger:
            return "message.circle.fill"
        case .sms:
            return "message.fill"
        }
    }
}

@Model
final class Student {
    var name: String
    var gender: String
    var contactPreference: String
    var contactDetail: String
    var sessionsDemand: Int
    var createdAt: Date

    @Relationship(inverse: \CoachingSession.students)
    var sessions: [CoachingSession] = []

    init(
        name: String,
        gender: String,
        contactPreference: ContactPreference,
        contactDetail: String,
        sessionsDemand: Int = 1,
        createdAt: Date = .now
    ) {
        self.name = name
        self.gender = gender
        self.contactPreference = contactPreference.rawValue
        self.contactDetail = contactDetail
        self.sessionsDemand = sessionsDemand
        self.createdAt = createdAt
    }

    var contactPreferenceValue: ContactPreference {
        ContactPreference(rawValue: contactPreference) ?? .instagram
    }

    var displayContactDetail: String {
        switch contactPreferenceValue {
        case .whatsApp, .sms:
            return Self.displayAustralianPhoneNumber(contactDetail)
        case .instagram, .fbMessenger:
            return contactDetail
        }
    }

    private static func displayAustralianPhoneNumber(_ value: String) -> String {
        let digits = value.filter(\.isNumber)

        let localDigits: String
        if digits.hasPrefix("61") {
            localDigits = String(digits.dropFirst(2).prefix(9))
        } else if digits.hasPrefix("0") {
            localDigits = String(digits.dropFirst().prefix(9))
        } else {
            localDigits = String(digits.prefix(9))
        }

        guard !localDigits.isEmpty else { return "" }

        var groups: [String] = [String(localDigits.prefix(3))]
        if localDigits.count > 3 {
            let start = localDigits.index(localDigits.startIndex, offsetBy: 3)
            let end = localDigits.index(start, offsetBy: min(3, localDigits.distance(from: start, to: localDigits.endIndex)))
            groups.append(String(localDigits[start..<end]))
        }
        if localDigits.count > 6 {
            let start = localDigits.index(localDigits.startIndex, offsetBy: 6)
            groups.append(String(localDigits[start...]))
        }

        return "+61 " + groups.joined(separator: " ")
    }
}
