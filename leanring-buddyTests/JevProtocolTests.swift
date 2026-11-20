//
//  JevProtocolTests.swift
//  leanring-buddyTests
//
//  Jev's requests and answers: box and yes/no questions, reading boxes
//  (nested or flat, refused when unsure or out of range), picture sizes Jev
//  takes, the "clearly not done" line and which click labels are worth asking.
//

import Foundation
import Testing
@testable import Dottie

struct JevProtocolTests {
    private func answer(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func boxRequestCarriesThePictureTheTargetAndTheAsk() {
        let body = DottieJevProtocol.boxRequestBody(target: "the first email", userContext: "open my newest mail", imageJPEGBase64: "abc")
        let assets = body["assets"] as? [String: [String: String]]
        #expect(assets?["screen"]?["type"] == "image")
        #expect(assets?["screen"]?["format"] == "jpeg")
        #expect(assets?["screen"]?["data_base64"] == "abc")
        let question = (body["questions"] as? [String: [String: String]])?["target"]
        #expect(question?["type"] == "box")
        #expect(question?["instructions"]?.contains("the first email") == true)
        #expect((body["state"] as? String)?.contains("open my newest mail") == true)
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test func boxRequestWithoutContextStillHasAState() {
        let body = DottieJevProtocol.boxRequestBody(target: "Send", userContext: nil, imageJPEGBase64: "abc")
        #expect((body["state"] as? String) == "A screenshot of a Mac screen.")
    }

    @Test func statementRequestIsAYesNoQuestion() {
        let body = DottieJevProtocol.statementRequestBody(statement: "the inbox is empty", imageJPEGBase64: "abc")
        let question = (body["questions"] as? [String: [String: String]])?["statement"]
        #expect(question?["type"] == "noul")
        #expect(question?["instructions"]?.contains("the inbox is empty") == true)
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test func readsANestedBoxAndTurnsItInto0To1000() throws {
        let data = answer(["answers": ["target": ["type": "box", "box": ["top": 0.1, "bottom": 0.2, "left": 0.3, "right": 0.5], "confidence": 0.9]]])
        let box = try #require(DottieJevProtocol.box(fromAnswer: data))
        #expect(box.confidence == 0.9)
        let normalized = box.normalizedBox
        #expect(abs(normalized.ymin - 100) < 0.001 && abs(normalized.xmin - 300) < 0.001)
        #expect(abs(normalized.ymax - 200) < 0.001 && abs(normalized.xmax - 500) < 0.001)
    }

    @Test func readsAFlatBox() {
        let data = answer(["answers": ["target": ["top": 0.4, "bottom": 0.6, "left": 0.4, "right": 0.6, "confidence": 0.7]]])
        #expect(DottieJevProtocol.box(fromAnswer: data)?.top == 0.4)
    }

    @Test func refusesUnsureEmptyOutOfRangeOrMissingBoxes() {
        let unsure = answer(["answers": ["target": ["box": ["top": 0.1, "bottom": 0.2, "left": 0.3, "right": 0.5], "confidence": 0.3]]])
        let noConfidence = answer(["answers": ["target": ["box": ["top": 0.1, "bottom": 0.2, "left": 0.3, "right": 0.5]]]])
        let upsideDown = answer(["answers": ["target": ["box": ["top": 0.5, "bottom": 0.2, "left": 0.3, "right": 0.5], "confidence": 0.9]]])
        let outOfRange = answer(["answers": ["target": ["box": ["top": 0.1, "bottom": 1.2, "left": 0.3, "right": 0.5], "confidence": 0.9]]])
        let otherQuestion = answer(["answers": ["done": ["noul": 0.9]]])
        for data in [unsure, noConfidence, upsideDown, outOfRange, otherQuestion, Data("not json".utf8), answer(["error": "x"])] {
            #expect(DottieJevProtocol.box(fromAnswer: data) == nil)
        }
    }

    @Test func readsTheChanceAStatementIsTrue() {
        #expect(DottieJevProtocol.probability(fromAnswer: answer(["answers": ["statement": ["type": "noul", "noul": 0.97]]])) == 0.97)
        #expect(DottieJevProtocol.probability(fromAnswer: answer(["answers": ["statement": ["probability": 0.1]]])) == 0.1)
        #expect(DottieJevProtocol.probability(fromAnswer: answer(["answers": ["statement": ["noul": 3]]])) == nil)
        #expect(DottieJevProtocol.probability(fromAnswer: answer(["answers": [:]])) == nil)
    }

    @Test func onlyAClearNoHoldsAFinishBack() {
        #expect(DottieJevProtocol.clearlyNotDone(probability: 0.05))
        #expect(!DottieJevProtocol.clearlyNotDone(probability: 0.2))
        #expect(!DottieJevProtocol.clearlyNotDone(probability: 0.6))
    }

    @Test func picturesAreShrunkToJevsLimitsOrRefused() throws {
        let retina = try #require(DottieJevProtocol.sendableSize(width: 2880, height: 1800))
        #expect(retina.width == 1568)
        #expect(retina.height == 980)
        let small = try #require(DottieJevProtocol.sendableSize(width: 640, height: 640))
        #expect(small.width == 640 && small.height == 640)
        #expect(DottieJevProtocol.sendableSize(width: 200, height: 640) == nil)
        #expect(DottieJevProtocol.sendableSize(width: 6000, height: 300) == nil)
        #expect(DottieJevProtocol.sendableSize(width: 0, height: 100) == nil)
    }

    @Test func vagueClickLabelsAreNotSentToJev() {
        #expect(DottieJevProtocol.isUsefulTargetLabel("the first email"))
        #expect(DottieJevProtocol.isUsefulTargetLabel("Send"))
        for vague in ["it", "  This ", "button", "go", ""] {
            #expect(!DottieJevProtocol.isUsefulTargetLabel(vague))
        }
    }
}
