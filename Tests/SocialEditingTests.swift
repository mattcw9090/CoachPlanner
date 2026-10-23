import Foundation
import SwiftData

@main
private struct SocialEditingTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
            print("PASS: \(message)")
        }
        let schema = Schema([Student.self, StudentHiddenWeek.self, Outsider.self, CoachingSession.self,
                             CourtBooking.self, SocialSession.self, SocialHiddenPerson.self, SocialAttendance.self, SessionStudentConfirmation.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let alice = Student(name: "Alice", gender: "", contactPreference: .sms, contactDetail: "")
        let bob = Student(name: "Bob", gender: "", contactPreference: .sms, contactDetail: "")
        let casey = Outsider(name: "Casey", gender: "", contactPreference: .sms, contactDetail: "")
        let drew = Outsider(name: "Drew", gender: "", contactPreference: .sms, contactDetail: "")
        let aliceAttendance = SocialAttendance(student: alice, status: .confirmed, createdAt: start)
        let caseyAttendance = SocialAttendance(student: nil, outsider: casey, status: .pending, createdAt: start)
        let hiddenBob = SocialHiddenPerson(student: bob, createdAt: start)
        let hiddenDrew = SocialHiddenPerson(outsider: drew, createdAt: start)
        let social = SocialSession(weekStart: start, dayOfWeek: .friday, startTime: start,
                                   endTime: start.addingTimeInterval(3_600), venue: .apex, students: [alice],
                                   hiddenPeople: [hiddenBob, hiddenDrew], attendances: [aliceAttendance, caseyAttendance])
        context.insert(alice); context.insert(bob); context.insert(casey); context.insert(drew); context.insert(social)
        try context.save()
        let attendanceIDs = Set(social.attendanceList.map(\.syncID))
        let hiddenIDs = Set(social.hiddenPersonList.map(\.syncID))
        let initial = SocialSessionEditorSnapshot(social)
        let unchangedEdits = [SocialAttendanceEdit(person: .student(alice), status: .confirmed, paymentStatus: .unpaid),
                              SocialAttendanceEdit(person: .outsider(casey), status: .pending, paymentStatus: .unpaid)]
        social.applyEditorRelationships(attendance: unchangedEdits, hidden: [.student(bob), .outsider(drew)], in: context)
        check(!context.hasChanges, "Unchanged relationship save performs no writes")
        check(Set(social.attendanceList.map(\.syncID)) == attendanceIDs && Set(social.hiddenPersonList.map(\.syncID)) == hiddenIDs,
              "Unchanged save retains all attendance and hidden-person IDs")

        let paidEdits = [SocialAttendanceEdit(person: .student(alice), status: .confirmed, paymentStatus: .paid), unchangedEdits[1]]
        social.applyEditorRelationships(attendance: paidEdits, hidden: [.student(bob), .outsider(drew)], in: context)
        check(social.attendanceList.first { $0.student?.syncID == alice.syncID } === aliceAttendance,
              "Payment edit updates the existing attendance object")
        check(aliceAttendance.paymentStatus == "Paid" && caseyAttendance.status == "Pending" && caseyAttendance.paymentStatus == "Unpaid",
              "Payment edit changes only the selected person's value")
        check(context.insertedModelsArray.isEmpty && context.deletedModelsArray.isEmpty,
              "Payment edit does not insert or delete any child")
        check(Set(social.attendanceList.map(\.syncID)) == attendanceIDs && Set(social.hiddenPersonList.map(\.syncID)) == hiddenIDs &&
              social.attendanceList.allSatisfy { $0.createdAt == start } && social.hiddenPersonList.allSatisfy { $0.createdAt == start },
              "Payment edit preserves child IDs and original creation times")
        check(!initial.matches(social), "A changed attendance payment invalidates an older editor draft")
        try context.save()

        social.applyEditorRelationships(
            attendance: [paidEdits[0], SocialAttendanceEdit(person: .outsider(drew), status: .confirmed, paymentStatus: .unpaid)],
            hidden: [.student(bob), .outsider(casey)], in: context
        )
        check(social.attendanceList.count == 2 && social.hiddenPersonList.count == 2 &&
              social.attendanceList.contains { $0.outsider?.syncID == drew.syncID } &&
              social.hiddenPersonList.contains { $0.outsider?.syncID == casey.syncID },
              "Participant and visibility changes affect only the selected differences")
        check(social.attendanceList.contains { $0 === aliceAttendance } && social.hiddenPersonList.contains { $0 === hiddenBob },
              "Unchanged attendance and visibility objects survive another person's move")
        check(context.insertedModelsArray.count == 2 && context.deletedModelsArray.count == 2,
              "Moving two people inserts and deletes only the two affected children")
        try context.save()

        let fresh = SocialSessionEditorSnapshot(social)
        social.updatedAt = start.addingTimeInterval(500)
        social.lastSyncedAt = social.updatedAt
        for attendance in social.attendanceList {
            attendance.updatedAt = social.updatedAt
            attendance.lastSyncedAt = social.updatedAt
        }
        check(fresh.matches(social), "Sync acknowledgement timestamps do not invalidate an unchanged draft")
        social.title = "Changed remotely"
        check(!fresh.matches(social), "A changed social scalar blocks an old draft")
        social.title = "Badminton Socials"
        social.attendanceList.first { $0.outsider?.syncID == drew.syncID }?.status = "Pending"
        check(!fresh.matches(social), "A remote attendance change blocks an old draft")
        social.attendanceList.first { $0.outsider?.syncID == drew.syncID }?.status = "Confirmed"
        check(fresh.matches(social), "Restoring the same semantic values permits the draft")

        let beforeOwnDeletion = SocialSessionEditorSnapshot(social)
        let departed = social.attendanceList.first { $0.outsider?.syncID == drew.syncID }!
        social.attendanceList.removeAll { $0 === departed }
        context.delete(departed)
        check(!beforeOwnDeletion.matches(social), "A removed participant invalidates an unrelated open draft")
        check(beforeOwnDeletion.matches(social, ignoringDeletedOutsiders: [drew.syncID]),
              "An outsider explicitly deleted inside this editor does not falsely stale its own draft")
        social.title = "Unrelated remote change"
        check(!beforeOwnDeletion.matches(social, ignoringDeletedOutsiders: [drew.syncID]),
              "An explicit outsider deletion never hides another concurrent change")
        try context.save()

        let newSocial = SocialSession(weekStart: start, dayOfWeek: .friday, startTime: start,
                                      endTime: start.addingTimeInterval(3_600), venue: .apex)
        context.insert(newSocial)
        newSocial.applyEditorRelationships(attendance: unchangedEdits, hidden: [.student(bob)], in: context)
        try context.save()
        check(newSocial.attendanceList.count == 2 && newSocial.hiddenPersonList.count == 1 &&
              newSocial.attendanceList.allSatisfy { $0.session === newSocial } &&
              newSocial.hiddenPersonList.allSatisfy { $0.session === newSocial },
              "A new social receives correctly linked new attendance and hidden records")
        let beforeDelete = SocialSessionEditorSnapshot(newSocial)
        context.delete(newSocial)
        check(!beforeDelete.matches(newSocial), "A deleted backing social cannot be saved by an open draft")

        check(TimetableTextScale.pointSize(base: 10, scale: .large) == 10,
              "Standard text size keeps the timetable's base size")
        check(TimetableTextScale.pointSize(base: 10, scale: .xxxLarge) == 13,
              "The largest standard text size caps timetable text at 13pt")
        check(TimetableTextScale.pointSize(base: 10, scale: .accessibility) == 13,
              "Accessibility text sizes use the same 13pt timetable cap")
        let smallerBase = TimetableTextScale.pointSize(base: 8, scale: .xxxLarge)
        check(smallerBase > 8 && smallerBase < 13,
              "A smaller timetable label grows with Dynamic Type and stays under 13pt")

        let afterBusyHour = TimetableFreeSlot.next(
            nowMinutes: 17 * 60,
            today: 3,
            blocks: [TimetableBlock(day: 3, startMinutes: 17 * 60, endMinutes: 18 * 60)]
        )
        check(afterBusyHour.day == 3 && afterBusyHour.startMinutes == 18 * 60 && afterBusyHour.endMinutes == 19 * 60,
              "The next free slot skips a busy hour on the same day")
        let nextHalfHour = TimetableFreeSlot.next(nowMinutes: 9 * 60 + 10, today: 3, blocks: [])
        check(nextHalfHour.day == 3 && nextHalfHour.startMinutes == 9 * 60 + 30 && nextHalfHour.endMinutes == 10 * 60 + 30,
              "Today's free slot starts at the next half hour")
        let nextWeek = TimetableFreeSlot.next(nowMinutes: 22 * 60 + 40, today: 7, blocks: [])
        check(nextWeek.day == 1 && nextWeek.startMinutes == 16 * 60 && nextWeek.endMinutes == 17 * 60,
              "A day with no remaining grid time moves to Monday afternoon")

        let aliceID = alice.syncID
        let bobID = bob.syncID
        let caseyID = casey.syncID
        let mattID = UUID()
        let people = [
            AddSocialPerson(id: aliceID, isStudent: true, name: "Alice", isHidden: false),
            AddSocialPerson(id: bobID, isStudent: true, name: "Bob", isHidden: true),
            AddSocialPerson(id: caseyID, isStudent: false, name: "Casey", isHidden: false),
            AddSocialPerson(id: mattID, isStudent: false, name: " Matt Chew ", isHidden: false)
        ]
        let starting = AddSocialSessionRequest.startingIDs(people: people)
        check(starting == [aliceID, caseyID, mattID],
              "the add list starts with every visible student and every outsider")
        let startingIDs = AddSocialSessionRequest.participantIDs(people: people, remainingIDs: starting)
        check(startingIDs == [aliceID, caseyID, mattID].sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() },
              "the starting list is the participant id list")
        let startingRows = AddSocialSessionRequest.attendance(people: people, participantIDs: Set(startingIDs))
        check(Set(startingRows.map(\.id)) == [aliceID, caseyID, mattID]
              && startingRows.first { $0.id == mattID }?.status == "Confirmed"
              && startingRows.filter { $0.id != mattID }.allSatisfy { $0.status == "Unscheduled" && $0.paymentStatus == "Unpaid" },
              "the starting list skips hidden students, confirms Matt Chew, and leaves the others unpaid")
        let removedAlice = AddSocialSessionRequest.participantIDs(people: people, remainingIDs: [caseyID])
        check(removedAlice == [caseyID, mattID].sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() },
              "removing a person keeps the remaining list and still includes Matt Chew")
        let omittedMatt = AddSocialSessionRequest.participantIDs(people: people, remainingIDs: [aliceID])
        check(Set(omittedMatt) == [aliceID, mattID],
              "Matt Chew stays in the participant ids when his row is missing from the remaining list")
        let addedBack = AddSocialSessionRequest.participantIDs(people: people, remainingIDs: [aliceID, bobID, caseyID, mattID])
        let addedBackRows = AddSocialSessionRequest.attendance(people: people, participantIDs: Set(addedBack))
        check(Set(addedBackRows.map(\.id)) == [aliceID, bobID, caseyID, mattID]
              && addedBackRows.first { $0.id == bobID }?.status == "Unscheduled"
              && addedBackRows.first { $0.id == mattID }?.status == "Confirmed",
              "a hidden student added back is included and Matt Chew stays confirmed")
        var perth = Calendar(identifier: .gregorian)
        perth.timeZone = TimeZone(identifier: "Australia/Perth")!
        let week = perth.date(from: DateComponents(year: 2026, month: 10, day: 19))!
        let evening = perth.date(bySettingHour: 19, minute: 0, second: 0, of: week)!
        let late = perth.date(bySettingHour: 21, minute: 30, second: 0, of: week)!
        let mapped = AddSocialSessionRequest.parameters(
            title: "  Friday Hit ", weekStart: week, dayOfWeek: Weekday.friday.rawValue,
            startTime: evening, endTime: late, venue: "Apex", participantIDs: startingIDs
        )
        check(mapped.date == "2026-10-23" && mapped.startLocal == "19:00:00" && mapped.endLocal == "21:30:00"
              && mapped.venue == "Apex" && mapped.title == "Friday Hit" && !mapped.includeEveryone
              && mapped.participantIDs == startingIDs && mapped.attendanceStatus == "Unscheduled"
              && mapped.jsonObject()["p_include_everyone"] as? Bool == false
              && (mapped.jsonObject()["p_participant_ids"] as? [String]) == startingIDs.map(\.uuidString),
              "the remaining list maps to participant ids with everyone turned off")
        let explicit = AddSocialSessionRequest.parameters(
            title: "   ", weekStart: week, dayOfWeek: Weekday.saturday.rawValue,
            startTime: evening, endTime: late, venue: "TRS",
            participantIDs: AddSocialSessionRequest.participantIDs(people: people, remainingIDs: [bobID, aliceID])
        )
        let explicitIDs = [aliceID, bobID, mattID].sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        check(explicit.date == "2026-10-24" && explicit.title == "Badminton Socials" && !explicit.includeEveryone
              && explicit.participantIDs == explicitIDs
              && (explicit.jsonObject()["p_participant_ids"] as? [String]) == explicit.participantIDs.map(\.uuidString),
              "the saved ids are the remaining people plus Matt Chew, and a blank title uses the default")

        print("\(checks) social editing regression checks passed")
    }
}
