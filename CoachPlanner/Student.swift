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
    var contactPreference: String = ContactPreference.instagram.rawValue
    var contactDetail: String = ""
    var sessionsDemand: Int
    var createdAt: Date

    init(
        name: String,
        gender: String,
        contactPreference: ContactPreference = .instagram,
        contactDetail: String = "",
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
}
