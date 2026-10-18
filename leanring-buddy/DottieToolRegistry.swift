//
//  DottieToolRegistry.swift
//  leanring-buddy
//
//  One place for features to add tools without touching the voice client or
//  CompanionManager. A feature declares a DottieToolModule in its own file,
//  lists it in DottieToolModules.all, and its tools show up for Dottie's
//  voice, her helpers, or both. Its prompt lines join the voice prompt.
//
//  Parameters use Gemini's schema (OBJECT, STRING, …). Helpers that run on
//  OpenAI-style models get them through `jsonSchema(_:)`, which lowercases
//  the types.
//

import Foundation

/// A tool a feature gives Dottie's voice and/or her helpers.
struct DottieTool {
    enum Audience: Hashable { case voice, helpers }

    let name: String
    let description: String
    /// Gemini-style schema for the arguments, or nil for none.
    let parameters: [String: Any]?
    let audiences: Set<Audience>
    let run: @MainActor ([String: Any]) async -> String

    init(
        name: String,
        description: String,
        parameters: [String: Any]? = nil,
        audiences: Set<Audience> = [.voice, .helpers],
        run: @escaping @MainActor ([String: Any]) async -> String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.audiences = audiences
        self.run = run
    }

    /// The Gemini function declaration.
    var functionDeclaration: [String: Any] {
        var declaration: [String: Any] = ["name": name, "description": description]
        if let parameters { declaration["parameters"] = parameters }
        return declaration
    }
}

/// A feature that adds tools and, optionally, a few lines to the voice prompt.
@MainActor
protocol DottieToolModule {
    static var tools: [DottieTool] { get }
    /// Lines added to the voice prompt (keep them short), or "".
    static var voicePromptSection: String { get }
    /// Lines added to every helper's instructions, or "".
    static var helperPromptSection: String { get }
}

extension DottieToolModule {
    static var voicePromptSection: String { "" }
    static var helperPromptSection: String { "" }
}

@MainActor
enum DottieToolRegistry {
    static func tools(for audience: DottieTool.Audience) -> [DottieTool] {
        DottieToolModules.all.flatMap { $0.tools }.filter { $0.audiences.contains(audience) }
    }

    static func functionDeclarations(for audience: DottieTool.Audience) -> [[String: Any]] {
        tools(for: audience).map(\.functionDeclaration)
    }

    static func handles(_ name: String, for audience: DottieTool.Audience) -> Bool {
        tools(for: audience).contains { $0.name == name }
    }

    /// Runs a registered tool, or returns nil when no module has it.
    static func run(_ name: String, arguments: [String: Any], for audience: DottieTool.Audience) async -> String? {
        guard let tool = tools(for: audience).first(where: { $0.name == name }) else { return nil }
        return await tool.run(arguments)
    }

    static var voicePromptSections: String {
        joinedSections(DottieToolModules.all.map { $0.voicePromptSection })
    }

    static var helperPromptSections: String {
        joinedSections(DottieToolModules.all.map { $0.helperPromptSection })
    }

    private static func joinedSections(_ sections: [String]) -> String {
        sections.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Gemini's schema as JSON Schema (lowercase types, no Gemini-only keys).
    nonisolated static func jsonSchema(_ schema: Any) -> Any {
        if let array = schema as? [Any] { return array.map(jsonSchema) }
        guard let dictionary = schema as? [String: Any] else { return schema }
        var converted: [String: Any] = [:]
        for (key, value) in dictionary {
            switch key {
            case "type":
                converted["type"] = (value as? String)?.lowercased() ?? value
            case "nullable", "propertyOrdering":
                continue
            default:
                converted[key] = jsonSchema(value)
            }
        }
        return converted
    }
}

// MARK: - Argument helpers

extension Dictionary where Key == String, Value == Any {
    func dottieString(_ key: String) -> String? {
        let text = (self[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    func dottieBool(_ key: String) -> Bool? {
        (self[key] as? Bool) ?? (self[key] as? NSNumber)?.boolValue
    }

    func dottieNumber(_ key: String) -> Double? {
        (self[key] as? NSNumber)?.doubleValue ?? (self[key] as? String).flatMap(Double.init)
    }
}
