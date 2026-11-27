//
//  HomeAppTasksAdminSection.swift
//  leanring-buddy
//
//  Home → Admin's app memory part: the hidden memory trial (screen jobs
//  with app memory on, off or at random, and how the two compare from the
//  job reports), and every app and site Dottie learned about: pages seen,
//  its card on how it works, the named tasks there (how often each worked,
//  its problems, forget one), watched how-tos, and notes or a tour the user
//  types, which a model turns into the card and tasks (DottieAppNotes).
//

import SwiftUI

struct HomeAppTasksAdminSection: View {
    @ObservedObject private var appTasks = DottieAppTasks.shared
    @ObservedObject private var jobReports = DottieJobReports.shared
    @ObservedObject private var appNotes = DottieAppNotes.shared
    @ObservedObject private var watchAndLearn = DottieWatchAndLearn.shared
    /// App memory's places, read from disk when the section shows.
    @State private var memoryPlaces: [DottieAppNotesPlan.MemoryPlace] = []
    @State private var expandedPlaceKeys = Set<String>()
    /// Notes being typed, per place.
    @State private var draftNotesByPlace: [String: String] = [:]
    @State private var newPlaceName = ""
    @State private var newPlaceNotes = ""
    @State private var newPlaceProblem = ""

    private var knownPlaces: [DottieKnownPlace] {
        DottieAppNotesPlan.knownPlaces(tasks: appTasks.tasks, howTos: watchAndLearn.howTos, memoryPlaces: memoryPlaces,
                                       notes: appNotes.notes, cardPlaceKeys: appTasks.cardPlaceKeys)
    }
    @AppStorage(DottieAppMemoryTrial.modeDefaultsKey) private var trialModeRawValue = DottieAppMemoryTrial.Mode.on.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Beta · App memory trial")
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $trialModeRawValue) {
                    ForEach(DottieAppMemoryTrial.Mode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .pointerCursor()
                hintText("Random runs each screen job with app memory (saved tasks, remembered clicks, app cards) or without it, so the two can be compared on the same jobs.")
                Text(DottieAppMemoryTrial.comparisonText(DottieAppMemoryTrial.summaries(of: jobReports.reports)))
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let lastReport = jobReports.reports.last {
                    hintText("Last job: " + DottieAppMemoryTrial.logLine(lastReport))
                }
                if !jobReports.reports.isEmpty {
                    Button("Clear the job reports") { jobReports.forgetAll() }
                        .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                }
            }
            .padding(16)
            .background(cardBackground)

            sectionTitle("Apps and sites Dottie knows")
            VStack(alignment: .leading, spacing: 10) {
                Text("Teach Dottie about an app or site")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                hintText("Type a tour, tips or the steps of a job in your own words. Dottie keeps your notes for her jobs there, and an AI turns them into how the app works and named tasks.")
                TextField("App or site (OpenEMR, localhost, notion.so)", text: $newPlaceName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                notesEditor(text: $newPlaceNotes)
                HStack(spacing: 8) {
                    Button("Teach Dottie") { teachNewPlace() }
                        .buttonStyle(DSPrimaryButtonStyle(isFullWidth: false))
                        .disabled(newPlaceName.trimmingCharacters(in: .whitespaces).isEmpty || newPlaceNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .pointerCursor()
                    if !newPlaceProblem.isEmpty { hintText(newPlaceProblem) }
                }
            }
            .padding(16)
            .background(cardBackground)

            if knownPlaces.isEmpty {
                hintText("Nothing yet. Apps and sites show up here once Dottie remembers their pages, finishes a job there, watches you or gets your notes.")
            }
            ForEach(knownPlaces) { place in
                placeCard(place)
            }
        }
        .onAppear { memoryPlaces = DottieAppMemory.shared.knownPlacesForAdmin() }
    }

    private func teachNewPlace() {
        guard let place = appNotes.place(forTypedName: newPlaceName, knownPlaces: knownPlaces) else {
            newPlaceProblem = "Dottie doesn't know that app. Type its name as it's installed, or the site's web address."
            return
        }
        appNotes.teach(newPlaceNotes, placeKey: place.placeKey, appName: place.appName)
        expandedPlaceKeys.insert(place.placeKey)
        newPlaceName = ""
        newPlaceNotes = ""
        newPlaceProblem = ""
    }

    private func placeCard(_ place: DottieKnownPlace) -> some View {
        let isExpanded = expandedPlaceKeys.contains(place.placeKey)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                if isExpanded { expandedPlaceKeys.remove(place.placeKey) } else { expandedPlaceKeys.insert(place.placeKey) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 12)
                    Text(place.appName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    if place.appName != place.placeKey {
                        Text(place.placeKey)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    Spacer(minLength: 8)
                    Text(placeCounts(place))
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded {
                placeDetails(place)
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private func placeCounts(_ place: DottieKnownPlace) -> String {
        var parts: [String] = []
        if place.pagesSeen > 0 { parts.append("\(place.pagesSeen) page\(place.pagesSeen == 1 ? "" : "s")") }
        if place.taskCount > 0 { parts.append("\(place.taskCount) task\(place.taskCount == 1 ? "" : "s")") }
        if place.howToCount > 0 { parts.append("\(place.howToCount) how-to\(place.howToCount == 1 ? "" : "s")") }
        if place.noteCount > 0 { parts.append("\(place.noteCount) note\(place.noteCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func placeDetails(_ place: DottieKnownPlace) -> some View {
        if let card = appTasks.card(forPlace: place.placeKey) {
            subTitle("How it works")
            Text(card.text)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }

        let placeTasks = appTasks.tasks
            .filter { ($0.places.isEmpty ? [$0.appName.lowercased()] : $0.places).contains(place.placeKey) }
            .sorted { $0.lastUsed > $1.lastUsed }
        if !placeTasks.isEmpty {
            subTitle("Tasks")
            ForEach(placeTasks) { task in
                taskRow(task)
            }
        }

        let placeHowTos = watchAndLearn.howTos.filter { ($0.places ?? []).contains(place.placeKey) }
        if !placeHowTos.isEmpty {
            subTitle("Watched")
            ForEach(placeHowTos) { howTo in
                hintText("\(howTo.isTour ? "Tour" : "How-to"): \(howTo.name). \(howTo.summary)")
            }
        }

        let placeNotes = appNotes.notes(forPlace: place.placeKey)
        if !placeNotes.isEmpty {
            subTitle("Your notes")
            ForEach(placeNotes) { note in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.text)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        hintText(note.learnedAt == nil ? "Kept for jobs here, not learned from yet" : (note.learnedSummary ?? "Learned"))
                    }
                    Spacer(minLength: 8)
                    Button("Forget") { appNotes.forget(noteID: note.id) }
                        .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                        .pointerCursor()
                }
            }
        }

        subTitle("Add notes or a tour")
        notesEditor(text: Binding(
            get: { draftNotesByPlace[place.placeKey] ?? "" },
            set: { draftNotesByPlace[place.placeKey] = $0 }
        ))
        HStack(spacing: 8) {
            let isTeaching = appNotes.placesBeingTaught.contains(place.placeKey)
            Button(isTeaching ? "Learning…" : "Teach Dottie") {
                appNotes.teach(draftNotesByPlace[place.placeKey] ?? "", placeKey: place.placeKey, appName: place.appName)
                draftNotesByPlace[place.placeKey] = ""
            }
            .buttonStyle(DSPrimaryButtonStyle(isFullWidth: false))
            .disabled(isTeaching || (draftNotesByPlace[place.placeKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .pointerCursor()
            if let status = appNotes.statusByPlace[place.placeKey] { hintText(status) }
        }
    }

    private func notesEditor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12))
            .frame(minHeight: 90, maxHeight: 220)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
    }

    private func subTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.top, 4)
    }

    private func taskRow(_ task: DottieAppTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(task.appName)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer(minLength: 8)
                Text("worked \(task.timesSucceeded) of \(task.timesRun) · \(task.steps.count) steps")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                Button("Forget") { appTasks.forget(taskID: task.id) }
                    .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
            }
            if !task.purpose.isEmpty { hintText(task.purpose) }
            hintText(task.steps.prefix(8).enumerated().map { "\($0.offset + 1). \(DottieAppTaskPlan.stepLine($0.element))" }.joined(separator: "  "))
            if let lastProblem = task.problems.last {
                hintText("Last problem: step \(lastProblem.stepNumber), \(lastProblem.whatHappened)" + (lastProblem.fix.map { ". Fixed by: \($0)" } ?? ""))
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(DS.Colors.textTertiary)
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
            .fill(DS.Colors.surface1)
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
    }
}
