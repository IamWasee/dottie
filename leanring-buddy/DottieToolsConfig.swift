//
//  DottieToolsConfig.swift
//  leanring-buddy
//
//  What Home → Tools saves, and where the keys go.
//
//  ~/Library/Application Support/Dottie/tools.json uses the same
//  "mcpServers" shape as Claude Desktop, Claude Code and Cursor, so a
//  server can be copied in or out as is:
//
//    {
//      "mcpServers": {
//        "notion": { "command": "npx", "args": ["-y", "@notionhq/notion-mcp-server"],
//                    "env": { "NOTION_TOKEN": "${NOTION_TOKEN}" } },
//        "linear": { "url": "https://mcp.linear.app/mcp",
//                    "headers": { "Authorization": "Bearer ${LINEAR_API_KEY}" } }
//      },
//      "dottie": { "servers": { "notion": { "enabled": true, "preset": "notion" } }, … }
//    }
//
//  Keys and tokens never go in the file: it holds ${NAME} and the value
//  lives in the Keychain (DottieToolsKeychain), filled in when a server
//  starts. Anything else in ${…} is read from the environment.
//

import CryptoKit
import Foundation
import Security

/// One server, in Claude Desktop's shape: a program to run (command, args,
/// env) or a web address (url, headers).
struct DottieMCPServerConfig: Codable, Equatable {
    var command: String?
    var args: [String] = []
    var env: [String: String] = [:]
    var url: String?
    var headers: [String: String] = [:]
    var type: String?
    var cwd: String?

    var isWebServer: Bool { command == nil && url != nil }

    init(command: String? = nil, args: [String] = [], env: [String: String] = [:], url: String? = nil, headers: [String: String] = [:], type: String? = nil, cwd: String? = nil) {
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.type = type
        self.cwd = cwd
    }

    private enum CodingKeys: String, CodingKey {
        case command, args, env, url, headers, type, cwd
        case serverURL = "serverUrl"
        case httpURL = "httpUrl"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        args = (try? container.decodeIfPresent([String].self, forKey: .args)) ?? []
        env = (try? container.decodeIfPresent([String: String].self, forKey: .env)) ?? [:]
        url = (try? container.decodeIfPresent(String.self, forKey: .url))
            ?? (try? container.decodeIfPresent(String.self, forKey: .httpURL))
            ?? (try? container.decodeIfPresent(String.self, forKey: .serverURL))
        headers = (try? container.decodeIfPresent([String: String].self, forKey: .headers)) ?? [:]
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(command, forKey: .command)
        if !args.isEmpty { try container.encode(args, forKey: .args) }
        if !env.isEmpty { try container.encode(env, forKey: .env) }
        try container.encodeIfPresent(url, forKey: .url)
        if !headers.isEmpty { try container.encode(headers, forKey: .headers) }
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(cwd, forKey: .cwd)
    }

    /// Every ${NAME} the server needs filled in.
    var placeholderNames: [String] {
        var names: [String] = []
        let texts = [command, url, cwd].compactMap { $0 } + args + Array(env.values) + Array(headers.values)
        for text in texts {
            for name in DottieToolsPlaceholders.names(in: text) where !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// The same server with every string passed through `transform`.
    func mapStrings(_ transform: (String) -> String) -> DottieMCPServerConfig {
        DottieMCPServerConfig(
            command: command.map(transform),
            args: args.map(transform),
            env: env.mapValues(transform),
            url: url.map(transform),
            headers: headers.mapValues(transform),
            type: type,
            cwd: cwd.map(transform)
        )
    }
}

/// Dottie's own notes about a server, kept beside mcpServers.
struct DottieMCPServerSettings: Codable, Equatable {
    var enabled: Bool = true
    var preset: String?
    var title: String?

    init(enabled: Bool = true, preset: String? = nil, title: String? = nil) {
        self.enabled = enabled
        self.preset = preset
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        preset = try? container.decodeIfPresent(String.self, forKey: .preset)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
    }
}

struct DottieToolsFileExtras: Codable, Equatable {
    var servers: [String: DottieMCPServerSettings] = [:]
    /// Servers Dottie added to Claude Code, by Claude Code name → fingerprint.
    var claudeCodeSynced: [String: String] = [:]
    /// Servers Dottie added to OpenMausBot, by name → fingerprint.
    var openMausBotSynced: [String: String] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        servers = (try? container.decodeIfPresent([String: DottieMCPServerSettings].self, forKey: .servers)) ?? [:]
        claudeCodeSynced = (try? container.decodeIfPresent([String: String].self, forKey: .claudeCodeSynced)) ?? [:]
        openMausBotSynced = (try? container.decodeIfPresent([String: String].self, forKey: .openMausBotSynced)) ?? [:]
    }
}

struct DottieToolsFile: Codable, Equatable {
    var mcpServers: [String: DottieMCPServerConfig] = [:]
    var dottie = DottieToolsFileExtras()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // One server Dottie can't read drops only itself.
        if let rawServers = try? container.decodeIfPresent([String: DottieLenient<DottieMCPServerConfig>].self, forKey: .mcpServers) {
            mcpServers = rawServers.compactMapValues(\.value)
        }
        dottie = (try? container.decodeIfPresent(DottieToolsFileExtras.self, forKey: .dottie)) ?? DottieToolsFileExtras()
    }

    static var folderURL: URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return applicationSupportURL.appendingPathComponent("Dottie", isDirectory: true)
    }

    static var fileURL: URL { folderURL.appendingPathComponent("tools.json") }
    static var toolCacheFileURL: URL { folderURL.appendingPathComponent("tools-cache.json") }

    static func load() -> DottieToolsFile {
        guard let fileData = try? Data(contentsOf: fileURL) else { return DottieToolsFile() }
        return (try? JSONDecoder().decode(DottieToolsFile.self, from: fileData)) ?? DottieToolsFile()
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.folderURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let fileData = try? encoder.encode(self) {
            try? fileData.write(to: Self.fileURL, options: .atomic)
        }
    }

    func isEnabled(_ serverName: String) -> Bool {
        dottie.servers[serverName]?.enabled ?? true
    }

    /// Servers that are switched on, by name.
    var enabledServers: [String: DottieMCPServerConfig] {
        mcpServers.filter { isEnabled($0.key) }
    }
}

/// Decodes a value, or nil instead of failing the whole file.
struct DottieLenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - ${NAME} placeholders

enum DottieToolsPlaceholders {
    /// The NAMEs of every ${NAME} in `text`.
    static func names(in text: String) -> [String] {
        var names: [String] = []
        var searchRange = text.startIndex..<text.endIndex
        while let openRange = text.range(of: "${", range: searchRange) {
            guard let closeRange = text.range(of: "}", range: openRange.upperBound..<text.endIndex) else { break }
            let name = String(text[openRange.upperBound..<closeRange.lowerBound])
            if isValidName(name) { names.append(name) }
            searchRange = closeRange.upperBound..<text.endIndex
        }
        return names
    }

    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !name.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return (CharacterSet.letters.contains(first) || first == "_")
            && name.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
    }

    /// Replaces each ${NAME} that `value(NAME)` knows; leaves the rest.
    static func fill(_ text: String, using value: (String) -> String?) -> String {
        var filledText = text
        for name in names(in: text) {
            if let replacement = value(name) {
                filledText = filledText.replacingOccurrences(of: "${\(name)}", with: replacement)
            }
        }
        return filledText
    }

    /// A name safe to use as an environment variable for a helper.
    static func helperVariableName(server: String, name: String) -> String {
        let cleanedServer = String(server.uppercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "_"
        })
        return "DOTTIE_\(cleanedServer)_\(name)"
    }
}

// MARK: - Keychain

/// Keys and tokens for connected apps, in the login Keychain. Read values
/// are remembered for the session so helpers don't hit the Keychain on every
/// turn.
enum DottieToolsKeychain {
    private static let service = "Dottie connected apps"
    private static let lock = NSLock()
    private static var cache: [String: String?] = [:]

    private static func account(server: String, name: String) -> String { "\(server)/\(name)" }

    static func value(server: String, name: String) -> String? {
        let accountName = account(server: server, name: name)
        lock.lock()
        if let cached = cache[accountName] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let value = status == errSecSuccess ? (item as? Data).map { String(decoding: $0, as: UTF8.self) } : nil
        lock.lock()
        cache[accountName] = .some(value)
        lock.unlock()
        return value
    }

    static func setValue(_ newValue: String?, server: String, name: String) {
        let accountName = account(server: server, name: name)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName
        ]
        SecItemDelete(baseQuery as CFDictionary)
        let trimmedValue = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedValue.isEmpty {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = Data(trimmedValue.utf8)
            addQuery[kSecAttrLabel as String] = "Dottie: \(server) \(name)"
            SecItemAdd(addQuery as CFDictionary, nil)
        }
        lock.lock()
        cache[accountName] = .some(trimmedValue.isEmpty ? nil : trimmedValue)
        lock.unlock()
    }

    static func removeAll(server: String, names: [String]) {
        for name in names {
            setValue(nil, server: server, name: name)
        }
    }
}

// MARK: - Filling in a server

extension DottieMCPServerConfig {
    /// The server with keys from the Keychain (then the environment) filled
    /// in, and the names it still needs.
    func filledIn(serverName: String) -> (config: DottieMCPServerConfig, missing: [String]) {
        var missing: [String] = []
        let environment = ProcessInfo.processInfo.environment
        let filled = mapStrings { text in
            DottieToolsPlaceholders.fill(text) { name in
                if let value = DottieToolsKeychain.value(server: serverName, name: name) { return value }
                if let value = environment[name] { return value }
                if !missing.contains(name) { missing.append(name) }
                return nil
            }
        }
        return (filled, missing)
    }

    /// A short fingerprint, so a sync can tell when a server changed.
    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
