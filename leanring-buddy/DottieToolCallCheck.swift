//
//  DottieToolCallCheck.swift
//  leanring-buddy
//
//  Checks a tool call the way Dottie would take it, without doing it: is
//  the tool real, are its arguments the right shape for its declaration,
//  and would the tool's own checker take it (a drawing's steps, for one).
//  The pre-ship check runs every tool call the real model makes for a set
//  of everyday asks through this, so a release where Live's calls get
//  refused (1.0.75's supply and demand drawing) stops before it ships.
//

import Foundation

@MainActor
enum DottieToolCallCheck {

    struct ToolCall {
        let name: String
        let arguments: [String: Any]
    }

    /// Everything wrong with one call, or nothing when Dottie would take it.
    static func problems(with toolCall: ToolCall, everyDeclaration: [[String: Any]]) -> [String] {
        if toolCall.name == DottieVoiceToolCatalog.useToolFunctionName {
            return problemsWithUseTool(arguments: toolCall.arguments, everyDeclaration: everyDeclaration)
        }
        let allDeclarations = everyDeclaration + [
            DottieVoiceToolCatalog.findToolFunctionDeclaration,
            DottieVoiceToolCatalog.useToolFunctionDeclaration
        ]
        guard let declaration = allDeclarations.first(where: { ($0["name"] as? String) == toolCall.name }) else {
            return ["\(toolCall.name): no tool has this name"]
        }
        var foundProblems: [String] = []
        if let parameterSchema = declaration["parameters"] as? [String: Any] {
            foundProblems += schemaProblems(value: toolCall.arguments, schema: parameterSchema, path: toolCall.name)
        }
        foundProblems += toolSpecificProblems(with: toolCall)
        return foundProblems
    }

    /// use_tool carries the real tool's name and its arguments as JSON text.
    private static func problemsWithUseTool(arguments: [String: Any], everyDeclaration: [[String: Any]]) -> [String] {
        guard let innerToolName = arguments["name"] as? String, !innerToolName.isEmpty else {
            return ["use_tool: no tool name"]
        }
        guard let innerArguments = DottieVoiceToolCatalog.parsedToolArguments(from: arguments["arguments_json"]) else {
            return ["use_tool \(innerToolName): arguments_json isn't a JSON object"]
        }
        return problems(with: ToolCall(name: innerToolName, arguments: innerArguments), everyDeclaration: everyDeclaration)
    }

    /// The checks a tool runs itself before doing anything.
    private static func toolSpecificProblems(with toolCall: ToolCall) -> [String] {
        guard toolCall.name == DottieTeaching.functionName else { return [] }
        guard let plan = DottieTeaching.Plan(arguments: toolCall.arguments) else {
            return ["\(toolCall.name): no steps Dottie can read"]
        }
        return plan.problems.map { "\(toolCall.name): \($0)" }
    }

    /// Whether a value fits a Gemini declaration schema (OBJECT, ARRAY,
    /// STRING with enum, NUMBER, INTEGER, BOOLEAN). Fields the schema
    /// doesn't name are let through, as the app ignores them.
    static func schemaProblems(value: Any, schema: [String: Any], path: String) -> [String] {
        let expectedType = (schema["type"] as? String)?.uppercased() ?? ""
        switch expectedType {
        case "OBJECT":
            guard let object = value as? [String: Any] else { return ["\(path): should be an object"] }
            var foundProblems: [String] = []
            let requiredFields = schema["required"] as? [String] ?? []
            for requiredField in requiredFields where object[requiredField] == nil {
                foundProblems.append("\(path): missing \(requiredField)")
            }
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for (fieldName, fieldValue) in object {
                guard let fieldSchema = properties[fieldName] as? [String: Any] else { continue }
                foundProblems += schemaProblems(value: fieldValue, schema: fieldSchema, path: "\(path).\(fieldName)")
            }
            return foundProblems
        case "ARRAY":
            guard let array = value as? [Any] else { return ["\(path): should be a list"] }
            guard let itemSchema = schema["items"] as? [String: Any] else { return [] }
            return array.enumerated().flatMap { itemIndex, item in
                schemaProblems(value: item, schema: itemSchema, path: "\(path)[\(itemIndex)]")
            }
        case "STRING":
            guard let text = value as? String else { return ["\(path): should be text"] }
            if let allowedValues = schema["enum"] as? [String], !allowedValues.contains(text) {
                return ["\(path): \"\(text)\" isn't one of \(allowedValues.joined(separator: ", "))"]
            }
            return []
        case "NUMBER", "INTEGER":
            guard isNumberBox(value) else { return ["\(path): should be a number"] }
            return []
        case "BOOLEAN":
            guard value is Bool else { return ["\(path): should be true or false"] }
            return []
        default:
            return []
        }
    }

    /// JSON numbers arrive as NSNumber, which Swift also lets cast to Bool;
    /// a real boolean is a CFBoolean.
    private static func isNumberBox(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    /// The tool calls in a streamed /chat answer ("data: {…}" lines).
    static func toolCalls(inStreamedAnswer streamedAnswer: String) -> [ToolCall] {
        streamedAnswer
            .components(separatedBy: .newlines)
            .compactMap { line -> [ToolCall]? in
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard trimmedLine.hasPrefix("data:") else { return nil }
                let payloadText = trimmedLine.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                guard let payload = try? JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [String: Any],
                      let candidates = payload["candidates"] as? [[String: Any]] else { return nil }
                return candidates.flatMap { candidate -> [ToolCall] in
                    let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                    return parts.compactMap { part in
                        guard let functionCall = part["functionCall"] as? [String: Any],
                              let functionName = functionCall["name"] as? String else { return nil }
                        return ToolCall(name: functionName, arguments: functionCall["args"] as? [String: Any] ?? [:])
                    }
                }
            }
            .flatMap { $0 }
    }
}
