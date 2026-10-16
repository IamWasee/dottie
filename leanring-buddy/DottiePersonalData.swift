//
//  DottiePersonalData.swift
//  leanring-buddy
//
//  Calendar, Reminders and Contacts through Apple's own frameworks, so
//  Dottie can answer "what's my day look like?", add events and reminders,
//  tick reminders off and look up a contact. macOS asks the user once for
//  each the first time it's used. Nothing here deletes anything.
//

import Contacts
import EventKit
import Foundation

@MainActor
final class DottiePersonalData {
    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()

    // MARK: - Access

    private func ensureCalendarAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return true
        case .notDetermined, .writeOnly:
            return (try? await eventStore.requestFullAccessToEvents()) ?? false
        default:
            return false
        }
    }

    private func ensureRemindersAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized:
            return true
        case .notDetermined, .writeOnly:
            return (try? await eventStore.requestFullAccessToReminders()) ?? false
        default:
            return false
        }
    }

    private func ensureContactsAccess() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return true
        case .notDetermined:
            return (try? await contactStore.requestAccess(for: .contacts)) ?? false
        default:
            // .limited (macOS 15) counts as allowed for what the user picked.
            return CNContactStore.authorizationStatus(for: .contacts).rawValue == 4
        }
    }

    private static func noAccessMessage(_ thing: String) -> String {
        "Dottie isn't allowed to use \(thing). tell the user to turn it on in System Settings → Privacy & Security → \(thing.capitalized) → Dottie."
    }

    // MARK: - Calendar

    func schedule(startText: String?, endText: String?) async -> String {
        guard await ensureCalendarAccess() else { return Self.noAccessMessage("calendars") }
        let calendar = Calendar.current
        let startDate = startText.flatMap(Self.parseDate) ?? calendar.startOfDay(for: Date())
        var endDate = endText.flatMap(Self.parseDate) ?? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: startDate))!
        if endDate <= startDate {
            endDate = calendar.date(byAdding: .day, value: 1, to: startDate)!
        }
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let events = eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        let rangeText = "\(Self.dayFormatter.string(from: startDate)) to \(Self.dayFormatter.string(from: endDate))"
        guard !events.isEmpty else {
            return "nothing on the calendar from \(rangeText). \(Self.nowLine)"
        }
        let lines = events.prefix(60).map { event -> String in
            var line = event.isAllDay
                ? "\(Self.dayFormatter.string(from: event.startDate)), all day: \(event.title ?? "untitled")"
                : "\(Self.dayFormatter.string(from: event.startDate)) \(Self.timeFormatter.string(from: event.startDate))–\(Self.timeFormatter.string(from: event.endDate)): \(event.title ?? "untitled")"
            if let location = event.location, !location.isEmpty {
                line += " @ \(location)"
            }
            if let calendarTitle = event.calendar?.title {
                line += " [\(calendarTitle)]"
            }
            return "- " + line
        }
        return "calendar from \(rangeText):\n" + lines.joined(separator: "\n") + "\n\(Self.nowLine)"
    }

    func addEvent(title: String, startText: String, endText: String?, location: String?, notes: String?) async -> String {
        guard await ensureCalendarAccess() else { return Self.noAccessMessage("calendars") }
        guard let startDate = Self.parseDate(startText) else {
            return "couldn't read the start time \(startText). use a date like 2026-10-17T15:00. \(Self.nowLine)"
        }
        guard let targetCalendar = eventStore.defaultCalendarForNewEvents else {
            return "there's no calendar to add events to on this Mac."
        }
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.calendar = targetCalendar
        let isAllDay = !startText.contains(":")
        event.isAllDay = isAllDay
        event.startDate = startDate
        let defaultEnd = isAllDay ? startDate : startDate.addingTimeInterval(3600)
        event.endDate = endText.flatMap(Self.parseDate).flatMap { $0 > startDate ? $0 : nil } ?? defaultEnd
        if let location, !location.isEmpty { event.location = location }
        if let notes, !notes.isEmpty { event.notes = notes }
        do {
            try eventStore.save(event, span: .thisEvent)
        } catch {
            return "couldn't add it: \(error.localizedDescription)"
        }
        let whenText = isAllDay
            ? Self.dayFormatter.string(from: startDate) + " (all day)"
            : "\(Self.dayFormatter.string(from: startDate)) at \(Self.timeFormatter.string(from: startDate))"
        return "added \"\(title)\" on \(whenText) to the \(targetCalendar.title) calendar."
    }

    // MARK: - Reminders

    func reminders() async -> String {
        guard await ensureRemindersAccess() else { return Self.noAccessMessage("reminders") }
        let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let reminderLines: [String] = await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            eventStore.fetchReminders(matching: predicate) { fetchedReminders in
                let sortedReminders = (fetchedReminders ?? []).sorted {
                    ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
                }
                let lines = sortedReminders.prefix(80).map { reminder -> String in
                    var line = "- \(reminder.title ?? "untitled")"
                    if let dueDate = reminder.dueDateComponents.flatMap({ Calendar.current.date(from: $0) }) {
                        line += " (due \(DottiePersonalData.dayFormatter.string(from: dueDate)) \(DottiePersonalData.timeFormatter.string(from: dueDate)))"
                    }
                    if let listTitle = reminder.calendar?.title {
                        line += " [\(listTitle)]"
                    }
                    return line
                }
                continuation.resume(returning: Array(lines))
            }
        }
        guard !reminderLines.isEmpty else { return "no open reminders. \(Self.nowLine)" }
        return "open reminders:\n" + reminderLines.joined(separator: "\n") + "\n\(Self.nowLine)"
    }

    func addReminder(title: String, dueText: String?, notes: String?) async -> String {
        guard await ensureRemindersAccess() else { return Self.noAccessMessage("reminders") }
        guard let targetList = eventStore.defaultCalendarForNewReminders() else {
            return "there's no reminders list on this Mac."
        }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = targetList
        if let notes, !notes.isEmpty { reminder.notes = notes }
        var dueDescription = ""
        if let dueText, !dueText.isEmpty {
            guard let dueDate = Self.parseDate(dueText) else {
                return "couldn't read the time \(dueText). use a date like 2026-10-17T17:00. \(Self.nowLine)"
            }
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
            // An alarm makes it actually pop up at that time.
            reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
            dueDescription = " for \(Self.dayFormatter.string(from: dueDate)) at \(Self.timeFormatter.string(from: dueDate))"
        }
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            return "couldn't add it: \(error.localizedDescription)"
        }
        return "added the reminder \"\(title)\"\(dueDescription) in \(targetList.title)."
    }

    func completeReminder(titled requestedTitle: String) async -> String {
        guard await ensureRemindersAccess() else { return Self.noAccessMessage("reminders") }
        let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let completedTitle: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            eventStore.fetchReminders(matching: predicate) { fetchedReminders in
                let candidates = fetchedReminders ?? []
                let match = candidates.first { ($0.title ?? "").caseInsensitiveCompare(requestedTitle) == .orderedSame }
                    ?? candidates.first { ($0.title ?? "").localizedCaseInsensitiveContains(requestedTitle) }
                    ?? candidates.first { requestedTitle.localizedCaseInsensitiveContains($0.title ?? "\u{0}") }
                continuation.resume(returning: match?.calendarItemIdentifier)
            }
        }
        guard let completedTitle,
              let reminder = eventStore.calendarItem(withIdentifier: completedTitle) as? EKReminder else {
            return "couldn't find an open reminder like \"\(requestedTitle)\"."
        }
        reminder.isCompleted = true
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            return "couldn't tick it off: \(error.localizedDescription)"
        }
        return "ticked off \"\(reminder.title ?? requestedTitle)\"."
    }

    // MARK: - Contacts

    func findContact(named name: String) async -> String {
        guard await ensureContactsAccess() else { return Self.noAccessMessage("contacts") }
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactBirthdayKey,
            CNContactPostalAddressesKey
        ].map { $0 as CNKeyDescriptor }
        let contacts = (try? contactStore.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: name),
            keysToFetch: keysToFetch
        )) ?? []
        guard !contacts.isEmpty else { return "no contact matches \(name)." }
        let lines = contacts.prefix(5).map { contact -> String in
            var parts = ["\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)]
            if !contact.organizationName.isEmpty { parts.append(contact.organizationName) }
            let phones = contact.phoneNumbers.map { "\(CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0.label ?? "phone")): \($0.value.stringValue)" }
            if !phones.isEmpty { parts.append(phones.joined(separator: ", ")) }
            let emails = contact.emailAddresses.map { $0.value as String }
            if !emails.isEmpty { parts.append(emails.joined(separator: ", ")) }
            if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
                parts.append("birthday \(month)/\(day)")
            }
            if let address = contact.postalAddresses.first?.value {
                parts.append(CNPostalAddressFormatter.string(from: address, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", "))
            }
            return "- " + parts.joined(separator: " · ")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Dates

    nonisolated static var nowLine: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d yyyy, h:mm a"
        return "(right now it's \(formatter.string(from: Date())).)"
    }

    nonisolated static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d"
        return formatter
    }()

    nonisolated static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    /// Reads the ISO-style dates the model sends, in the user's time zone
    /// unless the text names one.
    nonisolated static func parseDate(_ text: String) -> Date? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }
        let isoFormatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            isoFormatter.formatOptions = options
            if let date = isoFormatter.date(from: trimmedText) { return date }
        }
        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            localFormatter.dateFormat = format
            if let date = localFormatter.date(from: trimmedText) { return date }
        }
        return nil
    }
}
