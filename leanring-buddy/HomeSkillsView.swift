//
//  HomeSkillsView.swift
//  leanring-buddy
//
//  The Skills page in Home: the skill library on the left, and the selected
//  skill on the right with its instructions and which Clickys use it.
//  Shipped Clicky has a skills library page in Home too
//  (HomeSpaceSkillsLibrary). Skills are stored by ClickySkillLibrary.
//

import AppKit
import SwiftUI

struct HomeSkillsView: View {
    @ObservedObject var clickyRoster: ClickyRoster
    @ObservedObject var skillLibrary: ClickySkillLibrary
    @State private var selectedSkillName: String?
    @State private var isCreatingSkill = false
    @State private var importErrorMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            skillList
                .frame(width: 220)
            Divider().background(DS.Colors.borderSubtle)
            Group {
                if isCreatingSkill {
                    NewSkillForm(clickyRoster: clickyRoster, skillLibrary: skillLibrary) { createdSkill in
                        isCreatingSkill = false
                        selectedSkillName = createdSkill?.name ?? selectedSkillName
                    }
                } else if let selectedSkill {
                    SkillDetailView(clickyRoster: clickyRoster, skill: selectedSkill)
                        .id(selectedSkill.name)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            skillLibrary.reload()
        }
        .alert("Couldn't add that skill", isPresented: Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )) {
            Button("OK") { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "")
        }
    }

    private var selectedSkill: ClickySkill? {
        if let selectedSkillName, let matchingSkill = skillLibrary.skill(named: selectedSkillName) {
            return matchingSkill
        }
        return skillLibrary.skills.first
    }

    private var skillList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Skills")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Menu {
                    Button("New skill…") { isCreatingSkill = true }
                    Button("Add a skill folder…") { importSkillFolder() }
                    Divider()
                    Button("Show skills folder in Finder") { skillLibrary.revealLibraryInFinder() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .pointerCursor()
                .help("Add a skill")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            Divider().background(DS.Colors.borderSubtle)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(skillLibrary.skills) { skill in
                        skillRow(skill)
                    }
                }
                .padding(8)
            }
        }
    }

    private func skillRow(_ skill: ClickySkill) -> some View {
        let isSelected = !isCreatingSkill && selectedSkill?.name == skill.name
        let usingAgentCount = clickyRoster.agents.filter { clickyRoster.isSkill(skill.name, enabledFor: $0) }.count
        return Button(action: {
            isCreatingSkill = false
            selectedSkillName = skill.name
        }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(usingAgentCount == 0 ? "not in use" : "used by \(usingAgentCount) \(usingAgentCount == 1 ? "Dot" : "Dots")")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isSelected ? DS.Colors.accentSubtle : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No skills yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("A skill is a set of instructions a Dot follows when a task calls for it, like your report format or the steps of a weekly chore. Make one here, add a skill folder you downloaded, or tell a Dot \"remember how to do this\" and it saves one itself.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("New skill") { isCreatingSkill = true }
                .pointerCursor()
                .padding(.top, 6)
        }
        .padding(24)
    }

    private func importSkillFolder() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Add Skill"
        openPanel.message = "Choose a skill folder (one with a SKILL.md file in it), or a folder of skill folders to add them all."
        guard openPanel.runModal() == .OK, let chosenFolderURL = openPanel.url else { return }

        // A folder of skills (no SKILL.md of its own): add every skill in it.
        let isSingleSkillFolder = FileManager.default.fileExists(atPath: chosenFolderURL.appendingPathComponent("SKILL.md").path)
        if !isSingleSkillFolder {
            let folderInstallResult = skillLibrary.installSkills(fromFolder: chosenFolderURL)
            for installedSkill in folderInstallResult.installedSkills {
                clickyRoster.enableSkillForAllAgents(installedSkill.name)
            }
            if !folderInstallResult.installedSkills.isEmpty {
                ClickyAnalytics.trackSkillChanged(action: "imported")
                isCreatingSkill = false
                selectedSkillName = folderInstallResult.installedSkills.first?.name
            }
            if folderInstallResult.installedSkills.isEmpty && folderInstallResult.alreadyInstalledSkillNames.isEmpty {
                importErrorMessage = ClickySkillLibraryError.missingSkillFile.localizedDescription
            } else if !folderInstallResult.failedSkillMessages.isEmpty {
                importErrorMessage = folderInstallResult.failedSkillMessages.joined(separator: "\n")
            }
            return
        }

        do {
            let importedSkill = try skillLibrary.importSkill(fromFolder: chosenFolderURL)
            clickyRoster.enableSkillForAllAgents(importedSkill.name)
            ClickyAnalytics.trackSkillChanged(action: "imported")
            isCreatingSkill = false
            selectedSkillName = importedSkill.name
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - New skill

private struct NewSkillForm: View {
    @ObservedObject var clickyRoster: ClickyRoster
    @ObservedObject var skillLibrary: ClickySkillLibrary
    let onFinish: (ClickySkill?) -> Void

    @State private var skillDisplayName = ""
    @State private var skillDescription = ""
    @State private var skillInstructions = ""
    @State private var isEnabledForAllAgents = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("New skill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Dots see each skill's name and when to use it, and read the instructions only when a task calls for them.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                labeledField("Name", placeholder: "Weekly report", text: $skillDisplayName)
                labeledField("When to use it", placeholder: "When the user asks for their weekly report", text: $skillDescription)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Instructions")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                    TextEditor(text: $skillInstructions)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 180)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.surface2)
                        )
                }

                Toggle("Turn on for every Dot", isOn: $isEnabledForAllAgents)
                    .font(.system(size: 12))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.warningText)
                }

                HStack {
                    Button("Cancel") { onFinish(nil) }
                        .pointerCursor()
                    Spacer()
                    Button("Save") { saveSkill() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                        .pointerCursor()
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private var canSave: Bool {
        !ClickySkillLibrary.skillName(from: skillDisplayName).isEmpty
            && !skillDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !skillInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func labeledField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
        }
    }

    private func saveSkill() {
        do {
            let createdSkill = try skillLibrary.createSkill(
                displayName: skillDisplayName,
                description: skillDescription,
                instructions: skillInstructions
            )
            if isEnabledForAllAgents {
                clickyRoster.enableSkillForAllAgents(createdSkill.name)
            }
            ClickyAnalytics.trackSkillChanged(action: "created")
            onFinish(createdSkill)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Skill detail

private struct SkillDetailView: View {
    @ObservedObject var clickyRoster: ClickyRoster
    let skill: ClickySkill
    @State private var skillFileText = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(DS.Colors.borderSubtle)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.system(size: 13))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    agentToggles
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Instructions")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                        Text(skillFileText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(DS.Colors.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                    .fill(DS.Colors.surface1)
                            )
                    }
                }
                .padding(20)
            }
        }
        .onAppear {
            skillFileText = (try? String(contentsOf: skill.skillFileURL, encoding: .utf8)) ?? ""
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(skill.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
            Button(action: { clickyRoster.skillLibrary.revealInFinder(skill) }) {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Colors.textSecondary)
            .pointerCursor()
            .help("Show in Finder to edit it")

            Button(action: { isConfirmingDelete = true }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Colors.textSecondary)
            .pointerCursor()
            .help("Delete this skill")
            .confirmationDialog("Delete \(skill.name)?", isPresented: $isConfirmingDelete) {
                Button("Move to Trash", role: .destructive) { clickyRoster.deleteSkill(skill) }
            } message: {
                Text("Its folder goes to the Trash and no Dot will use it.")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var agentToggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Used by")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            if clickyRoster.agents.isEmpty {
                Text("No Dots yet. New Dots start with every skill turned on.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            } else {
                ForEach(clickyRoster.agents) { agent in
                    Toggle(agent.name, isOn: Binding(
                        get: { clickyRoster.isSkill(skill.name, enabledFor: agent) },
                        set: { clickyRoster.setSkill(skill.name, enabled: $0, forAgentID: agent.id) }
                    ))
                    .font(.system(size: 12))
                    .toggleStyle(.checkbox)
                }
            }
        }
    }
}
