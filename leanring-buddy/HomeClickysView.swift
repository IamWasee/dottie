//
//  HomeClickysView.swift
//  leanring-buddy
//
//  The Clickys page in Home: the list of background agents on the left, and
//  the selected agent's chat on the right (its replies, the tools it ran,
//  and a box to send it more work). Shipped Clicky shows its agents the
//  same way in Home.
//

import AppKit
import SwiftUI

struct HomeClickysView: View {
    @ObservedObject var clickyRoster: ClickyRoster
    @State private var selectedAgentID: UUID?
    @State private var isCreatingAgent = false

    var body: some View {
        HStack(spacing: 0) {
            agentList
                .frame(width: 200)
            Divider().background(DS.Colors.borderSubtle)
            Group {
                if isCreatingAgent || clickyRoster.agents.isEmpty {
                    NewClickyForm(clickyRoster: clickyRoster, isCancelable: !clickyRoster.agents.isEmpty) { createdAgent in
                        isCreatingAgent = false
                        selectedAgentID = createdAgent?.id ?? selectedAgentID
                    }
                } else if let selectedAgent = selectedAgent {
                    ClickyAgentChatView(clickyRoster: clickyRoster, agent: selectedAgent)
                        .id(selectedAgent.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selectedAgentID == nil {
                selectedAgentID = clickyRoster.agents.first?.id
            }
        }
    }

    private var selectedAgent: ClickyAgent? {
        if let selectedAgentID, let matchingAgent = clickyRoster.agent(withID: selectedAgentID) {
            return matchingAgent
        }
        return clickyRoster.agents.first
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Clickys")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Button(action: { isCreatingAgent = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("New Clicky")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            Divider().background(DS.Colors.borderSubtle)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(clickyRoster.agents) { agent in
                        agentRow(agent)
                    }
                }
                .padding(8)
            }
        }
    }

    private func agentRow(_ agent: ClickyAgent) -> some View {
        let isSelected = !isCreatingAgent && selectedAgent?.id == agent.id
        return Button(action: {
            isCreatingAgent = false
            selectedAgentID = agent.id
        }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(clickyRoster.isRunning(agent) ? DS.Colors.overlayCursorBlue : DS.Colors.textTertiary.opacity(0.5))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(clickyRoster.isRunning(agent) ? "working…" : agent.lastActivityAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
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

    private let isGeminiCLIInstalled = GeminiCLIAgentRuntime.locateGeminiCLIExecutable() != nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("New Clicky")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("A Clicky works on its own in a folder on your Mac, with a shell, files and the web, and tells you in the notch when it's done. You can also just ask Clicky out loud to hand something off.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if !isGeminiCLIInstalled {
                    Text("Clickys run on Gemini CLI, which isn't installed yet. In Terminal, run `npm install -g @google/gemini-cli` (needs Node.js), then reopen this window.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.warningText)
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
    let agent: ClickyAgent
    @State private var draftMessage = ""
    @State private var isConfirmingDelete = false

    private var transcript: [ClickyAgentTranscriptItem] {
        clickyRoster.transcriptsByAgentID[agent.id] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(DS.Colors.borderSubtle)

            if transcript.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text("No work yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("Give \(agent.name) a task below.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
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
                                        : nil
                                )
                                .id(transcriptItem.id)
                            }
                            if clickyRoster.isRunning(agent) {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("working")
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
                    .onChange(of: transcript.count) { _, _ in
                        withAnimation {
                            scrollProxy.scrollTo(transcript.last?.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider().background(DS.Colors.borderSubtle)
            composer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                if !agent.purpose.isEmpty {
                    Text(agent.purpose)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
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
            .help("Delete this Clicky")
            .confirmationDialog("Delete \(agent.name)?", isPresented: $isConfirmingDelete) {
                Button("Move to Trash", role: .destructive) { clickyRoster.deleteAgent(agent) }
            } message: {
                Text("Its folder and everything it made go to the Trash.")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Give \(agent.name) a task", text: $draftMessage)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .onSubmit(sendDraft)
                .disabled(clickyRoster.isRunning(agent))

            if clickyRoster.isRunning(agent) {
                Button(action: { clickyRoster.stopAgent(agent) }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Stop")
            } else {
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
        clickyRoster.sendMessage(messageText, to: agent)
    }
}

private struct ClickyTranscriptItemView: View {
    let transcriptItem: ClickyAgentTranscriptItem
    /// Set only on an unanswered computer-use request: (isAllowed, alwaysAllow).
    var onAnswerComputerUseRequest: ((Bool, Bool) -> Void)?

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
        case .error:
            Text(transcriptItem.text)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.warningText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .computerUseRequest:
            computerUseRequestCard
        }
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
                        .help("Let Clickys click and type on your Mac without asking. You can turn this off in Settings.")
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
