//
//  QuickMacActionTests.swift
//  leanring-buddyTests
//
//  quick_mac_action: voice Dottie and screen jobs hand "open Spotify",
//  "move this window left" or "volume 30" to the instant lane and Needle
//  mid-job, instead of doing it from screenshots.
//

import Foundation
import Testing
@testable import Dottie

@MainActor
struct QuickMacActionTests {
    // MARK: - Which plans a model may run

    @Test func everydayPlansMayRunFromAModel() {
        #expect(DottieQuickMacActionPlanKind.instantCommands.mayRunFromAModel)
        #expect(DottieQuickMacActionPlanKind.learnedShortcut.mayRunFromAModel)
        #expect(DottieQuickMacActionPlanKind.toolSteps.mayRunFromAModel)
    }

    @Test func replaysAndNamingShortcutsNeverRunFromAModel() {
        #expect(!DottieQuickMacActionPlanKind.replayPhrase.mayRunFromAModel)
        #expect(!DottieQuickMacActionPlanKind.saveNamedShortcut.mayRunFromAModel)
    }

    @Test func eachPlanMapsToItsKind() {
        let appPlan = DottieInstantLane.Plan.instantCommands([.openApp(appURL: URL(fileURLWithPath: "/Applications/Notes.app"), appName: "Notes")])
        #expect(DottieQuickMacAction.kind(of: appPlan) == .instantCommands)
        #expect(DottieQuickMacAction.kind(of: .saveNamedShortcut(name: "focus", commandTexts: ["open notes"])) == .saveNamedShortcut)
        let reminderStep = DottieLearnedShortcut.Step(functionName: "add_reminder", arguments: ["title": "call mom"])
        #expect(DottieQuickMacAction.kind(of: .toolSteps([reminderStep])) == .toolSteps)
    }

    // MARK: - The action text

    @Test func aShortActionIsUsedTrimmed() {
        #expect(DottieQuickMacAction.usableActionText(["action": "  open Spotify \n"]) == "open Spotify")
        #expect(DottieQuickMacAction.usableActionText(["action": "move this window to the left"]) == "move this window to the left")
    }

    @Test func missingEmptyOrWrongTypeIsRefused() {
        #expect(DottieQuickMacAction.usableActionText([:]) == nil)
        #expect(DottieQuickMacAction.usableActionText(["action": "   "]) == nil)
        #expect(DottieQuickMacAction.usableActionText(["action": 42]) == nil)
    }

    @Test func aWholeJobIsNotAQuickAction() {
        let longJob = "scroll down and find the free days then move all of the tasks from friday onto them evenly"
        #expect(DottieQuickMacAction.usableActionText(["action": longJob]) == nil)
        let twelveWords = Array(repeating: "word", count: 12).joined(separator: " ")
        #expect(DottieQuickMacAction.usableActionText(["action": twelveWords]) == twelveWords)
    }

    @Test func performingNothingSaysToDoItTheUsualWay() async {
        let result = await DottieQuickMacAction.perform(arguments: ["action": ""])
        #expect(result.hasPrefix("error:"))
        #expect(result.contains("usual way"))
    }

    // MARK: - Where the tool shows up

    @Test func voiceDottieHasItUpFront() {
        #expect(DottieVoiceToolCatalog.directFunctionNames.contains(DottieQuickMacAction.functionName))
        #expect(DottieToolRegistry.handles(DottieQuickMacAction.functionName, for: .voice))
        let declaration = DottieToolRegistry.functionDeclarations(for: .voice).first { ($0["name"] as? String) == DottieQuickMacAction.functionName }
        let parameters = declaration?["parameters"] as? [String: Any]
        #expect(parameters?["required"] as? [String] == ["action"])
    }

    @Test func voicePromptTellsDottieWhenToUseIt() {
        #expect(DottieToolRegistry.voicePromptSections.contains("quick_mac_action"))
    }

    @Test func screenJobsCanUseIt() {
        let names = DottieScreenTaskRunner.functionDeclarations.compactMap { $0["name"] as? String }
        #expect(names.contains(DottieQuickMacAction.functionName))
        #expect(names.contains("open_app"), "the screen job's own way stays as the fallback")
    }

    @Test func aRefusedVoiceCallGoesThroughTheRegistry() async {
        let result = await DottieToolRegistry.run(DottieQuickMacAction.functionName, arguments: [:], for: .voice)
        #expect(result?.hasPrefix("error:") == true)
    }

    @Test func checkingActionTextIsQuick() {
        let startedAt = Date()
        var usableCount = 0
        for index in 0..<20_000 where DottieQuickMacAction.usableActionText(["action": "open app number \(index)"]) != nil {
            usableCount += 1
        }
        #expect(usableCount == 20_000)
        #expect(Date().timeIntervalSince(startedAt) < 1.0)
    }
}
