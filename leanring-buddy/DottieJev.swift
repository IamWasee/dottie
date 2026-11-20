//
//  DottieJev.swift
//  leanring-buddy
//
//  Jev (TypeSafe's System One model) through the Worker's /jev route: it
//  draws a box around a thing on a screenshot ("the first email") and says
//  how likely a statement is ("the inbox is empty"). It plans nothing and
//  writes no text, so Dottie uses it to find exactly where to click (pointing
//  and screen-job clicks, after GLM says what) and to check that a screen job
//  is really done. Any miss, slow answer or low confidence returns nil and
//  the caller carries on its old way.
//

import AppKit
import Foundation

/// A Jev box: fractions 0-1 of the picture's width and height, top-left origin.
struct DottieJevBox: Equatable {
    let top: Double
    let bottom: Double
    let left: Double
    let right: Double
    let confidence: Double

    /// The same box as [ymin, xmin, ymax, xmax] in 0-1000, the way the
    /// models' box_2d reads.
    var normalizedBox: (ymin: Double, xmin: Double, ymax: Double, xmax: Double) {
        (top * 1000, left * 1000, bottom * 1000, right * 1000)
    }
}

/// Building Jev's requests and reading its answers. Pure, so it's unit tested.
enum DottieJevProtocol {
    static let boxQuestionName = "target"
    static let statementQuestionName = "statement"
    static let screenshotAssetName = "screen"
    /// Jev takes pictures whose sides are 280-1568 pixels.
    static let maximumImageSide = 1568
    static let minimumImageSide = 280
    /// Below this Jev isn't sure enough to beat the model's own box.
    static let minimumBoxConfidence = 0.5

    static func boxRequestBody(target: String, userContext: String?, imageJPEGBase64: String) -> [String: Any] {
        var state = "A screenshot of a Mac screen."
        if let userContext, !userContext.isEmpty {
            state += " The user asked: \(userContext)"
        }
        return [
            "state": state,
            "assets": [screenshotAssetName: ["type": "image", "format": "jpeg", "data_base64": imageJPEGBase64]],
            "questions": [boxQuestionName: [
                "type": "box",
                "instructions": "Box the on-screen element: \(target). Tight around the element itself; it may be an icon with no text."
            ]]
        ]
    }

    static func statementRequestBody(statement: String, imageJPEGBase64: String) -> [String: Any] {
        [
            "state": "A screenshot of a Mac screen, taken just now.",
            "assets": [screenshotAssetName: ["type": "image", "format": "jpeg", "data_base64": imageJPEGBase64]],
            "questions": [statementQuestionName: [
                "type": "noul",
                "instructions": "Does the screenshot show this is true: \(statement)"
            ]]
        ]
    }

    /// The box Jev answered, or nil when it's missing, out of range, empty
    /// or not confident enough. Takes the box nested under "box" or flat.
    static func box(fromAnswer answerData: Data) -> DottieJevBox? {
        guard let answer = question(boxQuestionName, in: answerData) else { return nil }
        let boxFields = (answer["box"] as? [String: Any]) ?? answer
        guard let top = number(boxFields["top"]), let bottom = number(boxFields["bottom"]),
              let left = number(boxFields["left"]), let right = number(boxFields["right"]) else { return nil }
        let confidence = number(answer["confidence"]) ?? number(boxFields["confidence"]) ?? 0
        guard [top, bottom, left, right].allSatisfy({ (0...1).contains($0) }),
              bottom > top, right > left,
              confidence >= minimumBoxConfidence else { return nil }
        return DottieJevBox(top: top, bottom: bottom, left: left, right: right, confidence: confidence)
    }

    /// How likely Jev thinks the statement is (0-1), or nil.
    static func probability(fromAnswer answerData: Data) -> Double? {
        guard let answer = question(statementQuestionName, in: answerData) else { return nil }
        let value = number(answer["noul"]) ?? number(answer["probability"]) ?? number(answer["value"])
        guard let value, (0...1).contains(value) else { return nil }
        return value
    }

    /// Jev's "is it done?" chance below this is a clear no.
    static let clearlyNotDoneProbability = 0.2

    static func clearlyNotDone(probability: Double) -> Bool {
        probability < clearlyNotDoneProbability
    }

    /// Labels worth asking Jev about: a few letters that name something,
    /// not "it", "here" or "button".
    static func isUsefulTargetLabel(_ label: String) -> Bool {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let vagueLabels: Set<String> = ["it", "this", "that", "here", "there", "button", "link", "icon", "field", "the button", "the link"]
        return trimmedLabel.count >= 3 && !vagueLabels.contains(trimmedLabel)
    }

    /// The pixel size to send a picture at: the longest side at most 1568,
    /// or nil when the short side would end up under 280 (Jev refuses it).
    static func sendableSize(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, Double(maximumImageSide) / Double(max(width, height)))
        let scaledWidth = Int((Double(width) * scale).rounded(.down))
        let scaledHeight = Int((Double(height) * scale).rounded(.down))
        guard min(scaledWidth, scaledHeight) >= minimumImageSide else { return nil }
        return (scaledWidth, scaledHeight)
    }

    private static func question(_ questionName: String, in answerData: Data) -> [String: Any]? {
        guard let answerObject = try? JSONSerialization.jsonObject(with: answerData) as? [String: Any],
              let answers = answerObject["answers"] as? [String: Any] else { return nil }
        return answers[questionName] as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

/// Asking Jev through the Worker.
@MainActor
enum DottieJev {
    /// After Jev fails (not set up, down, too slow), it's left alone this long.
    private static let pauseAfterFailureSeconds: TimeInterval = 120
    private static var pausedUntil = Date.distantPast

    /// Where `target` is on `image`, as a Jev box, or nil.
    static func findBox(target: String, userContext: String? = nil, in image: CGImage, timeoutSeconds: TimeInterval = 4) async -> DottieJevBox? {
        guard let imageBase64 = sendableJPEGBase64(image) else { return nil }
        let requestBody = DottieJevProtocol.boxRequestBody(target: target, userContext: userContext, imageJPEGBase64: imageBase64)
        guard let answerData = await ask(requestBody, timeoutSeconds: timeoutSeconds) else { return nil }
        let box = DottieJevProtocol.box(fromAnswer: answerData)
        if box == nil {
            DottieLog.notice("🎯 Jev wasn't sure where it is")
        }
        return box
    }

    /// How likely `statement` is true on `image` (0-1), or nil.
    static func probability(of statement: String, in image: CGImage, timeoutSeconds: TimeInterval = 4) async -> Double? {
        guard let imageBase64 = sendableJPEGBase64(image) else { return nil }
        let requestBody = DottieJevProtocol.statementRequestBody(statement: statement, imageJPEGBase64: imageBase64)
        guard let answerData = await ask(requestBody, timeoutSeconds: timeoutSeconds) else { return nil }
        return DottieJevProtocol.probability(fromAnswer: answerData)
    }

    private static func ask(_ requestBody: [String: Any], timeoutSeconds: TimeInterval) async -> Data? {
        guard Date() >= pausedUntil,
              let requestBodyData = try? JSONSerialization.data(withJSONObject: requestBody) else { return nil }
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/jev"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        request.httpBody = requestBodyData
        let startedAt = Date()
        do {
            let (answerData, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else {
                DottieLog.warning("⚠️ Jev answered \(statusCode); leaving it alone for a while")
                pausedUntil = Date().addingTimeInterval(pauseAfterFailureSeconds)
                return nil
            }
            DottieLog.notice("🎯 Jev answered in \(String(format: "%.2f", Date().timeIntervalSince(startedAt))) s")
            return answerData
        } catch {
            DottieLog.warning("⚠️ Jev didn't answer: \(error.localizedDescription)")
            pausedUntil = Date().addingTimeInterval(pauseAfterFailureSeconds)
            return nil
        }
    }

    private static func sendableJPEGBase64(_ image: CGImage) -> String? {
        guard let size = DottieJevProtocol.sendableSize(width: image.width, height: image.height) else { return nil }
        var sendableImage = image
        if size.width != image.width || size.height != image.height {
            guard let context = CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            guard let resizedImage = context.makeImage() else { return nil }
            sendableImage = resizedImage
        }
        return NSBitmapImageRep(cgImage: sendableImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.85])?
            .base64EncodedString()
    }
}
