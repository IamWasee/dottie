//
//  HomeMeetingsView.swift
//  leanring-buddy
//
//  Home → Meetings: the switch for meeting mode, the live transcript while
//  it runs, and every saved meeting's notes.
//

import AppKit
import SwiftUI

struct HomeMeetingsView: View {
    @ObservedObject var meetingRecorder: DottieMeetingRecorder

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Meetings")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Meeting mode is off until you turn it on. While it's on, Dottie listens to your mic and your Mac's audio, writes down what's said, and when you stop it, saves notes with the decisions and action items. The audio itself is never kept. You can also just tell Dottie \u{201C}take notes\u{201D} and \u{201C}stop\u{201D}.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HomeCard(title: "Meeting mode") {
                    HStack(spacing: 10) {
                        if meetingRecorder.isRecording {
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                            Text("Taking notes · \(meetingRecorder.elapsedText)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                        } else if meetingRecorder.isSummarizing {
                            ProgressView().controlSize(.small)
                            Text("Writing up the notes…")
                                .font(.system(size: 13))
                                .foregroundColor(DS.Colors.textSecondary)
                        } else {
                            Text("Off")
                                .font(.system(size: 13))
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        Spacer()
                        if meetingRecorder.isRecording {
                            Button("Stop and write notes") { meetingRecorder.stop() }
                                .keyboardShortcut(.defaultAction)
                        } else {
                            Button("Start taking notes") {
                                Task { await meetingRecorder.start() }
                            }
                            .disabled(meetingRecorder.isSummarizing)
                        }
                    }
                    if let statusNote = meetingRecorder.statusNote {
                        HomeHint(statusNote)
                    }
                    if meetingRecorder.isRecording {
                        let recentLines = meetingRecorder.transcriptLines.suffix(40)
                        if recentLines.isEmpty {
                            HomeHint("Listening. The first lines show up within a minute.")
                        } else {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(recentLines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 12))
                                        .foregroundColor(line.hasPrefix("[") ? DS.Colors.textTertiary : DS.Colors.textSecondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                HomeCard(title: "Saved meetings") {
                    if meetingRecorder.pastMeetings.isEmpty {
                        HomeHint("No meetings yet.")
                    }
                    ForEach(meetingRecorder.pastMeetings) { meeting in
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(DS.Colors.textTertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(meeting.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(DS.Colors.textPrimary)
                                    .lineLimit(1)
                                Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 10))
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                            Spacer()
                            Button("Open") { NSWorkspace.shared.open(meeting.fileURL) }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.open(DottieMeetingRecorder.meetingsFolderURL)
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear { meetingRecorder.reloadPastMeetings() }
    }
}

/// A titled card, the same look as the other Home sections.
struct HomeCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
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
}

struct HomeHint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
