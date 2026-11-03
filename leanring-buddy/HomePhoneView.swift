//
//  HomePhoneView.swift
//  leanring-buddy
//
//  Home → Phone: text Dottie from anywhere with Telegram. Connect pairs the
//  phone in one tap through Dottie's own bot (scan the QR code or open the
//  link, then Start); the user's own bot stays as an advanced option. Also
//  shows the latest messages.
//

import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct HomePhoneView: View {
    @ObservedObject var phoneBridge: DottiePhoneBridge
    @State private var tokenText = ""
    @State private var errorText: String?
    @State private var isConnecting = false
    @State private var isConnectingOwnBot = false
    @State private var ownBotErrorText: String?
    @State private var isShowingOwnBotSetup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Phone")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Text Dottie from your phone with Telegram. A helper called Phone does the job on this Mac and texts you back. Only your paired phone can use it. The Mac has to be awake with Dottie running.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !phoneBridge.isConnected {
                    HomeCard(title: "Connect your phone") {
                        Text("One tap: Dottie shows a code, you scan it with your phone and press Start in Telegram. No bot to make, nothing to copy.")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(isConnecting ? "Connecting…" : "Connect") {
                                isConnecting = true
                                Task {
                                    errorText = await phoneBridge.connectWithDottieBot()
                                    isConnecting = false
                                }
                            }
                            .keyboardShortcut(.defaultAction)
                            .disabled(isConnecting)
                            .pointerCursor()
                            Spacer()
                        }
                        if let errorText {
                            Text(errorText)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.warningText)
                        }
                        HomeHint("Needs Telegram on your phone (free in the App Store). Messages pass through Dottie's server only to reach this Mac.")
                    }

                    DisclosureGroup("Use my own Telegram bot instead (advanced)", isExpanded: $isShowingOwnBotSetup) {
                        ownBotSetupCard
                            .padding(.top, 8)
                    }
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                } else if phoneBridge.pairedChatID == nil, phoneBridge.usesDottieBot {
                    HomeCard(title: "Scan with your phone") {
                        Text("Point your phone's camera at this code, open it in Telegram and tap Start. That's all.")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let pairingLink = phoneBridge.pairingLink {
                            HStack {
                                Spacer()
                                if let qrImage = Self.qrCodeImage(for: pairingLink.absoluteString) {
                                    Image(nsImage: qrImage)
                                        .interpolation(.none)
                                        .resizable()
                                        .frame(width: 180, height: 180)
                                        .padding(10)
                                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                                }
                                Spacer()
                            }
                            HStack {
                                Button("Copy link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(pairingLink.absoluteString, forType: .string)
                                }
                                .pointerCursor()
                                Button("Open in Telegram on this Mac") {
                                    NSWorkspace.shared.open(pairingLink)
                                }
                                .pointerCursor()
                                Spacer()
                                Button("New code") {
                                    Task { await phoneBridge.refreshPairingLinkIfOld(force: true) }
                                }
                                .pointerCursor()
                            }
                            HomeHint("The code works for 15 minutes. You can also send yourself the link and open it on the phone.")
                        } else {
                            Text(phoneBridge.statusText.isEmpty ? "Getting a code…" : phoneBridge.statusText)
                                .font(.system(size: 12))
                                .foregroundColor(DS.Colors.textTertiary)
                            Button("Try again") {
                                Task { await phoneBridge.refreshPairingLinkIfOld(force: true) }
                            }
                            .pointerCursor()
                        }
                        HStack {
                            Spacer()
                            Button("Cancel") { phoneBridge.disconnect() }
                                .pointerCursor()
                        }
                    }
                    .task { await phoneBridge.refreshPairingLinkIfOld() }
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
                            Button(phoneBridge.usesDottieBot ? "Disconnect" : "Disconnect bot") { phoneBridge.disconnect() }
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

    /// The advanced way: the user's own bot made with @BotFather.
    private var ownBotSetupCard: some View {
        HomeCard(title: "Your own bot (about two minutes)") {
            step(1, "On your phone, open Telegram and message @BotFather.")
            step(2, "Send /newbot, give it any name, then a username ending in \u{201C}bot\u{201D}.")
            step(3, "BotFather replies with a token like 123456:ABC-DEF…. Paste it here.")
            HStack {
                SecureField("Bot token", text: $tokenText)
                    .textFieldStyle(.roundedBorder)
                Button(isConnectingOwnBot ? "Connecting…" : "Connect") {
                    isConnectingOwnBot = true
                    Task {
                        ownBotErrorText = await phoneBridge.connect(token: tokenText)
                        isConnectingOwnBot = false
                        if ownBotErrorText == nil { tokenText = "" }
                    }
                }
                .disabled(tokenText.isEmpty || isConnectingOwnBot)
            }
            if let ownBotErrorText {
                Text(ownBotErrorText)
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
    }

    /// A crisp QR code for the pairing link (drawn without smoothing).
    private static func qrCodeImage(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height))
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
