//
//  TalkerTests.swift
//  leanring-buddyTests
//
//  The talker (Groq) and the request brain (Claude): what each is sent,
//  how Groq's "REQUEST" is read, the short history and tool list that keep
//  tokens down, and reading text and tool calls back from the Worker.
//

import Foundation
import Testing
@testable import Dottie

struct TalkerTests {
    @Test func aMadeUpToolCallAroundRequestIsARequest() {
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: #"{"name":"assistant","arguments":"REQUEST"}"#) == .request(needsScreen: false))
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: #"{"name": "assistant<|channel|>final", "arguments": REQUEST.}"#) == .request(needsScreen: false))
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: #"{"name":"assistant","arguments":"REQUEST SCREEN"}"#) == .request(needsScreen: true))
    }

    @Test func wordsInsideAMadeUpCallAreSaidPlainly() {
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: #"{"name":"assistant","arguments":"hi! how can i help?"}"#) == .say("hi! how can i help?"))
    }

    @Test func leakedMarkupIsNeverSpoken() {
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: "<|channel|>final hello") == .request(needsScreen: false))
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: #"{"answer": 3}"#) == .request(needsScreen: false))
        #expect(DottieTalkerProtocol.unwrappedToolCallText("just words") == "just words")
    }

    private let exchanges: [(userTranscript: String, assistantResponse: String)] = (1...6).map { number in
        (userTranscript: "question \(number)", assistantResponse: "answer \(number)")
    }

    @Test func smallTalkIsSaidAsIs() {
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: "  doing great, thanks!  ") == .say("doing great, thanks!"))
    }

    @Test func requestWordHandsTheTurnOverWithOrWithoutTheScreen() {
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: "REQUEST") == .request(needsScreen: false))
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: "request screen") == .request(needsScreen: true))
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: "REQUEST. SCREEN") == .request(needsScreen: true))
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: "") == .request(needsScreen: false))
    }

    @Test func aWrittenPlanGoesToClaudeWithTheScreen() {
        let plan = "**Here's the plan**\n\n1. Open Calendar.\n2. Find the event.\n3. Drag it to Saturday."
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: plan) == .request(needsScreen: true))
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: "- open calendar\n- drag it") == .request(needsScreen: true))
        #expect(DottieTalkerProtocol.looksLikeAPlan("1) open it\n2) move it"))
    }

    @Test func sayingItCantDoSomethingGoesToClaude() {
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: "I can't draw on your screen, but I can open an app.") == .request(needsScreen: true))
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: "sorry, i’m unable to do that") == .request(needsScreen: true))
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: "you can't go wrong with pizza") == .say("you can't go wrong with pizza"))
        #expect(DottieTalkerProtocol.talkerSystemPrompt(personalityLine: "").contains("never say you can't do something"))
    }

    @Test func oneNumberOrOneLineIsStillTalk() {
        #expect(!DottieTalkerProtocol.looksLikeAPlan("i'd say 2. maybe 3 if you're feeling brave!"))
        #expect(!DottieTalkerProtocol.looksLikeAPlan("1. that's my favorite number"))
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: "ha, good one") == .say("ha, good one"))
    }

    @Test func promptsSendDoingToClaudeAndClaudeToScreenJobs() {
        #expect(DottieTalkerProtocol.talkerSystemPrompt(personalityLine: "").contains("never write steps or a plan"))
        let requestPrompt = DottieTalkerProtocol.requestSystemPrompt(personalityLine: "", profile: "")
        #expect(requestPrompt.contains("do_task_on_screen"))
        #expect(requestPrompt.contains("never tell them to do it themselves"))
        #expect(requestPrompt.contains("answer only what they asked"))
        #expect(DottieTalkerProtocol.talkerSystemPrompt(personalityLine: "").contains("answer only what they asked"))
    }

    @Test func aSentenceThatOnlyMentionsRequestsIsStillTalk() {
        #expect(DottieTalkerProtocol.decision(fromTalkerAnswer: "requests are fine, ask away") == .say("requests are fine, ask away"))
    }

    @Test func talkerGetsWordsOnlyAShortHistoryAndASmallAnswer() throws {
        let body = DottieTalkerProtocol.talkerRequestBody(transcript: "hey", exchanges: exchanges, personalityLine: "you're dottie")
        #expect(body["provider"] as? String == "talk")
        let contents = try #require(body["contents"] as? [[String: Any]])
        #expect(contents.count == DottieTalkerProtocol.talkerExchangeCount * 2 + 1)
        let bodyText = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        #expect(!bodyText.contains("inlineData"))
        #expect(!bodyText.contains("question 3"))
        #expect(bodyText.contains("question 4"))
        let generationConfig = try #require(body["generationConfig"] as? [String: Any])
        #expect(generationConfig["maxOutputTokens"] as? Int == DottieTalkerProtocol.talkerAnswerTokenLimit)
    }

    @Test func rememberedLinesAreCutShort() throws {
        let longExchange = [(userTranscript: String(repeating: "a", count: 2000), assistantResponse: "ok")]
        let contents = DottieTalkerProtocol.historyContents(longExchange, count: 3)
        let firstPart = try #require((contents.first?["parts"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(firstPart.count <= DottieTalkerProtocol.rememberedLineCharacterLimit + 1)
    }

    @Test func talkerPromptStaysShort() {
        #expect(DottieTalkerProtocol.talkerSystemPrompt(personalityLine: "").count < 900)
        #expect(DottieTalkerProtocol.requestSystemPrompt(personalityLine: "", profile: "").count < 1300)
    }

    @Test func requestPromptAddsTheProfileOnlyWhenThereIsOne() {
        #expect(!DottieTalkerProtocol.requestSystemPrompt(personalityLine: "", profile: "").contains("what you know"))
        #expect(DottieTalkerProtocol.requestSystemPrompt(personalityLine: "", profile: "name: celly").contains("name: celly"))
    }

    @Test func requestBodyGoesToClaudeWithItsTools() throws {
        let body = DottieTalkerProtocol.requestBody(systemPrompt: "rules", conversation: [["role": "user", "parts": [["text": "go"]]]], toolDeclarations: [["name": "search_web"]])
        #expect(body["provider"] as? String == "request")
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect((tools.first?["functionDeclarations"] as? [[String: Any]])?.first?["name"] as? String == "search_web")
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test func userTurnPutsLabeledScreensBeforeTheWords() throws {
        let turn = DottieTalkerProtocol.requestUserTurn(transcript: "what's this?", labeledImages: [(data: Data([1, 2]), label: "screen 1")])
        let parts = try #require(turn["parts"] as? [[String: Any]])
        #expect(parts.count == 3)
        #expect(parts[0]["text"] as? String == "screen 1")
        #expect((parts[1]["inlineData"] as? [String: String])?["data"] == Data([1, 2]).base64EncodedString())
        #expect(parts[2]["text"] as? String == "what's this?")
        #expect(DottieTalkerProtocol.requestUserTurn(transcript: "hi", labeledImages: []).count == 2)
    }

    @Test func toolResultsComeBackInOrder() throws {
        let turn = DottieTalkerProtocol.toolResultsTurn([("search_web", ["result": "a"]), ("remember", ["error": "b"])])
        let parts = try #require(turn["parts"] as? [[String: Any]])
        #expect((parts[0]["functionResponse"] as? [String: Any])?["name"] as? String == "search_web")
        #expect((parts[1]["functionResponse"] as? [String: Any])?["name"] as? String == "remember")
    }

    @Test func readsTextAndToolCallsFromTheWorkersEvents() {
        let events = """
        data: {"candidates":[{"content":{"role":"model","parts":[{"text":"on it"},{"functionCall":{"name":"start_helper","args":{"task":"build a site"}}}]}}]}\r
        \r
        data: {"candidates":[{"content":{"parts":[{"text":" now","thought":false},{"text":"hidden","thought":true}]}}]}

        """
        let answer = DottieTalkerProtocol.brainAnswer(fromServerSentEvents: Data(events.utf8))
        #expect(answer.text == "on it now")
        #expect(answer.functionCalls.count == 1)
        #expect(answer.functionCalls.first?.name == "start_helper")
        #expect(answer.functionCalls.first?.arguments["task"] as? String == "build a site")
        #expect((answer.modelContent?["parts"] as? [[String: Any]])?.count == 4)
    }

    @Test func emptyOrBrokenEventsGiveAnEmptyAnswer() {
        let answer = DottieTalkerProtocol.brainAnswer(fromServerSentEvents: Data("data: not json\n\n: ping\n".utf8))
        #expect(answer.text.isEmpty)
        #expect(answer.functionCalls.isEmpty)
        #expect(answer.modelContent == nil)
    }

    @Test func requestToolsAreTheShortListPlusFindAndUse() {
        let every: [[String: Any]] = [["name": "search_web"], ["name": "point_at_element"], ["name": "send_to_higher_model"], ["name": "game"], ["description": "nameless"]]
        let declared = DottieTalkerProtocol.requestToolDeclarations(from: every, findAndUseDeclarations: [["name": "find_tool"], ["name": "use_tool"]])
        #expect(declared.compactMap { $0["name"] as? String } == ["search_web", "find_tool", "use_tool"])
    }

    @Test func everyShortListToolIsARealVoiceTool() async {
        let realNames = await MainActor.run { Set(DottieVoiceTools.everyFunctionDeclaration.compactMap { $0["name"] as? String }) }
        for toolName in DottieTalkerProtocol.requestToolNames {
            #expect(realNames.contains(toolName), "\(toolName) isn't one of voice Dottie's tools")
        }
    }
}
