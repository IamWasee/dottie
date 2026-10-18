//
//  DottieCustomPersonality.swift
//  leanring-buddy
//
//  "Make your own" personality: the user names it, describes it in a line
//  ("grumpy pirate who loves cats") and adds catchphrases if they like.
//  "Write it for me" turns the line into a fuller personality with one
//  quick Gemini call, which the user can still edit. Each one is picked in
//  Settings → Voice like the built-in ones (DottiePersonality.custom) and
//  applies to the voice right away.
//
//  Saved in UserDefaults ("dottieCustomPersonalities").
//

import Combine
import Foundation
import SwiftUI

struct DottieCustomPersonality: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var description: String
    var catchphrases: [String]
    /// The fuller personality, written by "Write it for me" or the user.
    var writtenStyle: String

    var summary: String {
        description.isEmpty ? "One you made yourself." : description
    }

    /// The "how you talk" part of the voice prompt.
    var promptSection: String {
        var lines = ["how you talk (\(name), a personality the user made for you):"]
        if !description.isEmpty {
            lines.append("- the user described it as: \"\(description)\". play that character fully and with gusto, as dottie.")
        }
        let trimmedStyle = writtenStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStyle.isEmpty {
            lines.append(trimmedStyle)
        }
        let phrases = catchphrases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !phrases.isEmpty {
            lines.append("- catchphrases to drop in now and then (not every turn): " + phrases.map { "\"\($0)\"" }.joined(separator: ", "))
        }
        lines.append("- whatever the character, the answer still comes first and stays short, you're never mean to the user, and you drop the act if they're stressed or it's serious.")
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class DottieCustomPersonalities: ObservableObject {
    static let shared = DottieCustomPersonalities()

    @Published private(set) var personalities: [DottieCustomPersonality] = []
    @Published private(set) var activeID: UUID?

    nonisolated private static let defaultsKey = "dottieCustomPersonalities"
    nonisolated private static let activeDefaultsKey = "dottieActiveCustomPersonality"
    private static let writerModel = "gemini-3.5-flash-lite"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([DottieCustomPersonality].self, from: data) {
            personalities = saved
        }
        activeID = UserDefaults.standard.string(forKey: Self.activeDefaultsKey).flatMap(UUID.init(uuidString:))
        if activeID == nil || !personalities.contains(where: { $0.id == activeID }) {
            activeID = personalities.first?.id
        }
    }

    var active: DottieCustomPersonality? {
        personalities.first { $0.id == activeID } ?? personalities.first
    }

    /// The active one, read straight from what's saved, so the voice
    /// prompt (DottiePersonality) can read it from any thread.
    nonisolated static func savedActive() -> DottieCustomPersonality? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode([DottieCustomPersonality].self, from: data) else { return nil }
        let savedActiveID = UserDefaults.standard.string(forKey: activeDefaultsKey).flatMap(UUID.init(uuidString:))
        return saved.first { $0.id == savedActiveID } ?? saved.first
    }

    func setActive(_ id: UUID) {
        activeID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.activeDefaultsKey)
    }

    /// Adds or updates one and makes it the active custom personality.
    func save(_ personality: DottieCustomPersonality) {
        if let index = personalities.firstIndex(where: { $0.id == personality.id }) {
            personalities[index] = personality
        } else {
            personalities.append(personality)
        }
        persist()
        setActive(personality.id)
    }

    func delete(_ id: UUID) {
        personalities.removeAll { $0.id == id }
        persist()
        if activeID == id, let first = personalities.first {
            setActive(first.id)
        } else if personalities.isEmpty {
            activeID = nil
            UserDefaults.standard.removeObject(forKey: Self.activeDefaultsKey)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(personalities) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// "Write it for me": a few lines on how the character talks, from the
    /// user's one-line description. nil when Gemini didn't answer.
    static func writeStyle(name: String, description: String, catchphrases: [String]) async -> String? {
        let prompt = """
        write the speaking style for a voice companion called dottie (a tiny glowing dot who lives in the user's mac notch) playing this character:
        name: \(name)
        description: \(description)
        \(catchphrases.isEmpty ? "" : "catchphrases: " + catchphrases.joined(separator: ", "))

        write 5 to 7 short bullet lines, each starting with "- ", lowercase, second person ("you ..."): how she talks (word choice, rhythm, attitude), small habits, what she loves and grumbles about in character, and how she reacts when the user gets something done or is stuck. fun and specific, family friendly, never mean to the user. answers still come first and stay short. only the bullet lines, nothing else.
        """
        guard let answer = await DottieChat.ask(prompt, model: writerModel) else { return nil }
        let bulletLines = answer.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("- ") ? $0 : "- " + $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*• ")) }
        return bulletLines.isEmpty ? nil : bulletLines.prefix(8).joined(separator: "\n")
    }
}

// MARK: - Settings

/// Settings → Voice: the personality picker, with "Make your own".
struct DottiePersonalitySettings: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var customPersonalities = DottieCustomPersonalities.shared
    @State private var editorDraft: DottieCustomPersonality?

    private var selectionKey: Binding<String> {
        Binding(
            get: {
                if companionManager.selectedPersonality == .custom, let active = customPersonalities.active {
                    return "custom." + active.id.uuidString
                }
                let preset = companionManager.selectedPersonality == .custom ? DottiePersonality.defaultPersonality : companionManager.selectedPersonality
                return "preset." + preset.rawValue
            },
            set: { newKey in
                if newKey.hasPrefix("custom."), let id = UUID(uuidString: String(newKey.dropFirst("custom.".count))) {
                    customPersonalities.setActive(id)
                    companionManager.setSelectedPersonality(.custom)
                } else if let preset = DottiePersonality(rawValue: String(newKey.dropFirst("preset.".count))) {
                    companionManager.setSelectedPersonality(preset)
                }
            }
        )
    }

    private var isCustomSelected: Bool {
        companionManager.selectedPersonality == .custom && customPersonalities.active != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Personality")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Picker("", selection: selectionKey) {
                    ForEach(DottiePersonality.presets) { personality in
                        Text(personality.displayName).tag("preset." + personality.rawValue)
                    }
                    if !customPersonalities.personalities.isEmpty {
                        Divider()
                        ForEach(customPersonalities.personalities) { personality in
                            Text(personality.name).tag("custom." + personality.id.uuidString)
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                .font(.system(size: 12))
            }
            Text(isCustomSelected ? (customPersonalities.active?.summary ?? "") : companionManager.selectedPersonality.settingsHint)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Make your own…") {
                    editorDraft = DottieCustomPersonality(name: "", description: "", catchphrases: [], writtenStyle: "")
                }
                if isCustomSelected, let active = customPersonalities.active {
                    Button("Edit") { editorDraft = active }
                    Button("Delete", role: .destructive) {
                        customPersonalities.delete(active.id)
                        companionManager.setSelectedPersonality(customPersonalities.active == nil ? DottiePersonality.defaultPersonality : .custom)
                    }
                }
            }
            .font(.system(size: 12))
        }
        .sheet(item: $editorDraft) { draft in
            DottiePersonalityEditor(draft: draft) { saved in
                customPersonalities.save(saved)
                companionManager.setSelectedPersonality(.custom)
                editorDraft = nil
            } onCancel: {
                editorDraft = nil
            }
        }
    }
}

private struct DottiePersonalityEditor: View {
    @State var draft: DottieCustomPersonality
    let onSave: (DottieCustomPersonality) -> Void
    let onCancel: () -> Void
    @State private var catchphrasesText = ""
    @State private var isWriting = false
    @State private var writeError: String?

    init(draft: DottieCustomPersonality, onSave: @escaping (DottieCustomPersonality) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        _catchphrasesText = State(initialValue: draft.catchphrases.joined(separator: ", "))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var catchphrases: [String] {
        catchphrasesText.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.description.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make your own personality")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            field("Name") {
                TextField("Captain Whiskers", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }
            field("Describe it") {
                TextField("A grumpy pirate who loves cats", text: $draft.description, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
            field("Catchphrases (optional, comma-separated)") {
                TextField("Arr, Shiver me whiskers", text: $catchphrasesText)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("How she talks (optional)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                if isWriting {
                    ProgressView().controlSize(.small)
                }
                Button("Write it for me") { writeForMe() }
                    .disabled(isWriting || draft.description.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            TextEditor(text: $draft.writtenStyle)
                .font(.system(size: 12))
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(DS.Colors.surface2))
            Text(writeError ?? "Leave it empty and Dottie works it out from your description, or tap Write it for me and tweak it.")
                .font(.system(size: 11))
                .foregroundColor(writeError == nil ? DS.Colors.textTertiary : DS.Colors.warningText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save and use it") {
                    var saved = draft
                    saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.description = saved.description.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.catchphrases = catchphrases
                    onSave(saved)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(DS.Colors.background)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            content()
                .font(.system(size: 12))
        }
    }

    private func writeForMe() {
        isWriting = true
        writeError = nil
        let name = draft.name.isEmpty ? "Dottie" : draft.name
        let description = draft.description
        let phrases = catchphrases
        Task { @MainActor in
            let written = await DottieCustomPersonalities.writeStyle(name: name, description: description, catchphrases: phrases)
            isWriting = false
            if let written {
                draft.writtenStyle = written
            } else {
                writeError = "Couldn't reach Gemini just now. Try again in a moment, or write it yourself."
            }
        }
    }
}
