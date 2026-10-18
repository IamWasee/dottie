//
//  HomeToolsView.swift
//  leanring-buddy
//
//  Home → Tools: connect apps (MCP servers) Dottie and her helpers can use,
//  and install handy command-line tools. See DottieToolsStore and
//  DottieCLITools.
//

import AppKit
import SwiftUI

struct HomeToolsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case apps = "Connected apps"
        case commandLine = "Command-line tools"
        var id: String { rawValue }
    }

    @ObservedObject private var store = DottieToolsStore.shared
    @ObservedObject private var cliTools = DottieCLIToolsManager.shared
    @State private var selectedTab: Tab = .apps

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tools")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Give Dottie and her helpers more to work with: connect your apps (\u{201C}add a page to my Notion\u{201D}, \u{201C}what's new in Linear?\u{201D}) and install command-line tools they can use.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)

                switch selectedTab {
                case .apps:
                    HomeConnectedAppsSection(store: store, cliTools: cliTools)
                case .commandLine:
                    HomeCommandLineToolsSection(cliTools: cliTools)
                }
            }
            .padding(24)
        }
        .task {
            await cliTools.refresh()
            store.refreshStatuses()
        }
    }
}

// MARK: - Connected apps

private struct HomeConnectedAppsSection: View {
    @ObservedObject var store: DottieToolsStore
    @ObservedObject var cliTools: DottieCLIToolsManager

    @State private var expandedServer: String?
    @State private var presetBeingAdded: DottieMCPPreset?
    @State private var catalogSearch = ""
    @State private var customName = ""
    @State private var customTarget = ""
    @State private var customSettings = ""
    @State private var pastedJSON = ""
    @State private var isShowingPaste = false
    @State private var customProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let message = store.message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            yourAppsCard
            catalogCard
            customCard
        }
        .sheet(item: $presetBeingAdded) { preset in
            HomeAddPresetSheet(preset: preset, store: store) { presetBeingAdded = nil }
        }
    }

    // MARK: Your apps

    private var yourAppsCard: some View {
        HomeCard(title: "Your apps") {
            if store.serverNames.isEmpty {
                HomeHint("Nothing connected yet. Pick one below, it takes a click.")
            }
            ForEach(store.serverNames, id: \.self) { serverName in
                VStack(alignment: .leading, spacing: 8) {
                    serverRow(serverName)
                    if expandedServer == serverName {
                        serverDetails(serverName)
                    }
                }
                if serverName != store.serverNames.last {
                    Divider().background(DS.Colors.borderSubtle)
                }
            }
        }
    }

    private func serverRow(_ serverName: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: store.preset(for: serverName)?.symbolName ?? "puzzlepiece.extension")
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.title(for: serverName))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                HStack(spacing: 5) {
                    Circle().fill(statusColor(for: serverName)).frame(width: 6, height: 6)
                    Text(statusText(for: serverName))
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            statusAction(for: serverName)
            Toggle("", isOn: Binding(
                get: { store.isEnabled(serverName) },
                set: { store.setEnabled($0, for: serverName) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            Image(systemName: expandedServer == serverName ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if expandedServer == serverName {
                expandedServer = nil
            } else {
                expandedServer = serverName
                if store.status(for: serverName) == .ready {
                    store.connectInBackground(serverName)
                }
            }
        }
        .pointerCursor()
    }

    @ViewBuilder
    private func statusAction(for serverName: String) -> some View {
        switch store.status(for: serverName) {
        case .needsProgram(let command) where command == "uvx" || command == "uv":
            Button(cliTools.installProgress["uv"] != nil ? "Installing…" : "Install uv") {
                Task {
                    store.message = await cliTools.installUV()
                    store.refreshStatuses()
                    store.connectInBackground(serverName)
                }
            }
            .controlSize(.small)
            .disabled(cliTools.installProgress["uv"] != nil)
        case .needsKey:
            Button("Add key") { expandedServer = serverName }
                .controlSize(.small)
        case .failed:
            Button("Try again") { store.connectInBackground(serverName) }
                .controlSize(.small)
        case .starting:
            ProgressView().controlSize(.small)
        default:
            EmptyView()
        }
    }

    private func serverDetails(_ serverName: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary = store.preset(for: serverName)?.summary {
                HomeHint(summary)
            }
            let keyNames = store.keyNames(for: serverName)
            if !keyNames.isEmpty {
                HomeServerKeysEditor(serverName: serverName, keyNames: keyNames, store: store, keyLink: store.preset(for: serverName)?.keyLink)
            }
            if let tools = store.toolsByServer[serverName], !tools.isEmpty {
                Text("\(tools.count) tools")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tools) { tool in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tool.name)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(DS.Colors.textPrimary)
                            if !tool.description.isEmpty {
                                Text(tool.description)
                                    .font(.system(size: 11))
                                    .foregroundColor(DS.Colors.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            } else if store.status(for: serverName) == .starting {
                HomeHint("Starting it up. The first time can take a minute while it downloads.")
            }
            HStack {
                if let config = store.config(for: serverName) {
                    Text(config.command.map { ([$0] + config.args).joined(separator: " ") } ?? config.url ?? "")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Remove") {
                    expandedServer = nil
                    store.remove(serverName)
                }
                .controlSize(.small)
                .foregroundColor(DS.Colors.destructive)
            }
        }
        .padding(.leading, 32)
    }

    private func statusText(for serverName: String) -> String {
        let toolCount = store.toolsByServer[serverName]?.count
        let toolsText = toolCount.map { " · \($0) tool\($0 == 1 ? "" : "s")" } ?? ""
        switch store.status(for: serverName) {
        case .off: return "Off"
        case .ready: return (toolCount == nil ? "Ready, starts when needed" : "Ready") + toolsText
        case .starting: return "Starting…"
        case .connected: return "Connected" + toolsText
        case .needsKey: return "Needs a key"
        case .needsProgram(let command):
            switch command {
            case "uvx", "uv": return "Needs uv (a free Python tool runner)"
            case "docker": return "Needs Docker Desktop"
            case "npx", "node": return "Needs Node.js"
            default: return "Needs \(command), which isn't on this Mac"
            }
        case .failed(let reason): return "Problem: \(reason)"
        }
    }

    private func statusColor(for serverName: String) -> Color {
        switch store.status(for: serverName) {
        case .connected: return DS.Colors.success
        case .ready, .starting: return DS.Colors.accentText
        case .needsKey, .needsProgram: return DS.Colors.warningText
        case .failed: return DS.Colors.destructive
        case .off: return DS.Colors.textTertiary
        }
    }

    // MARK: Catalog

    private var filteredPresets: [DottieMCPPreset] {
        let query = catalogSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return DottieMCPPresets.all }
        return DottieMCPPresets.all.filter {
            $0.title.lowercased().contains(query) || $0.summary.lowercased().contains(query) || $0.id.contains(query)
        }
    }

    private var catalogCard: some View {
        HomeCard(title: "Add an app") {
            TextField("Search apps", text: $catalogSearch)
                .textFieldStyle(.roundedBorder)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(filteredPresets) { preset in
                    presetTile(preset)
                }
            }
        }
    }

    private func presetTile(_ preset: DottieMCPPreset) -> some View {
        let isAdded = store.config(for: preset.id) != nil
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: preset.symbolName)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(preset.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    if preset.needsKey {
                        Text("needs a key")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(DS.Colors.warningText)
                    }
                }
                Text(preset.summary)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(isAdded ? "Added" : "Add") {
                if preset.fields.isEmpty {
                    store.addPreset(preset, values: [:], folders: [:])
                    expandedServer = preset.id
                } else {
                    presetBeingAdded = preset
                }
            }
            .controlSize(.small)
            .disabled(isAdded)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    // MARK: Your own

    private var customCard: some View {
        HomeCard(title: "Add your own") {
            HomeHint("Any MCP server works. Type the command that starts it (like npx -y some-mcp-server) or its web address. Keys you type here are kept in your Mac's Keychain.")
            HStack {
                TextField("Short name, like notes", text: $customName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                TextField("Command or https:// address", text: $customTarget)
                    .textFieldStyle(.roundedBorder)
            }
            Text(customTarget.hasPrefix("http") ? "Headers, one per line (Authorization: Bearer …)" : "Settings, one per line (API_KEY=…)")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
            TextEditor(text: $customSettings)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 54)
                .scrollContentBackground(.hidden)
                .background(DS.Colors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
            HStack {
                if let customProblem {
                    Text(customProblem)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warningText)
                }
                Spacer()
                Button("Add") {
                    customProblem = store.addCustom(name: customName, commandOrAddress: customTarget, settingLines: customSettings)
                    if customProblem == nil {
                        expandedServer = DottieToolsStore.cleanServerName(customName)
                        customName = ""
                        customTarget = ""
                        customSettings = ""
                    }
                }
                .controlSize(.small)
            }

            DisclosureGroup("Paste a config from Claude, Cursor or a website", isExpanded: $isShowingPaste) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $pastedJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 110)
                        .scrollContentBackground(.hidden)
                        .background(DS.Colors.surface2)
                        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
                    HStack {
                        Spacer()
                        Button("Add from config") {
                            customProblem = store.importJSON(pastedJSON)
                            if customProblem == nil { pastedJSON = "" }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.top, 6)
            }
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textSecondary)
        }
    }
}

/// Key fields for a server that's already added.
private struct HomeServerKeysEditor: View {
    let serverName: String
    let keyNames: [DottieToolsStore.KeyName]
    @ObservedObject var store: DottieToolsStore
    let keyLink: String?
    @State private var typedValues: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(keyNames, id: \.name) { key in
                HStack {
                    SecureField(store.hasKey(key.name, for: serverName) ? "\(key.label) (saved)" : key.label, text: Binding(
                        get: { typedValues[key.name] ?? "" },
                        set: { typedValues[key.name] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        store.setKey(typedValues[key.name] ?? "", name: key.name, for: serverName)
                        typedValues[key.name] = ""
                    }
                    .controlSize(.small)
                    .disabled((typedValues[key.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let keyLink, let url = URL(string: keyLink) {
                Link("Where do I get this?", destination: url)
                    .font(.system(size: 11))
            }
        }
    }
}

/// Asks for what a catalog app needs (keys, folders, an address).
private struct HomeAddPresetSheet: View {
    let preset: DottieMCPPreset
    @ObservedObject var store: DottieToolsStore
    let onClose: () -> Void

    @State private var values: [String: String] = [:]
    @State private var folders: [String: [String]] = [:]
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: preset.symbolName)
                    .font(.system(size: 16))
                    .foregroundColor(DS.Colors.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add \(preset.title)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(preset.summary)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            ForEach(preset.fields, id: \.placeholder) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    fieldInput(field)
                    if !field.hint.isEmpty {
                        HomeHint(field.hint)
                    }
                }
            }

            if let keyLink = preset.keyLink, let url = URL(string: keyLink) {
                Link("Get a key", destination: url)
                    .font(.system(size: 11))
            }
            if preset.needsKey {
                HomeHint("Keys are kept in your Mac's Keychain, not in a file.")
            }
            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warningText)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                Button("Add") {
                    problem = store.addPreset(preset, values: values, folders: folders)
                    if problem == nil { onClose() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(DS.Colors.surface1)
    }

    @ViewBuilder
    private func fieldInput(_ field: DottieMCPPreset.Field) -> some View {
        switch field.kind {
        case .secret:
            SecureField("Paste it here", text: binding(for: field.placeholder))
                .textFieldStyle(.roundedBorder)
        case .address:
            TextField("http://…", text: binding(for: field.placeholder))
                .textFieldStyle(.roundedBorder)
        case .folders:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(folders[field.placeholder] ?? [], id: \.self) { folderPath in
                    HStack {
                        Text((folderPath as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Remove") {
                            folders[field.placeholder]?.removeAll { $0 == folderPath }
                        }
                        .controlSize(.small)
                    }
                }
                Button("Choose folders…") {
                    let picked = pick(directories: true, multiple: true)
                    var current = folders[field.placeholder] ?? []
                    for path in picked where !current.contains(path) { current.append(path) }
                    folders[field.placeholder] = current
                }
                .controlSize(.small)
            }
        case .folder, .file:
            HStack {
                Text(values[field.placeholder].map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Nothing chosen")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(values[field.placeholder] == nil ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(field.kind == .folder ? "Choose folder…" : "Choose file…") {
                    if let path = pick(directories: field.kind == .folder, multiple: false).first {
                        values[field.placeholder] = path
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private func binding(for placeholder: String) -> Binding<String> {
        Binding(get: { values[placeholder] ?? "" }, set: { values[placeholder] = $0 })
    }

    private func pick(directories: Bool, multiple: Bool) -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = multiple
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map(\.path)
    }
}

// MARK: - Command-line tools

private struct HomeCommandLineToolsSection: View {
    @ObservedObject var cliTools: DottieCLIToolsManager
    @State private var search = ""
    @State private var isConfirmingHomebrew = false

    private var filteredTools: [DottieCLITool] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return DottieCLICatalog.all }
        return DottieCLICatalog.all.filter {
            $0.title.lowercased().contains(query) || $0.summary.lowercased().contains(query) || $0.command.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !cliTools.isHomebrewInstalled {
                HomeCard(title: "Homebrew") {
                    HomeHint("These tools install with Homebrew, the free app store for command-line tools. It isn't on this Mac yet. Installing it takes a few minutes and asks for your Mac's password in Terminal.")
                    Button("Install Homebrew…") { isConfirmingHomebrew = true }
                        .controlSize(.small)
                }
            }
            if let problem = cliTools.lastProblem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HomeCard(title: "Command-line tools") {
                HStack {
                    TextField("Search tools", text: $search)
                        .textFieldStyle(.roundedBorder)
                    if cliTools.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                }
                HomeHint("Helpers can use any tool that's installed. \(cliTools.installedToolIDs.count) of \(DottieCLICatalog.all.count) are on this Mac.")
                ForEach(filteredTools) { tool in
                    toolRow(tool)
                }
            }
        }
        .alert("Install Homebrew?", isPresented: $isConfirmingHomebrew) {
            Button("Open Terminal") { cliTools.openHomebrewInstallerInTerminal() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Dottie opens Terminal with Homebrew's official install command. Type your Mac password there when asked, then come back here.")
        }
    }

    private func toolRow(_ tool: DottieCLITool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(tool.command)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Text(cliTools.installProgress[tool.id] ?? tool.summary)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if cliTools.installProgress[tool.id] != nil {
                ProgressView().controlSize(.small)
            } else if cliTools.isInstalled(tool) {
                Label("Installed", systemImage: "checkmark")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.success)
            } else {
                Button("Install") {
                    Task { await cliTools.install(tool) }
                }
                .controlSize(.small)
                .disabled(!cliTools.isHomebrewInstalled)
            }
        }
    }
}
