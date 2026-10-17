//
//  HomeLibraryViews.swift
//  leanring-buddy
//
//  Home → Projects (each thing the user is making, its folder, files and
//  notes) and Home → Pictures (the picture library: add a picture with a
//  name and a description, edit them, see the ones Dottie saved herself).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Projects

struct HomeProjectsView: View {
    @ObservedObject var projects: DottieProjects
    @ObservedObject var clickyRoster: ClickyRoster
    @State private var selectedProjectID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Projects")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Everything Dots build lives in a project: its own folder with the files and a PROJECT.md of what's done and what's left. Ask Dottie to \u{201C}work on the coffee store site again\u{201D} and the work goes back into the same project, or say \u{201C}get a team on it\u{201D} to split a big job between several Dots.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if projects.projects.isEmpty {
                    HomeCard(title: "No projects yet") {
                        HomeHint("Ask Dottie to build something, like \u{201C}have a Dot make me a coffee store website\u{201D}.")
                    }
                }

                ForEach(projects.projects.sorted { $0.updatedAt > $1.updatedAt }) { project in
                    HomeCard(title: project.name) {
                        if !project.summary.isEmpty {
                            Text(project.summary)
                                .font(.system(size: 12))
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        let workingNames = project.helperNames.filter { helperName in
                            clickyRoster.agents.contains { $0.name == helperName && clickyRoster.isRunning($0) }
                        }
                        HStack(spacing: 6) {
                            if !workingNames.isEmpty {
                                ProgressView().controlSize(.mini)
                                Text("\(workingNames.joined(separator: ", ")) working")
                                    .font(.system(size: 11))
                                    .foregroundColor(DS.Colors.textSecondary)
                            } else if !project.helperNames.isEmpty {
                                Text("Worked on by \(project.helperNames.suffix(4).joined(separator: ", "))")
                                    .font(.system(size: 11))
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                            Spacer()
                            Text(project.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        if selectedProjectID == project.id {
                            let fileNames = projects.fileNames(in: project)
                            if fileNames.isEmpty {
                                HomeHint("No files yet.")
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(fileNames, id: \.self) { fileName in
                                        Text(fileName)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(DS.Colors.textSecondary)
                                    }
                                }
                            }
                            let notes = projects.notes(for: project)
                            if !notes.isEmpty {
                                Text(notes)
                                    .font(.system(size: 11))
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        HStack(spacing: 8) {
                            Button(selectedProjectID == project.id ? "Hide files" : "Show files") {
                                selectedProjectID = selectedProjectID == project.id ? nil : project.id
                            }
                            Button("Open folder") { projects.revealInFinder(project) }
                            Spacer()
                            Button("Move to Trash") { projects.remove(project) }
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Pictures

struct HomePicturesView: View {
    @ObservedObject var imageMemory: DottieImageMemory
    @State private var newPictureData: Data?
    @State private var newPictureName = ""
    @State private var newPictureDescription = ""
    @State private var editingItemID: UUID?
    @State private var editedName = ""
    @State private var editedDescription = ""
    @State private var isDropTargeted = false

    private let gridColumns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pictures")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Pictures Dottie remembers by name. Say where each is from in its description (\u{201C}a guardian core from the game Build a Golem\u{201D}), and when you ask her to pick up the guardian core she knows what it looks like and which game it's in. She saves her own too when remembering how something looks will help later.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HomeCard(title: "Add a picture") {
                    if let newPictureData, let previewImage = NSImage(data: newPictureData) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(nsImage: previewImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("Name, like guardian core", text: $newPictureName)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Description: what it is, where it's from, how it looks", text: $newPictureDescription, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(2...4)
                                HStack {
                                    Button("Save") { saveNewPicture() }
                                        .keyboardShortcut(.defaultAction)
                                        .disabled(newPictureName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    Button("Cancel") { clearNewPicture() }
                                }
                            }
                        }
                    } else {
                        HStack(spacing: 10) {
                            Button("Choose a picture…") { choosePicture() }
                            HomeHint("or drop one here, or paste it with ⌘V in Conversation.")
                        }
                    }
                }

                if imageMemory.items.isEmpty {
                    HomeHint("No pictures yet.")
                } else {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 12) {
                        ForEach(imageMemory.items.reversed()) { item in
                            pictureCard(item)
                        }
                    }
                }
            }
            .padding(24)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DS.Colors.accent, lineWidth: 2)
                .padding(4)
                .opacity(isDropTargeted ? 1 : 0)
        )
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            loadDroppedPicture(from: providers)
            return true
        }
    }

    @ViewBuilder
    private func pictureCard(_ item: DottieImageMemory.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = NSImage(contentsOf: imageMemory.fileURL(for: item)) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if editingItemID == item.id {
                TextField("Name", text: $editedName)
                    .textFieldStyle(.roundedBorder)
                TextField("Description", text: $editedDescription, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                HStack {
                    Button("Save") {
                        imageMemory.rename(item, to: editedName)
                        imageMemory.updateDescription(item, to: editedDescription)
                        editingItemID = nil
                    }
                    Button("Cancel") { editingItemID = nil }
                }
                .controlSize(.small)
            } else {
                HStack(spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    if item.savedByDottie == true {
                        Text("saved by Dottie")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(4)
                }
                HStack {
                    Button("Edit") {
                        editedName = item.name
                        editedDescription = item.description
                        editingItemID = item.id
                    }
                    Button("Forget") { imageMemory.remove(item) }
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    private func choosePicture() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.image]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        guard openPanel.runModal() == .OK, let url = openPanel.url, let data = try? Data(contentsOf: url) else { return }
        startNewPicture(with: data, suggestedName: url.deletingPathExtension().lastPathComponent)
    }

    private func loadDroppedPicture(from providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return }
                DispatchQueue.main.async { startNewPicture(with: data, suggestedName: url.deletingPathExtension().lastPathComponent) }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                DispatchQueue.main.async { startNewPicture(with: data, suggestedName: "") }
            }
        }
    }

    private func startNewPicture(with data: Data, suggestedName: String) {
        guard NSImage(data: data) != nil else { return }
        newPictureData = data
        // Screenshot file names make poor names; only keep a real one.
        newPictureName = suggestedName.lowercased().hasPrefix("screenshot") ? "" : suggestedName
        newPictureDescription = ""
    }

    private func saveNewPicture() {
        guard let newPictureData else { return }
        _ = imageMemory.add(imageData: newPictureData, name: newPictureName, description: newPictureDescription, savedByDottie: false)
        clearNewPicture()
    }

    private func clearNewPicture() {
        newPictureData = nil
        newPictureName = ""
        newPictureDescription = ""
    }
}
