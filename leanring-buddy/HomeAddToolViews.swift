//
//  HomeAddToolViews.swift
//  leanring-buddy
//
//  Home → Tools → Command-line tools: an "Add a tool" box for typing any
//  tool's name, and the list of tools Dottie installed on request, each
//  with an Uninstall button. See DottieToolInstaller.
//

import SwiftUI

/// Type a name, see what Dottie found and where it comes from, tap Install.
struct HomeAddToolCard: View {
    @ObservedObject var installer: DottieToolInstaller
    @State private var query = ""
    @State private var isSearching = false
    @State private var resolution: DottieToolResolution?

    var body: some View {
        HomeCard(title: "Add a tool") {
            HomeHint("Type any command-line tool's name and Dottie finds it on Homebrew, npm, PyPI or crates.io. You can also just ask her: \u{201C}install ffmpeg\u{201D}.")
            HStack {
                TextField("Like ffmpeg, vercel or yt-dlp", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(find)
                if isSearching {
                    ProgressView().controlSize(.small)
                }
                Button("Find", action: find)
                    .controlSize(.small)
                    .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let resolution {
                resultView(resolution)
            }
        }
    }

    private func find() {
        let typedName = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typedName.isEmpty, !isSearching else { return }
        isSearching = true
        resolution = nil
        Task {
            let foundResolution = await DottieToolResolver.resolve(typedName)
            resolution = foundResolution
            isSearching = false
        }
    }

    @ViewBuilder
    private func resultView(_ resolution: DottieToolResolution) -> some View {
        switch resolution {
        case .found(let plan):
            foundRow(plan)
        case .notFound(let request, let suggestions):
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't find a tool called \u{201C}\(request)\u{201D}. Try its exact name, or ask Dottie to find one that does what you need.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                if !suggestions.isEmpty {
                    HStack(spacing: 6) {
                        Text("Close names:")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                query = suggestion
                                find()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func foundRow(_ plan: DottieToolPlan) -> some View {
        let package = plan.package
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(package.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("from \(package.source.displayName)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.accentText)
                    }
                    if !package.summary.isEmpty {
                        Text(package.summary)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(package.installCommandText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 4)
                installButton(plan)
            }
            if let prerequisite = plan.prerequisite, !plan.isAlreadyInstalled {
                HomeHint("Needs \(prerequisite.spokenDescription). Dottie does that too when you tap Install.")
            }
            if !plan.alsoFoundOn.isEmpty {
                HomeHint("Something with this name is also on \(plan.alsoFoundOn.map(\.displayName).joined(separator: ", ")). Ask Dottie if you meant that one.")
            }
            if let homepage = package.homepage, let homepageURL = URL(string: homepage) {
                Link("About \(package.title)", destination: homepageURL)
                    .font(.system(size: 11))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    @ViewBuilder
    private func installButton(_ plan: DottieToolPlan) -> some View {
        if installer.isInstalling(plan.package) {
            ProgressView().controlSize(.small)
        } else if plan.isAlreadyInstalled || installer.installedTools.contains(where: { $0.id == plan.package.id }) {
            Label("Installed", systemImage: "checkmark")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.success)
        } else {
            // Tapping Install is the user's OK.
            Button("Install") {
                Task { _ = await installer.installAndAnnounce(plan) }
            }
            .controlSize(.small)
        }
    }
}

/// Tools Dottie installed because someone asked, and installs in progress.
struct HomeAddedToolsCard: View {
    @ObservedObject var installer: DottieToolInstaller
    @State private var toolBeingRemoved: DottieInstalledTool?

    var body: some View {
        if !installer.installedTools.isEmpty || !installer.jobs.isEmpty {
            HomeCard(title: "Added by you") {
                if let message = installer.lastMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(installer.jobs) { job in
                    jobRow(job)
                }
                ForEach(installer.installedTools) { tool in
                    toolRow(tool)
                }
            }
            .alert(
                "Uninstall \(toolBeingRemoved?.package.title ?? "this tool")?",
                isPresented: Binding(get: { toolBeingRemoved != nil }, set: { if !$0 { toolBeingRemoved = nil } })
            ) {
                Button("Uninstall", role: .destructive) {
                    if let tool = toolBeingRemoved {
                        Task { _ = await installer.uninstall(tool) }
                    }
                    toolBeingRemoved = nil
                }
                Button("Cancel", role: .cancel) { toolBeingRemoved = nil }
            } message: {
                Text("Dottie removes it from this Mac, and helpers stop using it.")
            }
        }
    }

    private func jobRow(_ job: DottieToolInstaller.Job) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Installing \(job.package.title)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(job.progressText)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            ProgressView().controlSize(.small)
            Button("Stop") { installer.stop(jobID: job.id) }
                .controlSize(.small)
        }
    }

    private func toolRow(_ tool: DottieInstalledTool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.package.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    if !tool.commands.isEmpty {
                        Text(tool.commands.prefix(3).joined(separator: ", "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    Text("from \(tool.package.source.displayName)")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Text(tool.package.summary.isEmpty ? "Installed \(tool.installedAt.formatted(date: .abbreviated, time: .omitted))." : tool.package.summary)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
            if installer.removingToolIDs.contains(tool.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Uninstall") { toolBeingRemoved = tool }
                    .controlSize(.small)
                    .foregroundColor(DS.Colors.destructive)
            }
        }
    }
}
