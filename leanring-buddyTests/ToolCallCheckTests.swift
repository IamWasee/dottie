//
//  ToolCallCheckTests.swift
//  leanring-buddyTests
//
//  Unit tests for DottieToolCallCheck, which the pre-ship check uses to
//  judge the real model's tool calls: unknown tools, missing or wrongly
//  typed arguments, values outside an enum, use_tool's inner call, the
//  drawing checker, and reading tool calls out of a streamed answer.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct ToolCallCheckTests {
    private let declarations: [[String: Any]] = [
        [
            "name": "add_reminder",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "title": ["type": "STRING"],
                    "minutes": ["type": "NUMBER"],
                    "urgent": ["type": "BOOLEAN"],
                    "list": ["type": "STRING", "enum": ["home", "work"]],
                    "tags": ["type": "ARRAY", "items": ["type": "STRING"]]
                ],
                "required": ["title"]
            ]
        ],
        DottieTeaching.functionDeclaration
    ]

    private func problems(_ name: String, _ arguments: [String: Any]) -> [String] {
        DottieToolCallCheck.problems(with: .init(name: name, arguments: arguments), everyDeclaration: declarations)
    }

    // MARK: - Names

    @Test func aGoodCallHasNoProblems() {
        #expect(problems("add_reminder", ["title": "call mom", "minutes": 30, "urgent": true, "list": "home", "tags": ["family"]]).isEmpty)
    }

    @Test func anUnknownToolIsAProblem() {
        #expect(problems("send_rocket", [:]) == ["send_rocket: no tool has this name"])
    }

    @Test func findToolAndUseToolAreAlwaysKnown() {
        #expect(problems("find_tool", ["what": "take a screenshot"]).isEmpty)
    }

    // MARK: - Arguments

    @Test func aMissingRequiredArgumentIsAProblem() {
        #expect(problems("add_reminder", ["minutes": 5]) == ["add_reminder: missing title"])
    }

    @Test func wrongTypesAreProblems() {
        #expect(problems("add_reminder", ["title": 5]) == ["add_reminder.title: should be text"])
        #expect(problems("add_reminder", ["title": "x", "minutes": "five"]) == ["add_reminder.minutes: should be a number"])
        #expect(problems("add_reminder", ["title": "x", "urgent": "yes"]) == ["add_reminder.urgent: should be true or false"])
        #expect(problems("add_reminder", ["title": "x", "tags": "family"]) == ["add_reminder.tags: should be a list"])
    }

    @Test func aBooleanIsNotANumber() {
        #expect(problems("add_reminder", ["title": "x", "minutes": true]) == ["add_reminder.minutes: should be a number"])
    }

    @Test func aValueOutsideTheEnumIsAProblem() {
        let found = problems("add_reminder", ["title": "x", "list": "school"])
        #expect(found.count == 1)
        #expect(found.first?.contains("isn't one of home, work") == true)
    }

    @Test func listItemsAreCheckedOneByOne() {
        #expect(problems("add_reminder", ["title": "x", "tags": ["ok", 3]]) == ["add_reminder.tags[1]: should be text"])
    }

    @Test func fieldsTheSchemaDoesNotNameAreLetThrough() {
        #expect(problems("add_reminder", ["title": "x", "mood": "happy"]).isEmpty)
    }

    // MARK: - use_tool

    @Test func useToolIsCheckedAsTheToolItRuns() {
        #expect(problems("use_tool", ["name": "add_reminder", "arguments_json": "{\"title\": \"call mom\"}"]).isEmpty)
        #expect(problems("use_tool", ["name": "add_reminder", "arguments_json": "{}"]) == ["add_reminder: missing title"])
    }

    @Test func useToolWithBrokenJSONOrNoNameIsAProblem() {
        #expect(problems("use_tool", ["name": "add_reminder", "arguments_json": "{title"]).first?.contains("isn't a JSON object") == true)
        #expect(problems("use_tool", ["arguments_json": "{}"]) == ["use_tool: no tool name"])
        #expect(problems("use_tool", ["name": "nope", "arguments_json": "{}"]) == ["nope: no tool has this name"])
    }

    // MARK: - Drawing

    @Test func aDrawingTheAppWouldRefuseIsAProblem() {
        let found = problems("explain_on_screen", ["steps": [["kind": "curve", "points": ["somewhere", "elsewhere"]]]])
        #expect(found.contains { $0.contains("neither") })
    }

    @Test func aDrawingTheAppTakesHasNoProblems() {
        let found = problems("explain_on_screen", ["steps": [
            ["kind": "axes", "points": ["(100, 900)", "(900, 100)"]],
            ["kind": "line", "points": ["150", "850", "850", "150"], "text": "Supply"]
        ]])
        #expect(found.isEmpty, "\(found)")
    }

    @Test func oneBadStepAmongGoodOnesIsDrawnSoItIsNoProblem() {
        // The 27 Nov pre-ship run: supply and demand with one plot step that had no function.
        let found = problems("explain_on_screen", ["steps": [
            ["kind": "axes", "points": ["100,900", "900,100"]],
            ["kind": "plot", "points": ["100,100", "900,900"], "text": ""],
            ["kind": "line", "points": ["150,200", "850,800"], "text": "Demand"],
            ["kind": "line", "points": ["150,800", "850,200"], "text": "Supply"]
        ]])
        #expect(found.isEmpty, "\(found)")
    }

    @Test func aDrawingThatLosesMostOfItsStepsIsAProblem() {
        let found = problems("explain_on_screen", ["steps": [
            ["kind": "axes", "points": ["100,900", "900,100"]],
            ["kind": "plot", "points": ["100,100", "900,900"], "text": "demand curve"],
            ["kind": "curve", "points": ["somewhere", "elsewhere"]]
        ]])
        #expect(found.count == 2)
        #expect(found.contains { $0.contains("function of x") })
    }

    @Test func halfTheStepsBadStillDraws() {
        let found = problems("explain_on_screen", ["steps": [
            ["kind": "axes", "points": ["100,900", "900,100"]],
            ["kind": "plot", "points": ["100,100", "900,900"], "text": "demand curve"]
        ]])
        #expect(found.isEmpty, "\(found)")
    }

    @Test func aDrawingWithNoStepsIsAProblem() {
        #expect(problems("explain_on_screen", [:]).contains("explain_on_screen: no steps Dottie can read"))
    }

    // MARK: - Reading a streamed answer

    @Test func toolCallsAreReadFromAStreamedAnswer() {
        let streamedAnswer = """
        data: {"candidates":[{"content":{"parts":[{"text":"okay"}]}}]}\r
        \r
        data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"add_reminder","args":{"title":"call mom"}}}]}}]}
        data: not json
        data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"find_tool"}}]}}]}
        """
        let toolCalls = DottieToolCallCheck.toolCalls(inStreamedAnswer: streamedAnswer)
        #expect(toolCalls.map(\.name) == ["add_reminder", "find_tool"])
        #expect(toolCalls.first?.arguments["title"] as? String == "call mom")
        #expect(toolCalls.last?.arguments.isEmpty == true)
    }

    @Test func anAnswerWithNoToolCallsGivesNone() {
        #expect(DottieToolCallCheck.toolCalls(inStreamedAnswer: "").isEmpty)
        #expect(DottieToolCallCheck.toolCalls(inStreamedAnswer: "data: {\"candidates\":[]}").isEmpty)
    }

    // MARK: - Integration: the real declarations Live gets

    @Test func everyDirectToolIsKnownToTheChecker() {
        for declaration in DottieVoiceTools.directFunctionDeclarations {
            let toolName = declaration["name"] as? String ?? ""
            let found = DottieToolCallCheck.problems(with: .init(name: toolName, arguments: [:]),
                                                     everyDeclaration: DottieVoiceTools.everyFunctionDeclaration)
            #expect(!found.contains { $0.contains("no tool has this name") }, "\(toolName) should be known")
        }
    }

    // MARK: - Speed

    @Test func checkingManyCallsIsQuick() {
        let startedAt = Date()
        for _ in 0..<2_000 {
            _ = problems("add_reminder", ["title": "call mom", "minutes": 30, "tags": ["a", "b"]])
        }
        #expect(Date().timeIntervalSince(startedAt) < 1.0)
    }
}
