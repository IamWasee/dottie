//
//  DottieSketchArtist.swift
//  leanring-buddy
//
//  Free drawing for explain_on_screen's "sketch" step: "draw a horse", "a
//  plant cell", "a guitar". A quick model call plans the picture as pen
//  strokes (outline first, then details) inside a 0-1000 square, and
//  DottieTeaching draws them one by one like a marker, so Dottie can draw
//  anything, not only lines, shapes and graphs.
//

import CoreGraphics
import Foundation

enum DottieSketchArtist {
    struct Stroke {
        /// 0-1000 across and down the sketch's square.
        let points: [CGPoint]
        let ink: DottieInk?
        let isClosed: Bool
    }

    /// Marks a step's text as already-planned strokes (JSON after it).
    static let plannedStrokesPrefix = "sketch-strokes:"

    private static var cachedStrokesByDescription: [String: String] = [:]
    private static let cacheLock = NSLock()

    private static let systemInstruction = """
    You are a sketch artist who draws with a single marker, like a teacher drawing on a whiteboard. Plan the drawing as pen strokes on a square canvas 0-1000 across (x, left to right) and 0-1000 down (y, top to bottom). Reply only with JSON: {"strokes": [{"points": [[x, y], ...], "closed": false, "color": "gold"}]}.
    - Draw it clearly recognizable, in good proportions, the way a skilled artist would sketch it: main outline first (one long smooth stroke when possible), then the big parts, then a few details (eyes, texture, labels are not strokes).
    - 6 to 40 strokes, each 4 to 60 points, points close enough together that the curve looks smooth (they're joined with smooth curves). Use most of the canvas, centered, with a small margin.
    - color is one of: gold, white, red, blue, green, yellow, pink, purple, orange. Use gold for the main lines unless colors help (a red apple, green leaves).
    - closed true only for strokes that end where they started (a wheel, an eye).
    """

    /// The planned strokes as text for the step (prefix + JSON), or nil
    /// when no model could plan it.
    static func plannedStrokesText(for description: String) async -> String? {
        let cacheKey = description.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        cacheLock.lock()
        let cachedText = cachedStrokesByDescription[cacheKey]
        cacheLock.unlock()
        if let cachedText { return cachedText }

        let prompt = "Draw: \(description)"
        for attempt in 1...2 {
            let model = DottieModelPicker.shared.pick(attempt == 1 ? .normal : .tiny)
            guard let answerText = await DottieChat.ask(prompt, system: systemInstruction, model: model),
                  let jsonStart = answerText.firstIndex(of: "{"),
                  let jsonEnd = answerText.lastIndex(of: "}") else { continue }
            let jsonText = String(answerText[jsonStart...jsonEnd])
            guard !strokes(fromPlannedJSON: jsonText).isEmpty else { continue }
            let plannedText = plannedStrokesPrefix + jsonText
            cacheLock.lock()
            cachedStrokesByDescription[cacheKey] = plannedText
            cacheLock.unlock()
            return plannedText
        }
        return nil
    }

    /// The strokes in a step's text, when it holds planned strokes.
    static func strokes(fromStepText stepText: String?) -> [Stroke] {
        guard let stepText, stepText.hasPrefix(plannedStrokesPrefix) else { return [] }
        return strokes(fromPlannedJSON: String(stepText.dropFirst(plannedStrokesPrefix.count)))
    }

    private static func strokes(fromPlannedJSON jsonText: String) -> [Stroke] {
        guard let jsonData = jsonText.data(using: .utf8),
              let plan = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let rawStrokes = plan["strokes"] as? [[String: Any]] else { return [] }
        return rawStrokes.prefix(60).compactMap { rawStroke -> Stroke? in
            let rawPoints = (rawStroke["points"] as? [Any]) ?? []
            let points: [CGPoint] = rawPoints.prefix(120).compactMap { rawPoint in
                guard let pair = rawPoint as? [Any], pair.count >= 2,
                      let x = (pair[0] as? NSNumber)?.doubleValue,
                      let y = (pair[1] as? NSNumber)?.doubleValue else { return nil }
                return CGPoint(x: min(max(x, 0), 1000), y: min(max(y, 0), 1000))
            }
            guard points.count >= 2 else { return nil }
            let ink = (rawStroke["color"] as? String).flatMap { DottieInk(rawValue: $0.lowercased()) }
            let isClosed = (rawStroke["closed"] as? Bool) ?? false
            return Stroke(points: points, ink: ink, isClosed: isClosed)
        }
    }
}
