//
//  VoiceToolsRunTests.swift
//  leanring-buddyTests
//
//  Running voice Dottie's tools by name (DottieVoiceTools.runTool), the way
//  the talker's Claude requests do now that Gemini Live is gone.
//

import Testing
@testable import Dottie

@MainActor
struct VoiceToolsRunTests {

    @Test func aToolThatDoesNotExistAnswersWithAnError() async {
        let response = await DottieVoiceTools().runTool(functionName: "make_coffee", arguments: [:])
        #expect((response["error"] as? String)?.contains("make_coffee") == true)
    }

    @Test func pointingSaysToUseAPointTag() async {
        let response = await DottieVoiceTools().runTool(functionName: "point_at_element", arguments: ["x": 500, "y": 300, "label": "Sign in"])
        #expect((response["result"] as? String)?.contains("[POINT:") == true)
    }

    @Test func pointingWithoutAPlaceIsAnError() async {
        let response = await DottieVoiceTools().runTool(functionName: "point_at_element", arguments: [:])
        #expect(response["error"] as? String == "x and y are required")
    }

    @Test func useToolNeedsAName() async {
        let response = await DottieVoiceTools().runTool(functionName: DottieVoiceToolCatalog.useToolFunctionName, arguments: [:])
        #expect((response["error"] as? String)?.contains("name was empty") == true)
    }

    @Test func useToolRefusesBadArgumentsJSON() async {
        let response = await DottieVoiceTools().runTool(
            functionName: DottieVoiceToolCatalog.useToolFunctionName,
            arguments: ["name": "search_web", "arguments_json": "{not json"]
        )
        #expect((response["error"] as? String)?.contains("arguments_json") == true)
    }

    @Test func aToolWithNoHandlerSetSaysItCannotRunNow() async {
        let response = await DottieVoiceTools().runTool(functionName: "guide_next", arguments: [:])
        #expect(response["result"] as? String == "no guide is running.")
    }

    @Test func aSetCallbackGetsTheCallAndItsAnswerComesBack() async {
        let voiceTools = DottieVoiceTools()
        var startedGoal: String?
        voiceTools.onStartGuide = { goal, _ in
            startedGoal = goal
            return "guide started"
        }
        let response = await voiceTools.runTool(functionName: "guide_user", arguments: ["goal": "add a sound effect"])
        #expect(startedGoal == "add a sound effect")
        #expect(response["result"] as? String == "guide started")
    }
}
