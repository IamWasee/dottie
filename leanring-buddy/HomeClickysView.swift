//
//  HomeClickysView.swift
//  leanring-buddy
//
//  The Helpers page in Home, laid out like Grok Bots: a card per helper
//  (avatar, role, the step it's on right now, its latest message, which
//  engine it ran on, a box to hand it a task), teams, and each helper's chat
//  with its replies, the steps it took and its routines. The full bot view
//  is one click away in OpenMausBot ("Open in MausBot").
//

import AppKit
import SwiftUI

struct HomeClickysView: View {
    @ObservedObject var clickyRoster: ClickyRoster
    @ObservedObject private var mausBot = DottieMausBot.shared
    @State private var selectedAgentID: UUID?
    @State private var isCreatingAgent = false

    var body: some View {
        Group {
            if isCreatingAgent || clickyRoster.agents.isEmpty {
                NewClickyForm(clickyRoster: clickyRoster, isCancelable: !clickyRoster.agents.isEmpty) { createdAgent in
                    isCreatingAgent = false
                    selectedAgentID = createdAgent?.id
                }
            } else if let selectedAgent {
                ClickyAgentChatView(
                    clickyRoster: clickyRoster,
                    routineStore: clickyRoster.routineStore,
                    skillLibrary: clickyRoster.skillLibrary,
                    agent: selectedAgent,
                    onBack: { selectedAgentID = nil }
                )
                .id(selectedAgent.id)
            } else {
                HelperBotsGrid(
                    clickyRoster: clickyRoster,
                    routineStore: clickyRoster.routineStore,
                    onOpenAgent: { selectedAgentID = $0 },
                    onCreateAgent: { isCreatingAgent = true }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(clickyRoster.$agentIDRequestedInHome) { requestedAgentID in
            guard let requestedAgentID else { return }
            isCreatingAgent = false
            selectedAgentID = requestedAgentID
            clickyRoster.clearHomeRequest()
        }
    }

    private var selectedAgent: ClickyAgent? {
        guard let selectedAgentID else { return nil }
        return clickyRoster.agent(withID: selectedAgentID)
    }
}

// MARK: - Bot cards

/// Every helper as a card, like Grok Bots: who it is, what it's doing right
/// now, and a box to hand it something without opening its chat.
private struct HelperBotsGrid: View {
    @ObservedObject var clickyRoster: ClickyRoster
    @ObservedObject var routineStore: ClickyRoutineStore
    @ObservedObject private var mausBot = DottieMausBot.shared
    @ObservedObject private var claudeSignIn = DottieClaudeSignIn.shared
    let onOpenAgent: (UUID) -> Void
    let onCreateAgent: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                engineBanner

                let workingAgents = clickyRoster.agents.filter { clickyRoster.isRunning($0) }
                if !workingAgents.isEmpty {
                    section(title: "Working now") {
                        cardGrid(workingAgents)
                    }
                }

                let teams = clickyRoster.helperTeams()
                if !teams.isEmpty {
                    section(title: "Teams") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(teams.prefix(4).enumerated()), id: \.offset) { _, team in
                                teamRow(name: team.name, helperNames: team.helperNames)
                            }
                        }
                    }
                }

                section(title: "All helpers") {
                    cardGrid(clickyRoster.agents.sorted { $0.lastActivityAt > $1.lastActivityAt })
                }
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Helpers")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("They work on their own and tell you in the notch when they're done.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Button(action: onCreateAgent) {
                Label("New helper", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .pointerCursor()
        }
    }

    /// Says which engine helpers are on, and which Claude account they use.
    @ViewBuilder
    private var engineBanner: some View {
        if claudeSignIn.phase != .idle {
            DottieClaudeSignInPanel()
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(DS.Colors.accentSubtle)
                )
        } else if mausBot.preference == .claudeWithBackup && mausBot.hasLookedForMausBot && !mausBot.isSetUp {
            bannerRow(
                text: mausBot.busyText ?? "Helpers are on the free Gemini backup. Set up Claude (through the free MausBot app) to use your Claude plan instead: faster, and they can do a lot more.",
                buttonTitle: mausBot.isSettingUp || mausBot.isInstallingDesktopApp ? nil : "Set up Claude",
                action: { mausBot.setUp() }
            )
        } else if mausBot.preference == .claudeWithBackup && mausBot.isSetUp && mausBot.claudeState == .notSignedIn {
            bannerRow(
                text: "Sign in to Claude once so helpers can use your plan. Until then they use the free Gemini backup.",
                buttonTitle: "Sign in",
                action: { mausBot.openClaudeSignIn() }
            )
        } else if mausBot.preference == .claudeWithBackup, let pausedUntil = mausBot.claudePausedUntil {
            bannerRow(
                text: "\(mausBot.claudePauseReason ?? "Claude is paused"), so helpers use the free backup until \(pausedUntil.formatted(date: .omitted, time: .shortened)).",
                buttonTitle: "Try Claude now",
                action: { mausBot.resumeClaude() }
            )
        } else if mausBot.preference == .claudeWithBackup && mausBot.isSetUp && mausBot.claudeState == .ready {
            bannerRow(
                text: "Helpers use Claude: \(mausBot.claudeAccount?.summary ?? "Signed in").",
                buttonTitle: "Use a different account",
                action: { mausBot.switchClaudeAccount() }
            )
        }
    }

    private func bannerRow(text: String, buttonTitle: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.accentText)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let buttonTitle {
                Button(buttonTitle, action: action)
                    .controlSize(.small)
                    .pointerCursor()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.accentSubtle)
        )
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            content()
        }
    }

    private func cardGrid(_ gridAgents: [ClickyAgent]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(gridAgents) { agent in
                HelperBotCard(
                    clickyRoster: clickyRoster,
                    agent: agent,
                    routines: routineStore.routines(for: agent.id),
                    onOpen: { onOpenAgent(agent.id) }
                )
            }
        }
    }

    private func teamRow(name: String, helperNames: [String]) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: -6) {
                ForEach(helperNames.prefix(5), id: \.self) { helperName in
                    HelperAvatar(name: helperName, isBrain: false, size: 24)
                        .overlay(Circle().stroke(DS.Colors.surface1, lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(helperNames.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            let workingCount = helperNames.filter { helperName in
                clickyRoster.agents.contains { $0.name.caseInsensitiveCompare(helperName) == .orderedSame && clickyRoster.isRunning($0) }
            }.count
            if workingCount > 0 {
                Text("\(workingCount) working")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.accentText)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
    }
}

/// A round avatar: the helper's first letter on its own color (the Brain
/// gets a brain).
private struct HelperAvatar: View {
    let name: String
    let isBrain: Bool
    var size: CGFloat = 34

    private static let palette: [Color] = [
        DS.Colors.overlayCursorBlue, DS.Colors.floatingGradientPurple, DS.Colors.floatingGradientPink,
        DS.Colors.floatingGradientOrange, DS.Colors.success, DS.Colors.info
    ]

    var body: some View {
        let colorIndex = name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.palette.count
        ZStack {
            Circle().fill(Self.palette[colorIndex].opacity(0.85))
            Text(isBrain ? "🧠" : String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
        }
        .frame(width: size, height: size)
    }
}

/// "Claude" or "Gemini backup": which engine the helper's latest turn ran on.
private struct HelperEngineBadge: View {
    let engineName: String?

    var body: some View {
        if let engineName {
            Text(engineName == "claude" ? "Claude" : "Gemini backup")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(engineName == "claude" ? DS.Colors.accentText : DS.Colors.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(engineName == "claude" ? DS.Colors.accentSubtle : DS.Colors.surface3)
                )
        }
    }
}

private struct HelperBotCard: View {
    @ObservedObject var clickyRoster: ClickyRoster
    let agent: ClickyAgent
    let routines: [ClickyRoutine]
    let onOpen: () -> Void
    @State private var quickTask = ""
    @State private var isHovering = false

    private var isRunning: Bool { clickyRoster.isRunning(agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        HelperAvatar(name: agent.name, isBrain: agent.isBrain == true)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(agent.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(DS.Colors.textPrimary)
                                    .lineLimit(1)
                                if agent.hasUnreadReply == true {
                                    Circle()
                                        .fill(DS.Colors.overlayCursorBlue)
                                        .frame(width: 6, height: 6)
                                        .help("Something new")
                                }
                            }
                            Text(agent.isBrain == true ? "Dottie's second brain" : (agent.purpose.isEmpty ? "Helper" : agent.purpose))
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        HelperEngineBadge(engineName: agent.lastHelperEngine)
                    }

                    HStack(spacing: 6) {
                        if isRunning {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle()
                                .fill(statusDotColor)
                                .frame(width: 6, height: 6)
                        }
                        Text(clickyRoster.liveStatusLine(for: agent))
                            .font(.system(size: 12))
                            .foregroundColor(isRunning ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)

                    if !routines.isEmpty {
                        Label(routineSummary, systemImage: "clock")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            quickComposer
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(isHovering ? DS.Colors.surface2 : DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(isRunning ? DS.Colors.overlayCursorBlue.opacity(0.6) : DS.Colors.borderSubtle, lineWidth: isRunning ? 1 : 0.5)
        )
        .onHover { isHovering = $0 }
    }

    private var statusDotColor: Color {
        if clickyRoster.pendingMausBotApproval(for: agent) != nil || clickyRoster.pendingComputerUseRequest(for: agent) != nil {
            return DS.Colors.warningText
        }
        return agent.hasUnreadReply == true ? DS.Colors.overlayCursorBlue : DS.Colors.textTertiary.opacity(0.6)
    }

    private var routineSummary: String {
        let activeRoutines = routines.filter { !$0.isPaused }
        guard let nextRoutine = activeRoutines.min(by: { $0.nextRunAt < $1.nextRunAt }) else {
            return "\(routines.count) routine\(routines.count == 1 ? "" : "s"), paused"
        }
        let countText = "\(routines.count) routine\(routines.count == 1 ? "" : "s")"
        return nextRoutine.nextRunAt <= Date()
            ? "\(countText) · next run soon"
            : "\(countText) · next \(nextRoutine.nextRunAt.formatted(.relative(presentation: .named)))"
    }

    private var quickComposer: some View {
        HStack(spacing: 8) {
            TextField(isRunning ? "Line up another task" : "Ask \(agent.name)…", text: $quickTask)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .onSubmit(sendQuickTask)
            if isRunning {
                Button(action: { clickyRoster.stopAgent(agent) }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Stop")
            }
            Button(action: sendQuickTask) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(quickTask.isEmpty ? DS.Colors.textTertiary : DS.Colors.accent)
            }
            .buttonStyle(.plain)
            .pointerCursor(isEnabled: !quickTask.isEmpty)
            .disabled(quickTask.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.background.opacity(0.6))
        )
    }

    private func sendQuickTask() {
        let taskText = quickTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskText.isEmpty else { return }
        quickTask = ""
        clickyRoster.sendOrQueueMessage(taskText, to: agent)
    }
}

// MARK: - New Clicky

private struct NewClickyForm: View {
    @ObservedObject var clickyRoster: ClickyRoster
    let isCancelable: Bool
    let onFinish: (ClickyAgent?) -> Void

    @State private var agentName = ""
    @State private var agentPurpose = ""
    @State private var firstTask = ""

    private let isDotsRuntimeReady = GeminiCLIAgentRuntime.locateGeminiCLIExecutable() != nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("New helper")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("A helper works on its own in a folder on your Mac, with a shell, files and the web, and tells you in the notch when it's done. You can also just ask Dottie out loud to hand something off.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if !isDotsRuntimeReady && !DottieMausBot.shared.isSetUp {
                    Text("Dottie is still getting helpers ready (a one-time download of about 70 MB). You can make one now; its first task starts as soon as that's done.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                labeledField("Name", placeholder: "Research", text: $agentName)
                labeledField("What it's for (optional)", placeholder: "Digs into topics and writes short reports", text: $agentPurpose)
                labeledField("First task (optional)", placeholder: "Compare the three best budget mechanical keyboards", text: $firstTask)

                HStack {
                    if isCancelable {
                        Button("Cancel") { onFinish(nil) }
                            .pointerCursor()
                    }
                    Spacer()
                    Button("Create") { createAgent() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(agentName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .pointerCursor()
                }
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
        }
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

    private func createAgent() {
        let createdAgent = clickyRoster.createAgent(name: agentName, purpose: agentPurpose)
        if !firstTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clickyRoster.sendMessage(firstTask, to: createdAgent)
        }
        onFinish(createdAgent)
    }
}

// MARK: - Agent chat

private struct ClickyAgentChatView: View {
    @ObservedObject var clickyRoster: ClickyRoster
    @ObservedObject var routineStore: ClickyRoutineStore
    @ObservedObject var skillLibrary: ClickySkillLibrary
    let agent: ClickyAgent
    let onBack: () -> Void
    @ObservedObject private var mausBot = DottieMausBot.shared
    @State private var draftMessage = ""
    @State private var isConfirmingDelete = false
    /// .key while the Home window is the one the user is looking at.
    @Environment(\.controlActiveState) private var controlActiveState

    private var transcript: [ClickyAgentTranscriptItem] {
        clickyRoster.transcriptsByAgentID[agent.id] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(DS.Colors.borderSubtle)
            if !agentRoutines.isEmpty {
                routinesStrip
                Divider().background(DS.Colors.borderSubtle)
            }

            if transcript.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text("No work yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("Give \(agent.name) a task below. To repeat one on a schedule, just say how often, like \"every morning\".")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(transcript) { transcriptItem in
                                ClickyTranscriptItemView(
                                    transcriptItem: transcriptItem,
                                    onAnswerComputerUseRequest: isPendingComputerUseRequest(transcriptItem)
                                        ? { isAllowed, alwaysAllow in answerComputerUseRequest(isAllowed: isAllowed, alwaysAllow: alwaysAllow) }
                                        : nil,
                                    onOpenMausBot: { mausBot.openMausBot() }
                                )
                                .deletableRow(copyText: transcriptItem.text) {
                                    withAnimation { clickyRoster.deleteTranscriptItem(transcriptItem.id, fromAgentID: agent.id) }
                                }
                                .id(transcriptItem.id)
                            }
                            if clickyRoster.isRunning(agent) {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(clickyRoster.liveStatusLine(for: agent))
                                        .font(.system(size: 11))
                                        .foregroundColor(DS.Colors.textTertiary)
                                }
                                .id("working-indicator")
                            }
                        }
                        .padding(20)
                    }
                    .onAppear {
                        scrollProxy.scrollTo(transcript.last?.id, anchor: .bottom)
                    }
                    .onChange(of: transcript.last?.id) { _, _ in
                        withAnimation {
                            scrollProxy.scrollTo(transcript.last?.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider().background(DS.Colors.borderSubtle)
            composer
        }
        // Seeing the chat clears its "something new" mark, including a reply
        // that lands while the chat is on screen.
        .onAppear(perform: markReadIfVisible)
        .onChange(of: controlActiveState) { _, _ in markReadIfVisible() }
        .onChange(of: clickyRoster.agent(withID: agent.id)?.hasUnreadReply) { _, _ in markReadIfVisible() }
    }

    private func markReadIfVisible() {
        guard controlActiveState == .key else { return }
        clickyRoster.markRead(agentID: agent.id)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Colors.textSecondary)
            .pointerCursor()
            .help("All helpers")

            HelperAvatar(name: agent.name, isBrain: agent.isBrain == true, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    HelperEngineBadge(engineName: agent.lastHelperEngine)
                }
                if !agent.purpose.isEmpty {
                    Text(agent.purpose)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if agent.mausBotID != nil && mausBot.isSetUp {
                Button(action: { mausBot.openMausBot() }) {
                    Label("Open in MausBot", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.textSecondary)
                .pointerCursor()
                .help("See this helper's full view in MausBot")
            }
            skillsMenu

            Button(action: { clickyRoster.revealWorkspaceInFinder(for: agent) }) {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Colors.textSecondary)
            .pointerCursor()
            .help("Show its output folder in Finder")

            Button(action: { isConfirmingDelete = true }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Colors.textSecondary)
            .pointerCursor()
            .help("Delete this helper")
            .confirmationDialog("Delete \(agent.name)?", isPresented: $isConfirmingDelete) {
                Button("Move to Trash", role: .destructive) { clickyRoster.deleteAgent(agent) }
            } message: {
                Text("Its folder and everything it made go to the Trash. Its bot in MausBot stays until you remove it there.")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var agentRoutines: [ClickyRoutine] {
        routineStore.routines(for: agent.id)
    }

    /// Turns library skills on and off for this Clicky.
    private var skillsMenu: some View {
        Menu {
            if skillLibrary.skills.isEmpty {
                Text("No skills yet. Add some on the Skills page.")
            } else {
                ForEach(skillLibrary.skills) { skill in
                    Toggle(skill.name, isOn: Binding(
                        get: { clickyRoster.isSkill(skill.name, enabledFor: agent) },
                        set: { clickyRoster.setSkill(skill.name, enabled: $0, forAgentID: agent.id) }
                    ))
                }
            }
        } label: {
            Image(systemName: "sparkles")
                .foregroundColor(DS.Colors.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
        .help("Skills this helper uses")
        .onAppear { skillLibrary.reload() }
    }

    /// This Clicky's routines, with run now, pause and delete.
    private var routinesStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ROUTINES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            ForEach(agentRoutines) { routine in
                HStack(spacing: 8) {
                    Image(systemName: routine.isPaused ? "pause.circle" : "clock")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(routine.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(routineScheduleText(routine))
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Menu {
                        Button("Run now") { clickyRoster.runRoutine(routine) }
                            .disabled(clickyRoster.isRunning(agent))
                        Button(routine.isPaused ? "Resume routine" : "Pause routine") {
                            routineStore.setPaused(!routine.isPaused, routineID: routine.id)
                        }
                        Divider()
                        Button("Delete routine", role: .destructive) {
                            routineStore.deleteRoutine(routineID: routine.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .pointerCursor()
                }
                .help(routine.task)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func routineScheduleText(_ routine: ClickyRoutine) -> String {
        if routine.isPaused {
            return "\(routine.cadenceDescription) · paused"
        }
        if routine.nextRunAt <= Date() {
            return "\(routine.cadenceDescription) · next run soon"
        }
        return "\(routine.cadenceDescription) · next \(routine.nextRunAt.formatted(.relative(presentation: .named)))"
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(clickyRoster.isRunning(agent) ? "Line up another task for \(agent.name)" : "Give \(agent.name) a task", text: $draftMessage)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .onSubmit(sendDraft)

            if clickyRoster.isRunning(agent) {
                Button(action: { clickyRoster.stopAgent(agent) }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Stop")
            }
            if !draftMessage.isEmpty || !clickyRoster.isRunning(agent) {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(draftMessage.isEmpty ? DS.Colors.textTertiary : DS.Colors.accent)
                }
                .buttonStyle(.plain)
                .pointerCursor(isEnabled: !draftMessage.isEmpty)
                .disabled(draftMessage.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func isPendingComputerUseRequest(_ transcriptItem: ClickyAgentTranscriptItem) -> Bool {
        transcriptItem.kind == .computerUseRequest
            && transcriptItem.id == transcript.last?.id
            && clickyRoster.pendingComputerUseRequest(for: agent) != nil
    }

    private func answerComputerUseRequest(isAllowed: Bool, alwaysAllow: Bool) {
        if isAllowed {
            clickyRoster.approveComputerUse(for: agent, alwaysAllow: alwaysAllow)
        } else {
            clickyRoster.declineComputerUse(for: agent)
        }
    }

    private func sendDraft() {
        let messageText = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageText.isEmpty else { return }
        draftMessage = ""
        clickyRoster.sendOrQueueMessage(messageText, to: agent)
    }
}

private struct ClickyTranscriptItemView: View {
    let transcriptItem: ClickyAgentTranscriptItem
    /// Set only on an unanswered computer-use request: (isAllowed, alwaysAllow).
    var onAnswerComputerUseRequest: ((Bool, Bool) -> Void)?
    var onOpenMausBot: (() -> Void)?

    var body: some View {
        switch transcriptItem.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(transcriptItem.text)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(DS.Colors.helpChatUserBubble)
                    )
            }
        case .assistant:
            Text(transcriptItem.text)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            HStack(spacing: 6) {
                Image(systemName: toolStatusSymbolName)
                    .font(.system(size: 10))
                    .foregroundColor(transcriptItem.toolSucceeded == false ? DS.Colors.warningText : DS.Colors.textTertiary)
                Text(transcriptItem.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .status:
            Text(transcriptItem.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        case .routineRun:
            HStack(spacing: 8) {
                Rectangle()
                    .fill(DS.Colors.borderSubtle)
                    .frame(height: 0.5)
                Label(transcriptItem.text, systemImage: "clock")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize()
                Rectangle()
                    .fill(DS.Colors.borderSubtle)
                    .frame(height: 0.5)
            }
            .padding(.vertical, 4)
        case .error:
            Text(transcriptItem.text)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.warningText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .computerUseRequest:
            computerUseRequestCard
        case .needsApproval:
            needsApprovalCard
        }
    }

    /// A Claude helper stopped for an approval card or a question in MausBot.
    private var needsApprovalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs your OK in MausBot", systemImage: "hand.raised")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.warningText)
            Text(transcriptItem.text)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Answer it in MausBot. The reply shows up here when it's done.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
            if let onOpenMausBot {
                Button("Open MausBot", action: onOpenMausBot)
                    .font(.system(size: 12))
                    .keyboardShortcut(.defaultAction)
                    .pointerCursor()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.warningText.opacity(0.5), lineWidth: 0.5)
        )
    }

    private var computerUseRequestCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Wants to use your Mac", systemImage: "cursorarrow.click.2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text(transcriptItem.text)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let onAnswerComputerUseRequest {
                HStack(spacing: 8) {
                    Button("Allow") { onAnswerComputerUseRequest(true, false) }
                        .keyboardShortcut(.defaultAction)
                        .pointerCursor()
                    Button("Always allow") { onAnswerComputerUseRequest(true, true) }
                        .pointerCursor()
                        .help("Let Dots click and type on your Mac without asking. You can turn this off in Settings.")
                    Button("Not now") { onAnswerComputerUseRequest(false, false) }
                        .pointerCursor()
                }
                .font(.system(size: 12))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private var toolStatusSymbolName: String {
        switch transcriptItem.toolSucceeded {
        case .some(true): return "checkmark"
        case .some(false): return "xmark"
        case .none: return "gearshape"
        }
    }
}
