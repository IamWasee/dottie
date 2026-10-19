//
//  DottieEpisodicMemoryTimeline.swift
//  leanring-buddy
//
//  Home → Brain: the Timeline of episodes by day (tap one to see it all,
//  delete one, or forget everything), and the "Remember what's on my
//  screen" switch with the apps Dottie never looks at.
//

import AppKit
import SwiftUI

struct DottieEpisodeTimeline: View {
    @ObservedObject var memory: DottieEpisodicMemory
    @State private var expandedEpisodeID: UUID?
    @State private var shownEpisodeCount = 60
    @State private var isConfirmingForget = false

    private struct Day: Identifiable {
        let id: Date
        let title: String
        let episodes: [DottieEpisode]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if memory.episodes.isEmpty {
                Text("Nothing yet. After you talk with Dottie, or a helper or screen job finishes, what happened shows up here.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if memory.isSaving {
                Text("saving the last conversation…")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            ForEach(days) { day in
                VStack(alignment: .leading, spacing: 6) {
                    Text(day.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.top, 4)
                    ForEach(day.episodes) { episode in
                        row(for: episode)
                    }
                }
            }
            HStack {
                if memory.episodes.count > shownEpisodeCount {
                    Button("Show older") { shownEpisodeCount += 60 }
                }
                Spacer()
                if !memory.episodes.isEmpty {
                    Button("Forget everything…") { isConfirmingForget = true }
                }
            }
        }
        .alert("Forget the whole timeline?", isPresented: $isConfirmingForget) {
            Button("Forget", role: .destructive) { memory.forgetEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every moment on the timeline. The notes about you stay.")
        }
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let shownEpisodes = memory.episodes.suffix(shownEpisodeCount).reversed()
        var days: [Day] = []
        var currentDay: Date?
        var currentEpisodes: [DottieEpisode] = []
        for episode in shownEpisodes {
            let day = calendar.startOfDay(for: episode.startedAt)
            if day != currentDay {
                if let currentDay { days.append(Day(id: currentDay, title: Self.dayTitle(currentDay), episodes: currentEpisodes)) }
                currentDay = day
                currentEpisodes = []
            }
            currentEpisodes.append(episode)
        }
        if let currentDay { days.append(Day(id: currentDay, title: Self.dayTitle(currentDay), episodes: currentEpisodes)) }
        return days
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func row(for episode: DottieEpisode) -> some View {
        let isExpanded = expandedEpisodeID == episode.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                DottieEpisodeIcon(episode: episode, thumbnailURL: memory.thumbnailURL(for: episode))
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(isExpanded ? nil : 1)
                    Text("\(episode.startedAt.formatted(date: .omitted, time: .shortened)) · \(episode.source.label)\(episode.appName.map { " · \($0)" } ?? "")")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.top, 3)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) {
                    expandedEpisodeID = isExpanded ? nil : episode.id
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !episode.summary.isEmpty {
                        detailText(episode.summary)
                    }
                    if !episode.whereText.isEmpty {
                        labeledLine("Where", episode.whereText)
                    }
                    if !episode.people.isEmpty {
                        labeledLine("Involved", episode.people.joined(separator: ", "))
                    }
                    if let outcome = episode.outcome, !outcome.isEmpty {
                        labeledLine("Outcome", outcome)
                    }
                    if !episode.tags.isEmpty {
                        labeledLine("Tags", episode.tags.joined(separator: ", "))
                    }
                    HStack {
                        if let url = episode.url, url.hasPrefix("http"), let link = URL(string: url) {
                            Button("Open page") { NSWorkspace.shared.open(link) }
                        }
                        Spacer()
                        Button("Delete") {
                            expandedEpisodeID = nil
                            memory.delete([episode.id])
                        }
                    }
                }
                .padding(.leading, 38)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(isExpanded ? DS.Colors.surface2 : Color.clear)
        )
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(episode.title)\n\(episode.summary)", forType: .string)
            }
            Button("Delete", role: .destructive) { memory.delete([episode.id]) }
        }
    }

    private func detailText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func labeledLine(_ label: String, _ value: String) -> some View {
        (Text("\(label): ").foregroundColor(DS.Colors.textTertiary) + Text(value).foregroundColor(DS.Colors.textSecondary))
            .font(.system(size: 11))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The episode's picture, else its app's icon, else a symbol for where it
/// came from.
private struct DottieEpisodeIcon: View {
    let episode: DottieEpisode
    let thumbnailURL: URL?

    var body: some View {
        Group {
            if let image = DottieEpisodeIconCache.image(for: episode, thumbnailURL: thumbnailURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: thumbnailURL == nil ? .fit : .fill)
            } else {
                Image(systemName: episode.source.symbolName)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
    }
}

@MainActor
private enum DottieEpisodeIconCache {
    private static var images: [String: NSImage] = [:]

    static func image(for episode: DottieEpisode, thumbnailURL: URL?) -> NSImage? {
        if let thumbnailURL {
            let key = thumbnailURL.path
            if let cached = images[key] { return cached }
            guard let image = NSImage(contentsOf: thumbnailURL) else { return nil }
            images[key] = image
            return image
        }
        guard let bundleIdentifier = episode.bundleIdentifier else { return nil }
        if let cached = images[bundleIdentifier] { return cached }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        images[bundleIdentifier] = icon
        return icon
    }
}

/// The "Remember what's on my screen" switch and the never-look list.
struct DottieScreenMemorySettings: View {
    @ObservedObject var brain: DottieBrain
    @ObservedObject var screenMemory: DottieScreenMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { screenMemory.isEnabled },
                set: { brain.setScreenJournalEnabled($0) }
            )) {
                Text("Remember what's on my screen")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .toggleStyle(.switch)
            Text("Every few minutes while you're using the Mac, Dottie notes the app, the window, the web address and a little of the window's text. The text is read on this Mac and no screenshot is kept. Every half hour or so the notes are turned into timeline moments, and only those short notes go to Gemini. Password boxes, private browser windows and the apps below are always skipped. A small green light shows in the notch while it's on.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Never look at")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.top, 2)
            FlowingAppList(apps: screenMemory.excludedApps) { appName in
                screenMemory.removeExcludedApp(appName)
            }
            HStack {
                Spacer()
                Menu("Add app") {
                    ForEach(addableAppNames, id: \.self) { appName in
                        Button(appName) { screenMemory.addExcludedApp(appName) }
                    }
                }
                .fixedSize()
            }
        }
    }

    /// Open apps not on the list yet.
    private var addableAppNames: [String] {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap(\.localizedName)
            .filter { name in !screenMemory.excludedApps.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        return Array(Set(names)).sorted()
    }
}

/// App names as small removable chips, wrapping onto new lines.
private struct FlowingAppList: View {
    let apps: [String]
    let onRemove: (String) -> Void

    var body: some View {
        if apps.isEmpty {
            Text("No apps. Dottie may look at any app except password boxes and private windows.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(apps, id: \.self) { appName in
                    HStack(spacing: 4) {
                        Text(appName)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            onRemove(appName)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Let Dottie look at \(appName)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )
                }
            }
        }
    }
}
