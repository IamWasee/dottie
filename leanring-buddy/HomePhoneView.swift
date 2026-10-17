//
//  HomePhoneView.swift
//  leanring-buddy
//
//  Home → Phone: connect the user's own Telegram bot so they can text
//  Dottie from anywhere, pair their phone with a one-time code, and see
//  the latest messages.
//

import AppKit
import SwiftUI

struct HomePhoneView: View {
    @ObservedObject var phoneBridge: DottiePhoneBridge
    @State private var tokenText = ""
    @State private var errorText: String?
    @State private var isConnecting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Phone")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Text Dottie from your phone with Telegram. A helper called Phone does the job on this Mac and texts you back. Your Mac talks to Telegram directly, and only your paired phone can use it. The Mac has to be awake with Dottie running.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !phoneBridge.isConnected {
                    HomeCard(title: "Set up (about two minutes)") {
                        step(1, "On your phone, open Telegram and message @BotFather.")
                        step(2, "Send /newbot, give it any name, then a username ending in \u{201C}bot\u{201D}.")
                        step(3, "BotFather replies with a token like 123456:ABC-DEF…. Paste it here.")
                        HStack {
                            SecureField("Bot token", text: $tokenText)
                                .textFieldStyle(.roundedBorder)
                            Button(isConnecting ? "Connecting…" : "Connect") {
                                isConnecting = true
                                Task {
                                    errorText = await phoneBridge.connect(token: tokenText)
                                    isConnecting = false
                                    if errorText == nil { tokenText = "" }
                                }
                            }
                            .disabled(tokenText.isEmpty || isConnecting)
                        }
                        if let errorText {
                            Text(errorText)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.warningText)
                        }
                        HStack {
                            Spacer()
                            Button("Open BotFather") {
                                NSWorkspace.shared.open(URL(string: "https://t.me/BotFather")!)
                            }
                        }
                    }
                } else if phoneBridge.pairedChatID == nil {
                    HomeCard(title: "Pair your phone") {
                        Text("Open your bot\(phoneBridge.botUsername.map { " @\($0)" } ?? "") in Telegram and send it this code:")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textSecondary)
                        Text(phoneBridge.pairingCode)
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .foregroundColor(DS.Colors.textPrimary)
                            .textSelection(.enabled)
                        HStack {
                            if let botUsername = phoneBridge.botUsername {
                                Button("Open @\(botUsername)") {
                                    NSWorkspace.shared.open(URL(string: "https://t.me/\(botUsername)")!)
                                }
                            }
                            Spacer()
                            Button("Disconnect bot") { phoneBridge.disconnect() }
                        }
                    }
                } else {
                    HomeCard(title: "Connected") {
                        HStack(spacing: 8) {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text("Paired with your phone\(phoneBridge.botUsername.map { " through @\($0)" } ?? "").")
                                .font(.system(size: 13))
                                .foregroundColor(DS.Colors.textPrimary)
                        }
                        HomeHint("Text it a job, like \u{201C}what's on my calendar tomorrow\u{201D} or \u{201C}find the PDF I downloaded today and summarize it\u{201D}. Also: status, screenshot, and allow or deny when a helper asks to use the Mac.")
                        HStack {
                            Button("Send a test message") {
                                Task { await phoneBridge.send("Hi from your Mac! 👋") }
                            }
                            Spacer()
                            Button("Unpair") { phoneBridge.unpair() }
                            Button("Disconnect bot") { phoneBridge.disconnect() }
                        }
                    }
                }

                if !phoneBridge.log.isEmpty {
                    HomeCard(title: "Latest messages") {
                        ForEach(phoneBridge.log.suffix(20).reversed()) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entry.isFromPhone ? "You" : "Dottie") · \(entry.date.formatted(date: .omitted, time: .shortened))")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(DS.Colors.textTertiary)
                                Text(entry.text)
                                    .font(.system(size: 12))
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(DS.Colors.surface3))
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
