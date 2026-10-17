//
//  DottiePhoneBridge.swift
//  leanring-buddy
//
//  Text Dottie from your phone. The user makes their own Telegram bot
//  (free, two minutes with @BotFather), pastes its token in Home → Phone,
//  and sends the bot the pairing code once. From then on, messages from
//  that one chat go to a "Phone" helper on the Mac, and the helper's reply
//  comes back as a text. The Mac talks to Telegram directly; nothing goes
//  through Dottie's server. Messages from anyone else are ignored.
//

import Combine
import Foundation

@MainActor
final class DottiePhoneBridge: ObservableObject {
    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let isFromPhone: Bool
        let text: String
    }

    @Published private(set) var isConnected = false
    @Published private(set) var botUsername: String?
    @Published private(set) var pairedChatID: Int64?
    @Published private(set) var pairingCode = DottiePhoneBridge.newPairingCode()
    @Published private(set) var statusText = ""
    @Published private(set) var log: [LogEntry] = []

    /// A paired message that isn't a built-in command.
    var onMessage: ((String) -> Void)?
    /// "status": what Dottie and the helpers are up to.
    var statusProvider: (() -> String)?
    /// "screenshot": a JPEG of the main screen.
    var screenshotProvider: (() async -> Data?)?
    /// "allow" / "deny" for a helper waiting to use the Mac.
    var onPermissionAnswer: ((Bool) -> String)?

    private static let pairedChatDefaultsKey = "phonePairedChatID"
    private static let updateOffsetDefaultsKey = "phoneUpdateOffset"
    private var botToken: String?
    private var pollingTask: Task<Void, Never>?

    init() {
        let savedChatID = UserDefaults.standard.object(forKey: Self.pairedChatDefaultsKey) as? NSNumber
        pairedChatID = savedChatID?.int64Value
        if let savedToken = Self.readToken(), !savedToken.isEmpty {
            Task { _ = await connect(token: savedToken) }
        }
    }

    // MARK: - Setup

    /// Checks the token with Telegram, saves it and starts listening.
    /// Returns an error message, or nil when connected.
    func connect(token rawToken: String) async -> String? {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.contains(":") else { return "That doesn't look like a bot token. It looks like 123456:ABC-DEF…" }
        guard let botInfo = await callTelegram(token: token, method: "getMe", parameters: [:]) as? [String: Any],
              let username = botInfo["username"] as? String else {
            statusText = "Telegram didn't accept that token."
            return "Telegram didn't accept that token. Copy it again from @BotFather."
        }
        botToken = token
        Self.saveToken(token)
        botUsername = username
        isConnected = true
        statusText = pairedChatID == nil ? "Waiting for the pairing code." : "Connected."
        startPolling()
        return nil
    }

    func disconnect() {
        pollingTask?.cancel()
        pollingTask = nil
        botToken = nil
        Self.saveToken(nil)
        isConnected = false
        botUsername = nil
        statusText = ""
    }

    func unpair() {
        pairedChatID = nil
        UserDefaults.standard.removeObject(forKey: Self.pairedChatDefaultsKey)
        pairingCode = Self.newPairingCode()
        statusText = isConnected ? "Waiting for the pairing code." : ""
    }

    private static func newPairingCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    // MARK: - Sending

    func send(_ text: String) async {
        guard let botToken, let pairedChatID else { return }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        appendLog(isFromPhone: false, trimmedText)
        // Telegram's limit is 4096 characters a message.
        var remainingText = Substring(trimmedText)
        while !remainingText.isEmpty {
            let piece = remainingText.prefix(3900)
            remainingText = remainingText.dropFirst(piece.count)
            _ = await callTelegram(token: botToken, method: "sendMessage", parameters: ["chat_id": pairedChatID, "text": String(piece)])
        }
    }

    private func sendPhoto(_ jpegData: Data, caption: String) async {
        guard let botToken, let pairedChatID,
              let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendPhoto") else { return }
        let boundary = "dottie-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        appendField("chat_id", String(pairedChatID))
        appendField("caption", caption)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"screen.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpegData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
        appendLog(isFromPhone: false, "(sent a screenshot)")
    }

    // MARK: - Receiving

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let token = self.botToken else { return }
                let offset = UserDefaults.standard.integer(forKey: Self.updateOffsetDefaultsKey)
                let updates = await self.callTelegram(
                    token: token,
                    method: "getUpdates",
                    parameters: ["timeout": 50, "offset": offset, "allowed_updates": ["message"]],
                    timeout: 65
                ) as? [[String: Any]]
                if Task.isCancelled { return }
                guard let updates else {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
                for update in updates {
                    if let updateID = update["update_id"] as? Int {
                        UserDefaults.standard.set(updateID + 1, forKey: Self.updateOffsetDefaultsKey)
                    }
                    if let message = update["message"] as? [String: Any] {
                        await self.handle(message)
                    }
                }
            }
        }
    }

    private func handle(_ message: [String: Any]) async {
        guard let chat = message["chat"] as? [String: Any],
              (chat["type"] as? String) == "private",
              let chatID = (chat["id"] as? NSNumber)?.int64Value else { return }
        let text = (message["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let botToken else { return }

        guard let pairedChatID else {
            if text.contains(pairingCode) {
                self.pairedChatID = chatID
                UserDefaults.standard.set(NSNumber(value: chatID), forKey: Self.pairedChatDefaultsKey)
                statusText = "Paired with your phone."
                await send("Paired! Text me anything and a helper on your Mac will do it. Try: status, screenshot, or \"check my calendar for tomorrow\".")
            } else {
                _ = await callTelegram(token: botToken, method: "sendMessage", parameters: [
                    "chat_id": chatID,
                    "text": "Send the 6-digit pairing code shown in Dottie → Home → Phone."
                ])
            }
            return
        }
        // Only the paired chat can talk to this Mac.
        guard chatID == pairedChatID, !text.isEmpty else { return }
        appendLog(isFromPhone: true, text)

        let command = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ ."))
        switch command {
        case "start", "help":
            await send("Text me a job and a helper on your Mac does it, then replies here. Commands: status, screenshot, allow, deny.")
        case "status":
            await send(statusProvider?() ?? "Dottie is running.")
        case "screenshot", "screen":
            if let jpegData = await screenshotProvider?() {
                await sendPhoto(jpegData, caption: "Your screen right now")
            } else {
                await send("Couldn't take a screenshot (Screen Recording may be off).")
            }
        case "allow", "yes", "deny", "no":
            let isAllowed = command == "allow" || command == "yes"
            await send(onPermissionAnswer?(isAllowed) ?? "Nothing is waiting for permission.")
        default:
            onMessage?(text)
        }
    }

    private func appendLog(isFromPhone: Bool, _ text: String) {
        log.append(LogEntry(date: Date(), isFromPhone: isFromPhone, text: DottieMacActions.shortened(text, to: 500)))
        if log.count > 40 { log.removeFirst(log.count - 40) }
    }

    /// Calls a Bot API method and returns its "result", or nil.
    private func callTelegram(token: String, method: String, parameters: [String: Any], timeout: TimeInterval = 30) async -> Any? {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)"),
              let body = try? JSONSerialization.data(withJSONObject: parameters) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (response["ok"] as? Bool) == true else { return nil }
        return response["result"]
    }

    // MARK: - Token file

    /// A private file rather than the keychain: Dottie is signed ad hoc, so
    /// each update would otherwise ask for the keychain password.
    private static var tokenFileURL: URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportURL.appendingPathComponent("Dottie/phone-bot-token")
    }

    private static func saveToken(_ token: String?) {
        guard let token else {
            try? FileManager.default.removeItem(at: tokenFileURL)
            return
        }
        try? FileManager.default.createDirectory(at: tokenFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tokenFileURL.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
    }

    private static func readToken() -> String? {
        (try? String(contentsOf: tokenFileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
