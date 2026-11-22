//
//  PreShipLiveCheckTests.swift
//  leanring-buddyTests
//
//  The pre-ship check: everyday asks for each feature go to the real model
//  through the Worker's /chat the way a spoken request really goes now
//  (`"provider": "request"`, the request brain's own prompt and its short
//  tool list, DottieTalkerProtocol), and every tool call that comes back is
//  checked the way the app would take it (DottieToolCallCheck). A refused
//  or malformed call, or a forbidden one (a screen job for "open notes"),
//  fails the check, and the release workflow doesn't ship. It used to send
//  the old Live prompt and tool list, so it never saw the request brain
//  turning Mac actions into screen jobs.
//
//  Runs only when DOTTIE_PRESHIP_WORKER_URL is set (the Pre-ship check
//  workflow passes it as TEST_RUNNER_DOTTIE_PRESHIP_WORKER_URL); in normal
//  test runs it does nothing, since tests never reach the internet.
//
//  It can't hear a voice or see a real screen: /chat's text model stands
//  in for Live, and clicks still need checking on a Mac.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct PreShipLiveCheckTests {

    /// One everyday ask and the tools that would be a fitting answer. An
    /// empty list means any answer is fine (a question back counts).
    struct EverydayAsk {
        let feature: String
        let words: String
        let fittingTools: Set<String>
        /// Tools that must never answer this ask; calling one fails the check.
        var forbiddenTools: Set<String> = []
    }

    /// An everyday Mac action must never become a screen job.
    static let macActionForbiddenTools: Set<String> = ["do_task_on_screen", "click_on_screen"]

    static let everydayAsks: [EverydayAsk] = [
        EverydayAsk(feature: "teaching", words: "explain how a supply and demand curve works", fittingTools: ["explain_on_screen", "write_notes"]),
        EverydayAsk(feature: "teaching", words: "draw a right triangle and show me which side is the hypotenuse", fittingTools: ["explain_on_screen"]),
        EverydayAsk(feature: "teaching", words: "graph y equals x squared minus 3", fittingTools: ["explain_on_screen"]),
        EverydayAsk(feature: "teaching", words: "draw a horse", fittingTools: ["explain_on_screen"]),
        EverydayAsk(feature: "notes", words: "write me notes on photosynthesis", fittingTools: ["write_notes"]),
        EverydayAsk(feature: "screen", words: "click on my first email", fittingTools: ["click_on_screen", "point_at_element", "do_task_on_screen"]),
        EverydayAsk(feature: "screen", words: "move this task to saturday in my study planner", fittingTools: ["do_task_on_screen"]),
        EverydayAsk(feature: "screen", words: "check my emails", fittingTools: []),
        EverydayAsk(feature: "mac", words: "remind me to call mom at 5 pm", fittingTools: ["add_reminder"]),
        EverydayAsk(feature: "mac", words: "open youtube", fittingTools: ["open_url", "run_applescript", "control_device", "quick_mac_action"]),
        EverydayAsk(feature: "mac", words: "open spotify and move it to the left half", fittingTools: ["quick_mac_action", "run_applescript", "control_device", "do_task_on_screen"]),
        EverydayAsk(feature: "mac", words: "open my downloads folder", fittingTools: DottieTalkerProtocol.macToolNames, forbiddenTools: macActionForbiddenTools),
        EverydayAsk(feature: "mac", words: "open notes", fittingTools: DottieTalkerProtocol.macToolNames, forbiddenTools: macActionForbiddenTools),
        EverydayAsk(feature: "mac", words: "open my bull and shit folder", fittingTools: DottieTalkerProtocol.macToolNames, forbiddenTools: macActionForbiddenTools),
        EverydayAsk(feature: "mac", words: "pause the music", fittingTools: DottieTalkerProtocol.macToolNames, forbiddenTools: macActionForbiddenTools),
        EverydayAsk(feature: "mac", words: "copy the terminal command that lists files to my clipboard", fittingTools: ["copy_to_clipboard"]),
        EverydayAsk(feature: "search", words: "what's the weather in Dhaka right now", fittingTools: ["search_web"]),
        EverydayAsk(feature: "helpers", words: "make me a website for my coffee shop", fittingTools: ["start_helper"]),
        EverydayAsk(feature: "hidden tools", words: "turn your cursor into a cat", fittingTools: ["find_tool", "use_tool"])
    ]

    private struct Outcome {
        let ask: EverydayAsk
        let toolCalls: [DottieToolCallCheck.ToolCall]
        let problems: [String]
        let missedFittingTool: Bool
        let failedToAsk: String?
    }

    @Test func everyEverydayAskGetsToolCallsDottieWouldTake() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let workerAddress = environment["DOTTIE_PRESHIP_WORKER_URL"], !workerAddress.isEmpty,
              let chatURL = URL(string: workerAddress.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat") else {
            return
        }
        let sharedSecret = environment["DOTTIE_PRESHIP_SECRET"] ?? ""
        let voicePrompt = DottieTalkerProtocol.requestSystemPrompt(personalityLine: DottiePersonality.cheekyFriend.promptSection, profile: "")
        let declarations = DottieTalkerProtocol.requestToolDeclarations(
            from: DottieVoiceTools.everyFunctionDeclaration,
            findAndUseDeclarations: [DottieVoiceToolCatalog.findToolFunctionDeclaration, DottieVoiceToolCatalog.useToolFunctionDeclaration]
        )

        var outcomes: [Outcome] = []
        for ask in Self.everydayAsks {
            outcomes.append(await check(ask, chatURL: chatURL, sharedSecret: sharedSecret,
                                        voicePrompt: voicePrompt, declarations: declarations))
        }
        writeReport(outcomes, to: environment["DOTTIE_PRESHIP_REPORT"])

        for outcome in outcomes {
            if let failedToAsk = outcome.failedToAsk {
                Issue.record("\(outcome.ask.words): couldn't ask the model (\(failedToAsk))")
            }
            for problem in outcome.problems {
                Issue.record("\(outcome.ask.feature), \"\(outcome.ask.words)\": \(problem)")
            }
        }
        // The model picks differently from run to run, so one ask without a
        // fitting tool is a note in the report; most of them missing is a
        // real change in how Dottie answers.
        let missedCount = outcomes.filter(\.missedFittingTool).count
        #expect(missedCount * 3 <= outcomes.count, "\(missedCount) of \(outcomes.count) asks got no fitting tool")
    }

    private func check(_ ask: EverydayAsk, chatURL: URL, sharedSecret: String,
                       voicePrompt: String, declarations: [[String: Any]]) async -> Outcome {
        let body = DottieTalkerProtocol.requestBody(
            systemPrompt: voicePrompt,
            conversation: [DottieTalkerProtocol.requestUserTurn(transcript: ask.words, labeledImages: [])],
            toolDeclarations: declarations
        )
        var request = URLRequest(url: chatURL, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sharedSecret, forHTTPHeaderField: "x-clicky-secret")
        request.setValue("preship-check", forHTTPHeaderField: "x-dottie-install")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var lastFailure = "no answer"
        // One retry: a busy model is the Worker's problem, not Dottie's.
        for _ in 0..<2 {
            do {
                let (answerData, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard statusCode == 200 else {
                    lastFailure = "HTTP \(statusCode): \(String(decoding: answerData.prefix(300), as: UTF8.self))"
                    continue
                }
                let toolCalls = DottieToolCallCheck.toolCalls(inStreamedAnswer: String(decoding: answerData, as: UTF8.self))
                let problems = toolCalls.flatMap {
                    DottieToolCallCheck.problems(with: $0, everyDeclaration: DottieVoiceTools.everyFunctionDeclaration)
                } + Self.forbiddenCallProblems(toolCalls.map(\.name), for: ask)
                let missedFittingTool = !ask.fittingTools.isEmpty && !toolCalls.contains { ask.fittingTools.contains($0.name) }
                return Outcome(ask: ask, toolCalls: toolCalls, problems: problems, missedFittingTool: missedFittingTool, failedToAsk: nil)
            } catch {
                lastFailure = error.localizedDescription
            }
        }
        return Outcome(ask: ask, toolCalls: [], problems: [], missedFittingTool: false, failedToAsk: lastFailure)
    }

    /// A readable report for the workflow's summary: each ask, the tools
    /// called and anything wrong.
    private func writeReport(_ outcomes: [Outcome], to reportPath: String?) {
        guard let reportPath, !reportPath.isEmpty else { return }
        var lines = ["### Pre-ship check", "", "| Feature | Ask | Tools called | Result |", "|---|---|---|---|"]
        for outcome in outcomes {
            let calledTools = outcome.toolCalls.map(\.name).joined(separator: ", ")
            let result: String
            if let failedToAsk = outcome.failedToAsk {
                result = "couldn't ask: \(failedToAsk)"
            } else if !outcome.problems.isEmpty {
                result = "❌ " + outcome.problems.joined(separator: "; ")
            } else if outcome.missedFittingTool {
                result = "⚠️ no fitting tool"
            } else {
                result = "✅"
            }
            let cells = [outcome.ask.feature, outcome.ask.words, calledTools.isEmpty ? "(none)" : calledTools, result]
            lines.append("| " + cells.map { $0.replacingOccurrences(of: "|", with: "/") }.joined(separator: " | ") + " |")
        }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
    }

    /// One problem per forbidden tool the model called for this ask.
    static func forbiddenCallProblems(_ calledToolNames: [String], for ask: EverydayAsk) -> [String] {
        calledToolNames.filter { ask.forbiddenTools.contains($0) }.map { "called \($0), which must never answer this ask" }
    }

    // MARK: - The ask list itself (runs in every test run)

    @Test func aScreenJobForAMacActionIsAProblem() {
        let openNotes = EverydayAsk(feature: "mac", words: "open notes", fittingTools: ["quick_mac_action"], forbiddenTools: Self.macActionForbiddenTools)
        #expect(Self.forbiddenCallProblems(["do_task_on_screen"], for: openNotes).count == 1)
        #expect(Self.forbiddenCallProblems(["click_on_screen", "do_task_on_screen"], for: openNotes).count == 2)
        #expect(Self.forbiddenCallProblems(["quick_mac_action"], for: openNotes).isEmpty)
        #expect(Self.forbiddenCallProblems([], for: openNotes).isEmpty)
    }

    @Test func anAskWithoutForbiddenToolsTakesAnyTool() {
        let checkEmails = EverydayAsk(feature: "screen", words: "check my emails", fittingTools: [])
        #expect(Self.forbiddenCallProblems(["do_task_on_screen"], for: checkEmails).isEmpty)
    }

    @Test func everyMacActionAskForbidsScreenJobsAndHasMacToolsToUse() {
        let macActionAsks = Self.everydayAsks.filter { !$0.forbiddenTools.isEmpty }
        #expect(macActionAsks.count >= 3)
        for ask in macActionAsks {
            #expect(ask.forbiddenTools.contains("do_task_on_screen"), "\(ask.words) may become a screen job")
            #expect(ask.fittingTools.isDisjoint(with: ask.forbiddenTools), "\(ask.words) both fits and forbids a tool")
            // The request brain must actually be given a fitting tool.
            #expect(!ask.fittingTools.isDisjoint(with: DottieTalkerProtocol.requestToolNames), "\(ask.words) has no fitting tool on the request list")
        }
    }

    @Test func everyFittingToolIsARealTool() {
        let knownNames = Set((DottieVoiceTools.everyFunctionDeclaration.compactMap { $0["name"] as? String })
            + [DottieVoiceToolCatalog.findToolFunctionName, DottieVoiceToolCatalog.useToolFunctionName])
        for ask in Self.everydayAsks {
            for toolName in ask.fittingTools {
                #expect(knownNames.contains(toolName), "\(toolName) for \"\(ask.words)\" isn't a tool")
            }
        }
    }

    @Test func theAsksCoverEveryMainFeature() {
        let features = Set(Self.everydayAsks.map(\.feature))
        for feature in ["teaching", "notes", "screen", "mac", "search", "helpers", "hidden tools"] {
            #expect(features.contains(feature), "no ask for \(feature)")
        }
    }
}
