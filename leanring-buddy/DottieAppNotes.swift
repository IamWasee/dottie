//
//  DottieAppNotes.swift
//  leanring-buddy
//
//  Teaching Dottie about an app or site by typing: a tour ("the left menu
//  has Patient, Calendar and Fees; a new patient is Patient → New/Search"),
//  tips or the steps of a job, written in Home → Admin beside everything
//  she already learned there (Wasee, 28 Nov). One text call (Claude Haiku,
//  cost category app_tasks) turns the notes into the place's card on how it
//  works and named tasks with their steps in words; the notes themselves
//  are kept too and go to the advisor, the guesser and the step model with
//  the card. Notes live in Application Support/Dottie/AppTasks/notes.json.
//

import Combine
import Foundation

/// Something the user typed about one app or site.
struct DottieAppNote: Codable, Equatable, Identifiable {
    let id: UUID
    /// The task place it's about: a site host, else an app's bundle identifier.
    let placeKey: String
    var appName: String
    var text: String
    let writtenAt: Date
    /// When the model turned it into Dottie's card and tasks (nil until then).
    var learnedAt: Date?
    /// What it learned, in a line, for the list.
    var learnedSummary: String?
}

/// One app or site Dottie knows something about, for Home → Admin.
struct DottieKnownPlace: Equatable, Identifiable {
    var id: String { placeKey }
    let placeKey: String
    var appName: String
    var pagesSeen: Int
    var taskCount: Int
    var howToCount: Int
    var noteCount: Int
    var hasCard: Bool
    var lastSeen: Date?
}

/// The pure parts: the list of places, turning a typed name into a place,
/// the teaching call's prompt and answer, and what reaches a job.
enum DottieAppNotesPlan {
    static let maximumNoteCharacters = 6000
    static let maximumNotesPerPlace = 30
    static let maximumNotesKnowledgeCharacters = 1200
    static let maximumTasksFromNotes = 8
    static let maximumStepsPerTaughtTask = 12
    static let maximumCardCharacters = 1200

    /// One app or site in app memory: a browser's pages split by site.
    struct MemoryPlace: Equatable {
        let placeKey: String
        let appName: String
        let pagesSeen: Int
        let lastSeen: Date?
    }

    /// The places one app's memory file covers: the app itself, and each
    /// site seen in it when it's a browser.
    static func memoryPlaces(bundleIdentifier: String, appName: String, pages: [DottieAppPage]) -> [MemoryPlace] {
        var pagesByPlace: [String: [DottieAppPage]] = [:]
        for page in pages {
            pagesByPlace[placeKey(ofPageKey: page.key, bundleIdentifier: bundleIdentifier), default: []].append(page)
        }
        return pagesByPlace.map { placeKey, placePages in
            MemoryPlace(placeKey: placeKey, appName: placeKey == bundleIdentifier.lowercased() ? appName : placeKey,
                        pagesSeen: placePages.count, lastSeen: placePages.map(\.lastSeen).max())
        }
    }

    /// The place a remembered page belongs to: its site in a browser, else the app.
    static func placeKey(ofPageKey pageKey: String, bundleIdentifier: String) -> String {
        let keyParts = pageKey.components(separatedBy: "|")
        let siteHost = keyParts.count >= 2 ? keyParts[1] : ""
        return DottieAppTaskPlan.placeKey(siteHost: siteHost.isEmpty ? nil : siteHost, bundleIdentifier: bundleIdentifier)
    }

    // MARK: Forgetting a place (Home → Admin's Forget)

    /// Tasks without the place: one done only there is dropped, one also
    /// done elsewhere keeps its other places.
    static func tasksAfterForgetting(_ tasks: [DottieAppTask], placeKey: String) -> [DottieAppTask] {
        let forgottenKey = placeKey.lowercased()
        return tasks.compactMap { task in
            let taskPlaces = task.places.isEmpty ? [task.appName.lowercased()] : task.places.map { $0.lowercased() }
            guard taskPlaces.contains(forgottenKey) else { return task }
            let remainingPlaces = task.places.filter { $0.lowercased() != forgottenKey }
            guard !remainingPlaces.isEmpty else { return nil }
            var keptTask = task
            keptTask.places = remainingPlaces
            return keptTask
        }
    }

    /// Watched how-tos without the place, the same way (how-tos with no
    /// places saved are about no place and stay).
    static func howTosAfterForgetting(_ howTos: [DottieWatchedHowTo], placeKey: String) -> [DottieWatchedHowTo] {
        let forgottenKey = placeKey.lowercased()
        return howTos.compactMap { howTo in
            guard let howToPlaces = howTo.places, howToPlaces.contains(where: { $0.lowercased() == forgottenKey }) else { return howTo }
            let remainingPlaces = howToPlaces.filter { $0.lowercased() != forgottenKey }
            guard !remainingPlaces.isEmpty else { return nil }
            var keptHowTo = howTo
            keptHowTo.places = remainingPlaces
            return keptHowTo
        }
    }

    /// One app's remembered pages without the place's.
    static func pagesAfterForgetting(_ pages: [String: DottieAppPage], bundleIdentifier: String, placeKey: String) -> [String: DottieAppPage] {
        let forgottenKey = placeKey.lowercased()
        return pages.filter { pageKey, _ in self.placeKey(ofPageKey: pageKey, bundleIdentifier: bundleIdentifier) != forgottenKey }
    }

    static func notesAfterForgetting(_ notes: [DottieAppNote], placeKey: String) -> [DottieAppNote] {
        notes.filter { $0.placeKey.lowercased() != placeKey.lowercased() }
    }

    /// Every app and site Dottie learned anything about, newest first.
    static func knownPlaces(
        tasks: [DottieAppTask], howTos: [DottieWatchedHowTo], memoryPlaces: [MemoryPlace],
        notes: [DottieAppNote], cardPlaceKeys: Set<String>
    ) -> [DottieKnownPlace] {
        var placesByKey: [String: DottieKnownPlace] = [:]
        func update(_ placeKey: String, appName: String, change: (inout DottieKnownPlace) -> Void) {
            let key = placeKey.lowercased()
            var place = placesByKey[key] ?? DottieKnownPlace(placeKey: key, appName: appName, pagesSeen: 0, taskCount: 0,
                                                              howToCount: 0, noteCount: 0, hasCard: false, lastSeen: nil)
            change(&place)
            placesByKey[key] = place
        }
        func later(_ first: Date?, _ second: Date?) -> Date? {
            guard let first else { return second }
            guard let second else { return first }
            return max(first, second)
        }
        for memoryPlace in memoryPlaces {
            update(memoryPlace.placeKey, appName: memoryPlace.appName) { place in
                place.pagesSeen += memoryPlace.pagesSeen
                place.lastSeen = later(place.lastSeen, memoryPlace.lastSeen)
            }
        }
        for task in tasks {
            let taskPlaces = task.places.isEmpty ? [task.appName] : task.places
            for placeKey in taskPlaces {
                update(placeKey, appName: task.appName) { place in
                    place.taskCount += 1
                    place.lastSeen = later(place.lastSeen, task.lastUsed)
                }
            }
        }
        for howTo in howTos {
            for placeKey in howTo.places ?? [] {
                update(placeKey, appName: howTo.appName) { place in
                    place.howToCount += 1
                    place.lastSeen = later(place.lastSeen, howTo.learnedAt)
                }
            }
        }
        for note in notes {
            update(note.placeKey, appName: note.appName) { place in
                place.noteCount += 1
                place.lastSeen = later(place.lastSeen, note.writtenAt)
            }
        }
        for placeKey in cardPlaceKeys where placesByKey[placeKey.lowercased()] != nil {
            placesByKey[placeKey.lowercased()]?.hasCard = true
        }
        return placesByKey.values.sorted { first, second in
            if first.lastSeen != second.lastSeen { return (first.lastSeen ?? .distantPast) > (second.lastSeen ?? .distantPast) }
            return first.appName.localizedCaseInsensitiveCompare(second.appName) == .orderedAscending
        }
    }

    /// The place a typed name means: a known app or site by name, else a web
    /// address ("localhost:8300/openemr", "https://www.notion.so" → its host).
    /// Nil when it's neither (the store then looks for an installed app).
    static func placeKey(forTypedName typedName: String, knownPlaces: [DottieKnownPlace]) -> (placeKey: String, appName: String)? {
        let wantedName = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wantedName.isEmpty else { return nil }
        if let knownPlace = knownPlaces.first(where: {
            $0.appName.caseInsensitiveCompare(wantedName) == .orderedSame || $0.placeKey.caseInsensitiveCompare(wantedName) == .orderedSame
        }) {
            return (knownPlace.placeKey, knownPlace.appName)
        }
        let lowercasedName = wantedName.lowercased()
        let looksLikeAddress = !lowercasedName.contains(" ")
            && (lowercasedName.contains(".") || lowercasedName.hasPrefix("localhost") || lowercasedName.contains("://"))
        guard looksLikeAddress else { return nil }
        let withScheme = lowercasedName.contains("://") ? lowercasedName : "http://" + lowercasedName
        guard let host = URLComponents(string: withScheme)?.host, !host.isEmpty else { return nil }
        let siteHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return (siteHost, siteHost)
    }

    /// The teaching call's prompt.
    static func teachingPrompt(appName: String, noteText: String, existingCard: String?, knownTaskNames: [String]) -> String {
        let cardLine = existingCard.map { "Dottie's card on it now:\n\($0)" } ?? "Dottie has no card on it yet."
        let taskLine = knownTaskNames.isEmpty ? "No tasks known there yet." : "Tasks she knows there: " + knownTaskNames.prefix(20).joined(separator: "; ")
        return """
        The user is teaching Dottie, an assistant that uses apps by clicking, typing and pressing keys, about \(appName). \
        Their notes (a tour, tips or the steps of a job, in their own words):
        <<<
        \(String(noteText.prefix(maximumNoteCharacters)))
        >>>
        \(cardLine)
        \(taskLine)
        Answer with JSON only:
        {"card":"how \(appName) works for Dottie: what it's for, its pages or areas and how to reach each, where things are, \
        at most 150 words in plain short lines, keeping what the card says now unless the notes change it",\
        "tasks":[{"name":"the job, named the way the app's users would say it","purpose":"one line",\
        "done_when":"what shows on screen when it's done","steps":["one short step in words"],\
        "requests":["a request a person would say for it"]}],"summary":"one line on what you learned"}
        Use only what the notes and the card say: never invent pages, buttons or steps. \
        Leave out passwords and private details. At most \(maximumTasksFromNotes) tasks, each at most \(maximumStepsPerTaughtTask) steps; \
        no tasks when the notes describe no job.
        """
    }

    struct TaughtTask: Equatable {
        let name: String
        let purpose: String
        let doneWhen: String
        let steps: [String]
        let requests: [String]
    }

    struct Teaching: Equatable {
        let card: String
        let tasks: [TaughtTask]
        let summary: String
    }

    /// The teaching call's answer, or nil when it isn't usable.
    static func teaching(fromAnswer answerText: String) -> Teaching? {
        guard let openingBrace = answerText.firstIndex(of: "{"), let closingBrace = answerText.lastIndex(of: "}"),
              openingBrace < closingBrace,
              let object = (try? JSONSerialization.jsonObject(with: Data(String(answerText[openingBrace...closingBrace]).utf8))) as? [String: Any]
        else { return nil }
        func text(_ value: Any?) -> String { ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func texts(_ value: Any?, limit: Int) -> [String] {
            ((value as? [Any]) ?? []).map(text).filter { !$0.isEmpty }.prefix(limit).map { $0 }
        }
        let card = String(text(object["card"]).prefix(maximumCardCharacters))
        let tasks = ((object["tasks"] as? [[String: Any]]) ?? []).compactMap { taskObject -> TaughtTask? in
            let name = String(text(taskObject["name"]).prefix(80))
            guard !name.isEmpty else { return nil }
            return TaughtTask(name: name, purpose: String(text(taskObject["purpose"]).prefix(200)),
                              doneWhen: String(text(taskObject["done_when"]).prefix(200)),
                              steps: texts(taskObject["steps"], limit: maximumStepsPerTaughtTask).map { String($0.prefix(160)) },
                              requests: texts(taskObject["requests"], limit: DottieAppTaskPlan.maximumExampleRequests))
        }.prefix(maximumTasksFromNotes).map { $0 }
        guard !card.isEmpty || !tasks.isEmpty else { return nil }
        return Teaching(card: card, tasks: tasks, summary: String(text(object["summary"]).prefix(200)))
    }

    /// A task the user explained: no steps to do again by themselves (they
    /// are words, not spots on a screen), so Jev, its advisor and the step
    /// model read them as tips until a real job records the steps.
    static func task(from taughtTask: TaughtTask, placeKey: String, appName: String, now: Date) -> DottieAppTask {
        var tips: [String] = []
        if !taughtTask.steps.isEmpty {
            tips.append("The user's steps: " + taughtTask.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " "))
        }
        return DottieAppTask(
            id: UUID(), name: taughtTask.name, purpose: taughtTask.purpose, doneWhen: taughtTask.doneWhen, tips: tips,
            appName: appName, places: [placeKey], exampleRequests: taughtTask.requests.isEmpty ? [taughtTask.name] : taughtTask.requests,
            steps: [], stepsRecordedFor: "", finalPageTitle: nil, timesRun: 0, timesSucceeded: 0, problems: [],
            createdAt: now, lastUsed: now, isNamed: true, learnedByWatching: nil, learnedFromNotes: true
        )
    }

    /// Tasks after teaching: a same-named task in the same place gets the
    /// user's steps as its tips (its recorded steps stay), others are added.
    static func tasksAfterTeaching(_ existingTasks: [DottieAppTask], adding taughtTasks: [DottieAppTask]) -> [DottieAppTask] {
        var tasks = existingTasks
        for taughtTask in taughtTasks {
            guard let sameIndex = tasks.firstIndex(where: {
                $0.name.caseInsensitiveCompare(taughtTask.name) == .orderedSame && !Set($0.places).isDisjoint(with: taughtTask.places)
            }) else {
                tasks.append(taughtTask)
                continue
            }
            var task = tasks[sameIndex]
            task.tips = task.tips.filter { !$0.hasPrefix("The user's steps: ") } + taughtTask.tips
            for request in taughtTask.exampleRequests { task.exampleRequests = DottieAppTaskPlan.keptExamples(task.exampleRequests, adding: request) }
            if !taughtTask.purpose.isEmpty { task.purpose = taughtTask.purpose }
            if !taughtTask.doneWhen.isEmpty { task.doneWhen = taughtTask.doneWhen }
            task.isNamed = true
            tasks[sameIndex] = task
        }
        return DottieAppTaskPlan.trimmed(tasks)
    }

    /// What the user typed about a place, newest last, for a job's notes.
    static func knowledgeText(appName: String, notes: [DottieAppNote]) -> String {
        guard !notes.isEmpty else { return "" }
        let joinedNotes = notes.sorted { $0.writtenAt < $1.writtenAt }.map(\.text).joined(separator: "\n")
        // The newest words matter most, so a long history keeps its end.
        let keptNotes = joinedNotes.count > maximumNotesKnowledgeCharacters
            ? "…" + String(joinedNotes.suffix(maximumNotesKnowledgeCharacters)) : joinedNotes
        return "What the user told Dottie about \(appName):\n\(keptNotes)"
    }
}

/// The store: notes on disk and the teaching call.
@MainActor
final class DottieAppNotes: ObservableObject {
    static let shared = DottieAppNotes()

    @Published private(set) var notes: [DottieAppNote] = []
    /// Places being taught right now.
    @Published private(set) var placesBeingTaught = Set<String>()
    /// The last teaching's result per place, for Home → Admin.
    @Published private(set) var statusByPlace: [String: String] = [:]
    private let fileURL: URL

    private init() {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = applicationSupportURL.appendingPathComponent("Dottie/AppTasks/notes.json")
        notes = DottieFileLoader.load([DottieAppNote].self, from: fileURL) ?? []
    }

    func notes(forPlace placeKey: String) -> [DottieAppNote] {
        notes.filter { $0.placeKey == placeKey.lowercased() }
    }

    /// The user's own words about a place, for the advisor, the guesser and the step model.
    func knowledgeText(forPlace placeKey: String) -> String {
        let placeNotes = notes(forPlace: placeKey)
        return DottieAppNotesPlan.knowledgeText(appName: placeNotes.last?.appName ?? placeKey, notes: placeNotes)
    }

    /// The place a typed name means, looking for an installed app by name
    /// when it's not a known place or a web address.
    func place(forTypedName typedName: String, knownPlaces: [DottieKnownPlace]) -> (placeKey: String, appName: String)? {
        if let place = DottieAppNotesPlan.placeKey(forTypedName: typedName, knownPlaces: knownPlaces) { return place }
        guard let installedApp = DottieInstalledApps.shared.installedApp(matchingSpokenName: typedName),
              let bundleIdentifier = Bundle(url: installedApp.url)?.bundleIdentifier else { return nil }
        return (bundleIdentifier.lowercased(), installedApp.name)
    }

    /// Keeps the notes and has the model turn them into the place's card
    /// and tasks in the background.
    func teach(_ typedText: String, placeKey givenPlaceKey: String, appName: String) {
        let noteText = String(typedText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(DottieAppNotesPlan.maximumNoteCharacters))
        let placeKey = givenPlaceKey.lowercased()
        guard !noteText.isEmpty, !placesBeingTaught.contains(placeKey) else { return }
        let note = DottieAppNote(id: UUID(), placeKey: placeKey, appName: appName, text: noteText, writtenAt: Date())
        notes.append(note)
        let placeNotes = notes(forPlace: placeKey)
        if placeNotes.count > DottieAppNotesPlan.maximumNotesPerPlace, let oldestNote = placeNotes.first {
            notes.removeAll { $0.id == oldestNote.id }
        }
        save()
        placesBeingTaught.insert(placeKey)
        statusByPlace[placeKey] = "Learning from your notes…"
        let appTasks = DottieAppTasks.shared
        let prompt = DottieAppNotesPlan.teachingPrompt(
            appName: appName, noteText: noteText, existingCard: appTasks.card(forPlace: placeKey)?.text,
            knownTaskNames: appTasks.tasks.filter { $0.places.contains(placeKey) }.map(\.name)
        )
        let requestBody: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["maxOutputTokens": 1500]
        ]
        Task { [weak self] in
            let answerText = await DottieChat.send(requestBody, timeout: 60)
            guard let self else { return }
            self.placesBeingTaught.remove(placeKey)
            guard let answerText, let teaching = DottieAppNotesPlan.teaching(fromAnswer: answerText) else {
                self.statusByPlace[placeKey] = "Your notes are saved and go to Dottie's jobs here, but they couldn't be turned into tasks this time. Try again later."
                DottieLog.notice("📝 Notes about an app were kept but couldn't be learned from this time")
                return
            }
            let taughtTasks = teaching.tasks.map { DottieAppNotesPlan.task(from: $0, placeKey: placeKey, appName: appName, now: Date()) }
            appTasks.noteTaught(placeKey: placeKey, appName: appName, card: teaching.card, tasks: taughtTasks)
            if let index = self.notes.firstIndex(where: { $0.id == note.id }) {
                self.notes[index].learnedAt = Date()
                self.notes[index].learnedSummary = teaching.summary.isEmpty ? nil : teaching.summary
                self.save()
            }
            let taskWords = taughtTasks.isEmpty ? "updated how it works" : "updated how it works and learned \(taughtTasks.count) task\(taughtTasks.count == 1 ? "" : "s")"
            self.statusByPlace[placeKey] = "Learned: \(taskWords)." + (teaching.summary.isEmpty ? "" : " \(teaching.summary)")
            DottieLog.notice("📝 Learned from the user's notes about an app (\(public: taughtTasks.count) task(s))")
        }
    }

    /// Home → Admin's Forget: everything Dottie learned about one app or
    /// site goes (pages, tasks, card, watched how-tos, notes). The skills a
    /// watch saved for the Dots stay in Home → Skills.
    func forgetEverything(aboutPlace placeKey: String) {
        notes = DottieAppNotesPlan.notesAfterForgetting(notes, placeKey: placeKey)
        statusByPlace[placeKey.lowercased()] = nil
        save()
        DottieAppTasks.shared.forget(placeKey: placeKey)
        DottieWatchAndLearn.shared.forget(placeKey: placeKey)
        DottieAppMemory.shared.forget(placeKey: placeKey)
        DottieLog.notice("📝 Forgot everything about one app or site, as the user asked")
    }

    func forget(noteID: UUID) {
        notes.removeAll { $0.id == noteID }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let fileData = try? JSONEncoder().encode(notes) else { return }
        _ = DottieFileSaver.save(fileData, to: fileURL)
    }
}
