//
//  NotchRootView.swift
//  leanring-buddy
//
//  The black shape that grows out of the notch, and every surface inside it:
//  Clicky's eyes, the listening waveform, the live caption while it speaks,
//  a text box for typing, and the finished answer as a card. Mirrors the
//  surfaces shipped Clicky has (NotchRootView, NotchEyeView,
//  NotchTextInputSurface, NotchTextResponseSurface).
//

import AppKit
import SwiftUI

struct NotchRootView: View {
    @ObservedObject var notchPresenter: NotchPresenter
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    private var isExpanded: Bool {
        notchPresenter.surface != .compact || notchPresenter.isHovering
    }

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(
                bottomLeadingRadius: isExpanded ? 22 : 10,
                bottomTrailingRadius: isExpanded ? 22 : 10,
                style: .continuous
            )
            .fill(Color.black)

            VStack(spacing: 0) {
                // The physical notch covers this strip; keep it empty.
                Color.clear.frame(height: notchHeight)
                surfaceContent
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.22), value: notchPresenter.surface)
        .animation(.easeOut(duration: 0.18), value: notchPresenter.isHovering)
        .onHover { isHovering in
            notchPresenter.isHovering = isHovering
        }
    }

    @ViewBuilder
    private var surfaceContent: some View {
        switch notchPresenter.surface {
        case .compact:
            if notchPresenter.isHovering {
                compactHoverContent
            }
        case .listening:
            listeningContent
        case .thinking:
            thinkingContent
        case .speaking:
            speakingContent
        case .textInput:
            NotchTextInputSurface(notchPresenter: notchPresenter)
        case .textResponse:
            NotchTextResponseSurface(notchPresenter: notchPresenter)
        }
    }

    // MARK: - Compact (hovered)

    private var compactHoverContent: some View {
        HStack(spacing: 10) {
            NotchEyeView(mood: .idle)
            Button(action: { notchPresenter.openTextInput() }) {
                Text("type to clicky")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            Spacer(minLength: 0)
            Button(action: { notchPresenter.onOpenHome?() }) {
                Image(systemName: "house.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Open Home")
        }
        .padding(.top, 4)
    }

    // MARK: - Voice surfaces

    private var listeningContent: some View {
        HStack(spacing: 12) {
            NotchEyeView(mood: .listening)
            Text(notchPresenter.activityLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
            Spacer(minLength: 0)
            NotchWaveformView(audioPowerLevel: notchPresenter.audioPowerLevel)
        }
        .padding(.top, 8)
    }

    private var thinkingContent: some View {
        HStack(spacing: 12) {
            NotchEyeView(mood: .thinking)
            Text(notchPresenter.activityLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
            Spacer(minLength: 0)
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        }
        .padding(.top, 8)
    }

    private var speakingContent: some View {
        HStack(alignment: .top, spacing: 12) {
            NotchEyeView(mood: .speaking)
                .padding(.top, 2)
            // Show the tail of the caption so the newest words stay visible.
            Text(notchPresenter.liveCaptionText.isEmpty ? "…" : notchPresenter.liveCaptionText)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8)
    }
}

// MARK: - Eyes

/// Clicky's face in the notch: two little eyes that blink, look up while
/// thinking, and bounce while talking.
struct NotchEyeView: View {
    enum Mood {
        case idle
        case listening
        case thinking
        case speaking
    }

    let mood: Mood
    @State private var isBlinking = false
    @State private var speakingBounce = false

    var body: some View {
        HStack(spacing: 4) {
            eye
            eye
        }
        .offset(y: mood == .thinking ? -2 : 0)
        .offset(y: speakingBounce ? -1.5 : 0)
        .onAppear {
            scheduleNextBlink()
            if mood == .speaking {
                withAnimation(.easeInOut(duration: 0.28).repeatForever(autoreverses: true)) {
                    speakingBounce = true
                }
            }
        }
    }

    private var eye: some View {
        Capsule()
            .fill(mood == .listening ? DS.Colors.overlayCursorBlue : Color.white)
            .frame(width: 6, height: isBlinking ? 1.5 : 10)
            .animation(.easeInOut(duration: 0.08), value: isBlinking)
    }

    private func scheduleNextBlink() {
        let secondsUntilBlink = Double.random(in: 2.5...5.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + secondsUntilBlink) {
            isBlinking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                isBlinking = false
                scheduleNextBlink()
            }
        }
    }
}

// MARK: - Waveform

private struct NotchWaveformView: View {
    let audioPowerLevel: CGFloat
    private let barCount = 7

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { barIndex in
                Capsule()
                    .fill(DS.Colors.overlayCursorBlue)
                    .frame(width: 3, height: barHeight(forBarIndex: barIndex))
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.08), value: audioPowerLevel)
    }

    /// Middle bars move most, edges least, so it reads as a voice shape.
    private func barHeight(forBarIndex barIndex: Int) -> CGFloat {
        let distanceFromCenter = abs(CGFloat(barIndex) - CGFloat(barCount - 1) / 2)
        let centerWeight = 1 - distanceFromCenter / CGFloat(barCount)
        let clampedPowerLevel = min(1, max(0, audioPowerLevel))
        return 4 + 18 * clampedPowerLevel * centerWeight
    }
}

// MARK: - Text input

private struct NotchTextInputSurface: View {
    @ObservedObject var notchPresenter: NotchPresenter
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            NotchEyeView(mood: .idle)
            TextField("ask clicky", text: $notchPresenter.draftText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .focused($isTextFieldFocused)
                .onSubmit { notchPresenter.submitDraft() }
                .onExitCommand { notchPresenter.cancelTextInput() }
            Button(action: { notchPresenter.submitDraft() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(notchPresenter.draftText.isEmpty ? .white.opacity(0.3) : DS.Colors.overlayCursorBlue)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(notchPresenter.draftText.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .padding(.top, 8)
        .onAppear {
            // The panel becomes key a moment after resizing; focus after it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
    }
}

// MARK: - Text response

private struct NotchTextResponseSurface: View {
    @ObservedObject var notchPresenter: NotchPresenter
    @State private var didJustCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let responseTitle = notchPresenter.lastResponseTitle {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.overlayCursorBlue)
                    Text(responseTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                    Spacer(minLength: 0)
                    Button(action: { notchPresenter.onOpenHome?() }) {
                        Text("open")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                Text(notchPresenter.lastResponseText)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if notchPresenter.computerUseRequestAgentID != nil {
                computerUseRequestButtons
            } else {
                responseButtons
            }
        }
        .padding(.top, 8)
    }

    private var computerUseRequestButtons: some View {
        HStack(spacing: 10) {
            Text("wants to use your Mac")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
            Spacer(minLength: 0)
            Button("Not now") { notchPresenter.answerComputerUseRequest(isAllowed: false) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .pointerCursor()
            Button("Always") { notchPresenter.answerComputerUseRequest(isAllowed: true, alwaysAllow: true) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .pointerCursor()
                .help("Let Clickys use your Mac without asking")
            Button(action: { notchPresenter.answerComputerUseRequest(isAllowed: true) }) {
                Text("Allow")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.Colors.overlayCursorBlue))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private var responseButtons: some View {
        HStack(spacing: 14) {
            Button(action: copyResponse) {
                Label(didJustCopy ? "Copied" : "Copy", systemImage: didJustCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: { notchPresenter.openTextInput() }) {
                Label("Follow up", systemImage: "arrowshape.turn.up.right.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Spacer(minLength: 0)

            Button(action: { notchPresenter.toggleAutoDismissPause() }) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: notchPresenter.autoDismissProgress)
                        .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if notchPresenter.isAutoDismissPaused {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 6))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(notchPresenter.isAutoDismissPaused ? "Resume auto-dismiss" : "Pause auto-dismiss")

            Button(action: { notchPresenter.collapse() }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Dismiss now")
        }
    }

    private func copyResponse() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(notchPresenter.lastResponseText, forType: .string)
        didJustCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            didJustCopy = false
        }
    }
}
