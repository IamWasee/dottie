//
//  HomeBrainView.swift
//  leanring-buddy
//
//  Home → Brain: what Dottie's second brain knows (editable), the newest
//  memories, the screen journal switch, the folders the Brain agent may
//  use, the MCP servers it and the Dots can call, and a way to wipe it all.
//

import AppKit
import SwiftUI

struct HomeBrainView: View {
    @ObservedObject var brain: DottieBrain
    @State private var editedProfile = ""
    @State private var isEditingProfile = false
    @State private var editedMCPJSON = ""
    @State private var mcpMessage: String?
    @State private var isConfirmingForget = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Brain")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Everything here stays on this Mac. Dottie reads the notes in every conversation and asks the brain when she needs your files or tools.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                group(title: "What Dottie knows about you") {
                    if isEditingProfile {
                        TextEditor(text: $editedProfile)
                            .font(.system(size: 12))
                            .frame(minHeight: 160)
                            .scrollContentBackground(.hidden)
                            .background(DS.Colors.surface2)
                        HStack {
                            Spacer()
                            Button("Cancel") { isEditingProfile = false }
                            Button("Save") {
                                brain.saveProfile(editedProfile)
                                isEditingProfile = false
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    } else {
                        Text(brain.profileText.isEmpty ? "Nothing yet. Dottie writes notes here as you talk to her." : brain.profileText)
                            .font(.system(size: 12))
                            .foregroundColor(brain.profileText.isEmpty ? DS.Colors.textTertiary : DS.Colors.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            if brain.isUpdatingProfile {
                                Text("updating…")
                                    .font(.system(size: 11))
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                            Spacer()
                            Button("Edit") {
                                editedProfile = brain.profileText
                                isEditingProfile = true
                            }
                        }
                    }
                }

                group(title: "Screen journal") {
                    Toggle(isOn: Binding(
                        get: { brain.isScreenJournalEnabled },
                        set: { brain.setScreenJournalEnabled($0) }
                    )) {
                        Text("Note what I'm doing every couple of minutes")
                            .font(.system(size: 13))
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                    .toggleStyle(.switch)
                    hint("Takes a quick look at your screen while you're using the Mac and writes one line, like \u{201C}editing the intro in Premiere\u{201D}. The screenshot is thrown away. A small green light shows in the notch while it's on.")
                }

                group(title: "Folders the brain can use") {
                    if brain.folderPaths.isEmpty {
                        hint("None yet. Add the folders you want Dottie's brain to read and work in, like Documents or a projects folder.")
                    }
                    ForEach(brain.folderPaths, id: \.self) { folderPath in
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(DS.Colors.textTertiary)
                            Text((folderPath as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 12))
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                brain.removeFolder(folderPath)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Stop sharing this folder")
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Add folder…") { chooseFolder() }
                    }
                }

                group(title: "Tools (MCP servers)") {
                    hint("Paste MCP servers in the same JSON Claude and Gemini CLI use. The brain and every Dot can call them on their next task.")
                    TextEditor(text: $editedMCPJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 110)
                        .scrollContentBackground(.hidden)
                        .background(DS.Colors.surface2)
                    HStack {
                        if let mcpMessage {
                            Text(mcpMessage)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        Spacer()
                        Button("Save") {
                            mcpMessage = brain.saveMCPServersJSON(editedMCPJSON) ?? "Saved."
                        }
                    }
                }

                group(title: "Latest memories") {
                    if brain.recentMemories.isEmpty {
                        hint("Nothing remembered yet.")
                    }
                    ForEach(brain.recentMemories.suffix(25).reversed()) { memory in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(memory.kind.rawValue) · \(memory.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(DS.Colors.textTertiary)
                            Text(memory.text)
                                .font(.system(size: 12))
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Forget everything…") { isConfirmingForget = true }
                }
            }
            .padding(20)
        }
        .onAppear {
            editedMCPJSON = brain.mcpServersJSON.isEmpty
                ? "{\n  \"mcpServers\": {\n  }\n}"
                : brain.mcpServersJSON
        }
        .alert("Forget everything?", isPresented: $isConfirmingForget) {
            Button("Forget", role: .destructive) { brain.forgetEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every memory and the notes about you. Shared folders and tools stay.")
        }
    }

    private func chooseFolder() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = true
        openPanel.prompt = "Share with Brain"
        guard openPanel.runModal() == .OK else { return }
        for folderURL in openPanel.urls {
            brain.addFolder(folderURL)
        }
    }

    private func group<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
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
    }

    private func hint(_ hintText: String) -> some View {
        Text(hintText)
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
