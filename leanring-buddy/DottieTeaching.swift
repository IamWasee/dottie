//
//  DottieTeaching.swift
//  leanring-buddy
//
//  Teaching with a marker (explain_on_screen): Dottie draws an explanation
//  step by step, like a tutor at a whiteboard. Lines, arrows, curves,
//  circles, angles and right-angle marks, measurements, braces, axes, real
//  plots of a function, and handwritten math, either over the screen itself
//  (on a math video, a diagram, a chart) or on a dark board she opens beside
//  it. Her cursor holds the pen: it traces each stroke as it appears and
//  says a short caption ("right angle", "slope = 3"), and each step's line
//  is spoken as it's drawn.
//
//  Live's own coordinates come from a small frame and are often off, which
//  is how "highlight A and B" ended up as a box around the wrong equation.
//  So things already on screen are named as anchors with a description,
//  and one sharp screenshot goes to Gemini Flash to find all of them at
//  once. Numbers are only used for empty space and the board.
//

import AppKit
import Foundation
import Vision

/// One stroke for the cursor to trace like a pen: fly to its start in
/// `leadInSeconds`, follow it over `drawSeconds`, then say the caption.
struct DottiePenTrace: Equatable {
    let id = UUID()
    let points: [CGPoint]
    let leadInSeconds: Double
    let drawSeconds: Double
    let caption: String?
    let displayFrame: CGRect
}

enum DottieTeaching {
    static let functionName = "explain_on_screen"

    // MARK: - The plan

    enum Surface: String, CaseIterable {
        case screen, board_right, board_left, board_bottom, board_center

        /// The board, a square so circles stay round, on the screen with
        /// the cursor.
        func boardRect(on visibleFrame: CGRect) -> CGRect? {
            let margin: CGFloat = 24
            switch self {
            case .screen:
                return nil
            case .board_right, .board_left:
                let side = min(visibleFrame.width * 0.42, visibleFrame.height * 0.82)
                let x = self == .board_right ? visibleFrame.maxX - side - margin : visibleFrame.minX + margin
                return CGRect(x: x, y: visibleFrame.midY - side / 2, width: side, height: side)
            case .board_bottom:
                let side = min(visibleFrame.height * 0.45, visibleFrame.width * 0.6)
                return CGRect(x: visibleFrame.midX - side / 2, y: visibleFrame.minY + margin, width: side, height: side)
            case .board_center:
                let side = min(visibleFrame.height * 0.82, visibleFrame.width * 0.8)
                return CGRect(x: visibleFrame.midX - side / 2, y: visibleFrame.midY - side / 2, width: side, height: side)
            }
        }
    }

    enum Kind: String, CaseIterable {
        case line, arrow, double_arrow, curve, polygon, circle, box, highlight, underline
        case angle, right_angle, point, text, ticks, measure, brace, axes, plot, cross, check, grid, chart
        /// A free drawing of anything ("a horse"), planned as pen strokes
        /// by DottieSketchArtist.
        case sketch
    }

    struct Anchor {
        let name: String
        let description: String
    }

    struct Step {
        let kind: Kind
        let points: [String]
        let text: String?
        let ink: DottieInk?
        let size: String?
        let caption: String?
        let say: String?
        let range: [Double]
        /// chart only: line, bar or dots.
        let style: String?

        /// The same step with other text, for a chart whose numbers were
        /// read from the circled area on the Mac.
        func replacingText(_ newText: String) -> Step {
            Step(kind: kind, points: points, text: newText, ink: ink, size: size, caption: caption, say: say, range: range, style: style)
        }
    }

    struct Plan {
        let surface: Surface
        let anchors: [Anchor]
        let steps: [Step]
        let keepsDrawing: Bool
        /// Draw onto the drawing that's already up (same board) instead of
        /// starting over, for "now add…" or "continue it" later on.
        let addsToLastDrawing: Bool
        /// Whether the model named a surface, so adding to a board keeps
        /// that board unless it asked for another one.
        let surfaceWasGiven: Bool

        init?(arguments: [String: Any]) {
            func trimmed(_ value: Any?) -> String? {
                let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return text?.isEmpty == false ? text : nil
            }
            let givenSurface = trimmed(arguments["surface"]).flatMap { Surface(rawValue: $0.lowercased()) }
            surface = givenSurface ?? .screen
            surfaceWasGiven = givenSurface != nil
            addsToLastDrawing = (arguments["add_to_last"] as? Bool) ?? ((arguments["add_to_last"] as? NSNumber)?.boolValue ?? false)
            anchors = ((arguments["anchors"] as? [Any]) ?? []).compactMap { item in
                guard let fields = item as? [String: Any], let name = trimmed(fields["name"]) else { return nil }
                return Anchor(name: name, description: trimmed(fields["describe"]) ?? name)
            }
            steps = ((arguments["steps"] as? [Any]) ?? []).prefix(40).compactMap { item in
                guard let fields = item as? [String: Any],
                      let kind = trimmed(fields["kind"]).flatMap({ Kind(rawValue: $0.lowercased()) }) else { return nil }
                let points: [String]
                if let pointList = fields["points"] as? [Any] {
                    points = pointList.compactMap { point in
                        if let text = point as? String { return text.trimmingCharacters(in: .whitespaces) }
                        if let number = point as? NSNumber { return number.stringValue }
                        return nil
                    }
                } else if let pointText = trimmed(fields["points"]) {
                    points = pointText.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                } else {
                    points = []
                }
                return Step(
                    kind: kind,
                    points: points,
                    text: trimmed(fields["text"]),
                    ink: trimmed(fields["color"]).flatMap { DottieInk(rawValue: $0.lowercased()) },
                    size: trimmed(fields["size"])?.lowercased(),
                    caption: trimmed(fields["caption"]),
                    say: trimmed(fields["say"]),
                    range: ((fields["range"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.doubleValue },
                    style: trimmed(fields["style"])?.lowercased()
                )
            }
            guard !steps.isEmpty else { return nil }
            // Kept up by default, so the user can ask to add to it later.
            keepsDrawing = (arguments["keep"] as? Bool) ?? true
        }

        var anchorNames: Set<String> { Set(anchors.map { $0.name.lowercased() }) }
    }

    // MARK: - Tool declaration

    static var functionDeclaration: [String: Any] {
        let stepProperties: [String: Any] = [
            "kind": ["type": "STRING", "enum": Kind.allCases.map(\.rawValue), "description": "What to draw."],
            "points": [
                "type": "ARRAY",
                "items": ["type": "STRING"],
                "description": "Each is an anchor's name (add .left .right .top .bottom .topleft .topright .bottomleft .bottomright for its edges) or \"x,y\" from 0 to 1000 across the surface. line, curve, polygon: 2 or more points. arrow, double_arrow: from and to (a middle point bends it). circle: one anchor to ring it, or center and a point on the circle. box, highlight, underline: one anchor, or two corners. angle, right_angle: the vertex, then a point on each arm. point, text, cross, check: one point (text starts there). ticks, measure, brace: the two ends of the segment. axes: origin, end of x axis, end of y axis. plot, chart: the graph area's top-left and bottom-right. sketch: the drawing area's top-left and bottom-right (keep it about square), or one center point. grid: two opposite corners of the grid. The name circled is always there: the area the user circled with their cursor (circled.right, circled.bottom… for its edges)."
            ],
            "text": ["type": "STRING", "description": "What to write: the words or math for text, a point's name, an angle like 40° or θ, a length like 5 cm for measure, a brace's label, the number of ticks, for grid the cells across or across x down like 8x5 (default 10), for plot the function of x like x^2 - 3, or for chart the data as label: value pairs split by ; like \"Mon: 12; Tue: 9; Wed: 15\" (or x, y pairs like \"1, 3; 2, 5\"), or the word circled to graph the table or numbers the user circled (read exactly on the Mac), or for sketch what to draw, with the pose and look (\"a horse galloping, side view\", \"a plant cell with its parts\", \"a red sports car\"); it's drawn stroke by stroke like an artist, so use sketch for any picture of a thing (animals, people, objects, places, cells, machines), and text steps beside it for labels. Always math symbols, never math in words: \"p = ¹⁄₁₆x⁴\" not \"p equals one-sixteenth x to the power of four\"; x², ×, ÷, √, π, θ, ⊥, ≠, ≤, ½, →, H₂O. Color part of it to highlight it: {red:key part}, {highlight:…}, **bold**. Keep each step simple: one change at a time, with a few plain words beside it saying why. Numbers: digits in math, measurements, money, times, dates, scores and anything 10 or more (3x⁶, 5 cm, $12, 9:30, 42); words for small everyday counts in a sentence (\"two ways to do this\", \"the first step\"); if the user asks for one style, use that from then on."],
            "color": ["type": "STRING", "enum": DottieInk.allCases.map(\.rawValue), "description": "Pen color. gold unless colors help tell things apart."],
            "size": ["type": "STRING", "enum": ["small", "medium", "large"], "description": "Text size; medium unless it's a heading or a small note."],
            "caption": ["type": "STRING", "description": "2-4 words your cursor says as it draws this, like \"right angle\", \"radius = 6\" or \"slope is 3\"."],
            "say": ["type": "STRING", "description": "The sentence you say out loud for this step. It's spoken while this step is drawn."],
            "range": ["type": "ARRAY", "items": ["type": "NUMBER"], "description": "plot: xmin, xmax, ymin, ymax (default -10, 10, -10, 10). chart: ymin, ymax if you want a set value scale (default fits the data)."],
            "style": ["type": "STRING", "enum": ["line", "bar", "dots"], "description": "chart only: line (default, for trends over time), bar (for comparing amounts) or dots (a scatter)."]
        ]
        return [
            "name": functionName,
            "description": "Teach by drawing, like a tutor with a marker. Draw lines, arrows, curves, circles, angles, right-angle marks, lengths, braces, axes, real plots of functions and handwritten math, one step at a time, either over what's on screen (the video, diagram or page itself) or on a dark board that opens beside it. Use it on your own, without being asked, whenever you explain something visual or mathematical: geometry, graphs, equations, a worked problem, a diagram, a chart, a chess move. Show it, don't only say it. Your cursor holds the pen and says each step's caption. Give every step a say line: they're spoken one by one in sync with the drawing, so right after calling, say only two or three words like \"okay, watch\". When the user circled something with their cursor, the anchor circled is that area: write a worked answer or example beside it (text steps at circled.right, or on a board), mark it, or chart its numbers. To mark other things already on screen, list them in anchors with a precise description and use their names in points: Dottie finds their exact spot with a sharp screenshot, so never guess numbers for them. Numbers are for empty space and the board, and only say you marked something if you anchored it. Worked math, step-by-step solutions and notes go on the notes board with write_notes (it scrolls, keeps long lines whole and takes headings, lists and pictures); use a board here for diagrams and short labels, with each text step's math in symbols, never words. Use sketch to draw any picture of a thing (\"draw a horse\", a heart, a volcano, a cell), never try to build a picture out of lines and curves yourself. A how-to with stages (folding an envelope, a craft, a recipe) is several small sketch steps side by side on a board, one per stage ('1. a square sheet, corners marked', '2. side corners folded to the middle'…), each with a short numbered text label under it and an arrow to the next; never one sketch of the whole tutorial. Use plot for a function's real graph, chart to graph data or a table (it draws the axes, scale, labels and the line or bars from the numbers, so never work out positions for data yourself; text circled graphs a table the user circled), grid for graph paper or a chart's grid (then lines, arrows or a polygon on it for a trend, like a falling line for a downward trend), measure for lengths, angle with its size, ticks for equal sides. The drawing stays up: when the user asks to add to it, change it or carry on (\"now show a downward trend on it\", \"label that\"), call this again with add_to_last true and only the new steps, using the same positions as before. If the user says stop or clear, call clear_drawings.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "surface": [
                        "type": "STRING",
                        "enum": Surface.allCases.map(\.rawValue),
                        "description": "screen draws over what's on screen, to mark the video or diagram itself. board_right, board_left, board_bottom or board_center opens a dark square board there for your own clean diagram and worked steps (0-1000 across and down the board); pick the side where it covers the least of what matters. Steps that use anchors still point at the screen."
                    ],
                    "anchors": [
                        "type": "ARRAY",
                        "items": [
                            "type": "OBJECT",
                            "properties": [
                                "name": ["type": "STRING", "description": "Short name to use in points, like A, B, eq1, circle, tangent_top."],
                                "describe": ["type": "STRING", "description": "What it looks like and where, so it can be found: \"the purple dot labeled A inside the circle on the left\", \"the boxed equation y = -1/3 x + 29/3\", \"the top end of the tangent line\"."]
                            ],
                            "required": ["name", "describe"]
                        ],
                        "description": "Things already on screen that the drawing refers to."
                    ],
                    "steps": [
                        "type": "ARRAY",
                        "items": ["type": "OBJECT", "properties": stepProperties, "required": ["kind", "points"]],
                        "description": "The drawing, in the order to draw and explain it."
                    ],
                    "keep": ["type": "BOOLEAN", "description": "Keep the drawing up after you finish until it's cleared (about 10 minutes). Default true; false fades it after a minute."],
                    "add_to_last": ["type": "BOOLEAN", "description": "true adds these steps to the drawing already up, on the same board, instead of starting a new one. Use it whenever the user asks to add to, change or continue what you drew."]
                ],
                "required": ["steps"]
            ]
        ]
    }

    // MARK: - Finding anchors

    /// One sharp screenshot of the display, and Gemini Flash finds every
    /// anchor on it at once. Returns each found anchor's frame in global
    /// AppKit coordinates, keyed by lowercased name.
    @MainActor
    static func locateAnchors(_ anchors: [Anchor], displayFrame: CGRect, userQuestion: String) async -> [String: CGRect] {
        guard !anchors.isEmpty,
              let image = await DottieDisplayCapture.captureImage(displayFrame: displayFrame, maximumDimension: 1920),
              let jpegData = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return [:]
        }
        let itemList = anchors.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let prompt = """
        This is the user's screen. The user asked: "\(userQuestion)".
        Find each of these things on it:
        \(itemList)
        Reply with only JSON: {"items": [{"name": "...", "box_2d": [ymin, xmin, ymax, xmax]}]}, coordinates normalized 0-1000 across the image, one entry per thing, tight around the thing itself. For a point or dot, a small box around the dot itself, not its label. For the end of a line, a small box at that end. For a circle or shape, the box around the whole shape. Leave out anything you can't see.
        """
        // The normal model thinks a little first; the quickest one joins in
        // when it's slow, and the first answer wins. Waiting for one, then
        // the other, left the drawing stuck on "finding it on your screen"
        // for most of a minute when the free models were busy, and then
        // drew without its anchors. Both skip models that are busy right now.
        let normalModel = DottieModelPicker.shared.pick(.normal)
        let quickModel = DottieModelPicker.shared.pick(.tiny)
        let quickModelDelayNanoseconds = UInt64(quickModelDelaySeconds * 1_000_000_000)
        let foundBoxes: (model: String, boxes: [(String, [Double])])? = await withTaskGroup(
            of: (model: String, boxes: [(String, [Double])])?.self
        ) { boxRequests in
            boxRequests.addTask {
                await requestBoxes(jpegData: jpegData, prompt: prompt, model: normalModel, thinksFirst: true)
                    .map { (model: normalModel, boxes: $0) }
            }
            boxRequests.addTask {
                try? await Task.sleep(nanoseconds: quickModelDelayNanoseconds)
                guard !Task.isCancelled else { return nil }
                return await requestBoxes(jpegData: jpegData, prompt: prompt, model: quickModel, thinksFirst: false)
                    .map { (model: quickModel, boxes: $0) }
            }
            for await answer in boxRequests {
                if let answer, !answer.boxes.isEmpty {
                    boxRequests.cancelAll()
                    return answer
                }
            }
            return nil
        }
        guard let foundBoxes else {
            DottieLog.notice("✏️ Couldn't find the anchors")
            return [:]
        }
        var frames: [String: CGRect] = [:]
        for (name, box) in foundBoxes.boxes {
            frames[name.lowercased()] = CGRect(
                x: displayFrame.minX + box[1] / 1000 * displayFrame.width,
                y: displayFrame.maxY - box[2] / 1000 * displayFrame.height,
                width: (box[3] - box[1]) / 1000 * displayFrame.width,
                height: (box[2] - box[0]) / 1000 * displayFrame.height
            )
        }
        DottieLog.notice("✏️ Found \(frames.count) of \(anchors.count) anchors with \(foundBoxes.model)")
        return frames
    }

    /// The normal model usually answers in a few seconds.
    private static let quickModelDelaySeconds: TimeInterval = 4

    @MainActor
    private static func requestBoxes(jpegData: Data, prompt: String, model: String, thinksFirst: Bool) async -> [(String, [Double])]? {
        var request = URLRequest(url: ClickyWorkerConfiguration.url(forRoute: "/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 14
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The Worker moves on to its next model when one is slow to start.
        request.setValue("6", forHTTPHeaderField: "x-dottie-attempt-seconds")
        ClickyWorkerConfiguration.applyAuthenticationHeaders(to: &request)
        var generationConfig: [String: Any] = ["maxOutputTokens": 4096, "responseMimeType": "application/json"]
        if thinksFirst {
            generationConfig["thinkingConfig"] = ["thinkingLevel": "low"]
        }
        let body: [String: Any] = [
            "model": model,
            "contents": [[
                "role": "user",
                "parts": [
                    ["inlineData": ["mimeType": "image/jpeg", "data": jpegData.base64EncodedString()]],
                    ["text": prompt]
                ]
            ]],
            "generationConfig": generationConfig
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData
        guard let (responseData, response) = try? await DottieModelPicker.shared.data(for: request, model: model),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let answerText = GeminiServerSentEvents.text(from: responseData)
        guard let start = answerText.firstIndex(of: "{"), let end = answerText.lastIndex(of: "}"),
              let jsonData = String(answerText[start...end]).data(using: .utf8),
              let answer = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let items = answer["items"] as? [Any] else {
            return boxesFromMalformedAnswer(answerText)
        }
        return items.compactMap { item in
            guard let fields = item as? [String: Any], let name = fields["name"] as? String,
                  let box = (fields["box_2d"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }),
                  box.count == 4, box[2] >= box[0], box[3] >= box[1],
                  box.allSatisfy({ (0...1000).contains($0) }) else { return nil }
            return (name, box)
        }
    }

    /// The quickest model sometimes writes a box without its brackets
    /// ({"name": "A", "box_2d": 19, 21, 25, 33}), which isn't JSON; read
    /// each name and the four numbers after it anyway.
    private static func boxesFromMalformedAnswer(_ answerText: String) -> [(String, [Double])]? {
        let number = #"\s*(-?[\d.]+)\s*"#
        let itemPattern = #""name"\s*:\s*"([^"]+)"[^{}]*?"box_2d"\s*:\s*\[?"# + [number, number, number, number].joined(separator: ",")
        guard let itemExpression = try? NSRegularExpression(pattern: itemPattern) else { return nil }
        let wholeAnswer = NSRange(answerText.startIndex..., in: answerText)
        let boxes = itemExpression.matches(in: answerText, range: wholeAnswer).compactMap { match -> (String, [Double])? in
            let capturedTexts = (1...5).compactMap { captureIndex in
                Range(match.range(at: captureIndex), in: answerText).map { String(answerText[$0]) }
            }
            guard capturedTexts.count == 5 else { return nil }
            let box = capturedTexts.dropFirst().compactMap(Double.init)
            guard box.count == 4, box[2] >= box[0], box[3] >= box[1],
                  box.allSatisfy({ (0...1000).contains($0) }) else { return nil }
            return (capturedTexts[0], box)
        }
        return boxes.isEmpty ? nil : boxes
    }

    // MARK: - Drawing a step

    /// Where things go for one explanation.
    struct Space {
        /// The board, if one is open; numbers then mean board positions.
        let boardRect: CGRect?
        /// Anchor frames by lowercased name.
        let anchorFrames: [String: CGRect]
        /// A 0-1000 point on Live's screen frame, in global coordinates.
        let screenPoint: (Double, Double) -> CGPoint?

        func numericPoint(_ x: Double, _ y: Double) -> CGPoint? {
            if let boardRect {
                let clampedX = min(max(x, 0), 1000), clampedY = min(max(y, 0), 1000)
                return CGPoint(x: boardRect.minX + clampedX / 1000 * boardRect.width, y: boardRect.maxY - clampedY / 1000 * boardRect.height)
            }
            return screenPoint(x, y)
        }

        /// An anchor's frame, for "anchor" or "anchor.part" references.
        func anchorFrame(_ reference: String) -> (frame: CGRect, part: String?)? {
            let lowered = reference.lowercased()
            if let frame = anchorFrames[lowered] { return (frame: frame, part: nil) }
            guard let dotIndex = lowered.lastIndex(of: ".") else { return nil }
            let name = String(lowered[..<dotIndex])
            let part = String(lowered[lowered.index(after: dotIndex)...])
            guard let frame = anchorFrames[name] else { return nil }
            return (frame: frame, part: part)
        }

        func point(_ reference: String) -> CGPoint? {
            let numbers = reference
                .components(separatedBy: CharacterSet(charactersIn: ", "))
                .filter { !$0.isEmpty }
                .compactMap(Double.init)
            if numbers.count == 2 { return numericPoint(numbers[0], numbers[1]) }
            guard let match = anchorFrame(reference) else { return nil }
            let frame = match.frame
            switch match.part ?? "center" {
            case "left": return CGPoint(x: frame.minX, y: frame.midY)
            case "right": return CGPoint(x: frame.maxX, y: frame.midY)
            case "top": return CGPoint(x: frame.midX, y: frame.maxY)
            case "bottom": return CGPoint(x: frame.midX, y: frame.minY)
            case "topleft": return CGPoint(x: frame.minX, y: frame.maxY)
            case "topright": return CGPoint(x: frame.maxX, y: frame.maxY)
            case "bottomleft": return CGPoint(x: frame.minX, y: frame.minY)
            case "bottomright": return CGPoint(x: frame.maxX, y: frame.minY)
            default: return CGPoint(x: frame.midX, y: frame.midY)
            }
        }

        /// A whole anchor (no edge named), for marks that hug it.
        func wholeAnchor(_ reference: String) -> CGRect? {
            guard let match = anchorFrame(reference), match.part == nil else { return nil }
            return match.frame
        }
    }

    /// What one step puts on screen and the path the pen follows.
    struct DrawnStep {
        var figures: [DottieFigure] = []
        var penPath: [CGPoint] = []
        var duration: Double = 0

        /// Adds a figure after the ones before it, so they draw in turn.
        mutating func add(_ shape: DottieFigure.Shape, ink: DottieInk, lineWidth: CGFloat = 3.5, pen: [CGPoint], duration: Double? = nil) {
            let drawDuration = duration ?? DrawnStep.penDuration(pen)
            figures.append(DottieFigure(shape: shape, ink: ink, lineWidth: lineWidth, delay: self.duration, drawDuration: drawDuration))
            penPath.append(contentsOf: pen)
            self.duration += drawDuration
        }

        mutating func addText(_ text: String, origin: CGPoint, fontSize: CGFloat, ink: DottieInk) {
            let width = DottieFigure.estimatedTextWidth(text, fontSize: fontSize)
            let baselineY = origin.y - fontSize * 0.3
            let writingDuration = min(max(Double(text.count) * 0.07, 0.35), 2.6)
            add(.text(text, origin: origin, fontSize: fontSize), ink: ink,
                pen: [CGPoint(x: origin.x, y: baselineY), CGPoint(x: origin.x + width, y: baselineY)],
                duration: writingDuration)
        }

        /// A label centered on a point.
        mutating func addLabel(_ text: String?, centeredAt center: CGPoint, fontSize: CGFloat = 22, ink: DottieInk) {
            guard let text, !text.isEmpty else { return }
            let width = DottieFigure.estimatedTextWidth(text, fontSize: fontSize)
            addText(text, origin: CGPoint(x: center.x - width / 2, y: center.y), fontSize: fontSize, ink: ink)
        }

        static func penDuration(_ pen: [CGPoint]) -> Double {
            min(max(Double(length(of: pen)) / 650, 0.3), 1.6)
        }
    }

    static func draw(_ step: Step, in space: Space) -> DrawnStep? {
        var drawn = DrawnStep()
        let ink = step.ink ?? .gold
        let label = step.text.map(DottieMathText.pretty)
        let points = step.points.compactMap(space.point)
        let fontSize: CGFloat = step.size == "small" ? 18 : (step.size == "large" ? 38 : 26)

        switch step.kind {
        case .sketch:
            let sketchStrokes = DottieSketchArtist.strokes(fromStepText: step.text)
            guard !sketchStrokes.isEmpty else { return nil }
            let sketchRect: CGRect
            if points.count >= 2, let givenRect = rectangle(from: step, points: points, in: space) {
                sketchRect = givenRect
            } else if let center = points.first {
                let side: CGFloat = space.boardRect.map { $0.width * 0.6 } ?? 360
                sketchRect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            } else {
                return nil
            }
            // Keep the drawing's proportions: fit the square canvas inside
            // the area, centered.
            let side = min(sketchRect.width, sketchRect.height)
            let canvas = CGRect(x: sketchRect.midX - side / 2, y: sketchRect.midY - side / 2, width: side, height: side)
            func canvasPoint(_ sketchPoint: CGPoint) -> CGPoint {
                // y runs down on the canvas, up in AppKit.
                CGPoint(x: canvas.minX + sketchPoint.x / 1000 * canvas.width, y: canvas.maxY - sketchPoint.y / 1000 * canvas.height)
            }
            for sketchStroke in sketchStrokes {
                let strokePoints = sketchStroke.points.map(canvasPoint)
                // A smooth curve through a sharp corner (a fold, a box's
                // edge) swings out into a loop, so strokes are split at
                // their corners and each piece is smoothed on its own.
                let strokePieces = Self.piecesSplitAtSharpCorners(strokePoints, isClosed: sketchStroke.isClosed)
                let keepsClosedCurve = sketchStroke.isClosed && strokePieces.count == 1
                for strokePiece in strokePieces {
                    drawn.add(.stroke(points: strokePiece, closed: keepsClosedCurve, smooth: strokePiece.count >= 3, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                              ink: sketchStroke.ink ?? ink, lineWidth: 3, pen: keepsClosedCurve ? strokePiece + [strokePiece[0]] : strokePiece,
                              duration: min(max(Double(length(of: strokePiece)) / 900, 0.15), 1.4))
                }
            }

        case .line, .curve, .polygon:
            guard points.count >= 2 else { return nil }
            let closed = step.kind == .polygon
            drawn.add(.stroke(points: points, closed: closed, smooth: step.kind == .curve, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                      ink: ink, pen: closed ? points + [points[0]] : points)
            if let label, let lastPoint = points.last {
                drawn.addLabel(label, centeredAt: CGPoint(x: lastPoint.x + 24, y: lastPoint.y + 18), ink: ink)
            }

        case .arrow, .double_arrow:
            guard points.count >= 2 else { return nil }
            var arrowPoints = points
            // An arrow to or from a whole thing stops at its edge.
            if let startFrame = step.points.first.flatMap(space.wholeAnchor) {
                arrowPoints[0] = edgePoint(of: startFrame, toward: arrowPoints[1], gap: 6)
            }
            if let endFrame = step.points.last.flatMap(space.wholeAnchor) {
                arrowPoints[arrowPoints.count - 1] = edgePoint(of: endFrame, toward: arrowPoints[arrowPoints.count - 2], gap: 6)
            }
            drawn.add(.stroke(points: arrowPoints, closed: false, smooth: arrowPoints.count > 2, dashed: false,
                              arrowAtStart: step.kind == .double_arrow, arrowAtEnd: true),
                      ink: ink, pen: arrowPoints)
            if let label {
                let middle = midpoint(arrowPoints[0], arrowPoints[arrowPoints.count - 1])
                drawn.addLabel(label, centeredAt: offset(middle, perpendicularTo: arrowPoints[0], arrowPoints[arrowPoints.count - 1], by: 22), ink: ink)
            }

        case .circle:
            let ring: [CGPoint]
            if let firstReference = step.points.first, let frame = space.wholeAnchor(firstReference), step.points.count == 1 {
                ring = ellipsePoints(in: frame.insetBy(dx: -10, dy: -8))
            } else if points.count >= 2 {
                let radius = distance(points[0], points[1])
                ring = ellipsePoints(in: CGRect(x: points[0].x - radius, y: points[0].y - radius, width: radius * 2, height: radius * 2))
            } else if let center = points.first {
                ring = ellipsePoints(in: CGRect(x: center.x - 28, y: center.y - 28, width: 56, height: 56))
            } else {
                return nil
            }
            drawn.add(.stroke(points: ring, closed: true, smooth: true, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                      ink: ink, pen: ring, duration: 0.7)
            if let label, let topPoint = ring.max(by: { $0.y < $1.y }) {
                drawn.addLabel(label, centeredAt: CGPoint(x: topPoint.x, y: topPoint.y + 20), ink: ink)
            }

        case .box, .highlight:
            guard let rect = rectangle(from: step, points: points, in: space) else { return nil }
            let corners = [CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
                           CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.minY)]
            if step.kind == .highlight {
                drawn.add(.fill(points: corners), ink: step.ink ?? .yellow, pen: [corners[0], corners[1], corners[2], corners[3], corners[0]], duration: 0.5)
            } else {
                drawn.add(.stroke(points: corners, closed: true, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                          ink: ink, pen: corners + [corners[0]])
            }
            if let label {
                drawn.addLabel(label, centeredAt: CGPoint(x: rect.midX, y: rect.minY - 20), ink: ink)
            }

        case .underline:
            let start: CGPoint, end: CGPoint
            if let firstReference = step.points.first, let frame = space.wholeAnchor(firstReference), step.points.count == 1 {
                start = CGPoint(x: frame.minX - 2, y: frame.minY - 5)
                end = CGPoint(x: frame.maxX + 2, y: frame.minY - 6)
            } else if points.count >= 2 {
                start = points[0]
                end = points[1]
            } else {
                return nil
            }
            drawn.add(.stroke(points: [start, end], closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                      ink: ink, pen: [start, end])

        case .angle, .right_angle:
            guard points.count >= 3 else { return nil }
            let vertex = points[0]
            let armA = unit(from: vertex, to: points[1])
            let armB = unit(from: vertex, to: points[2])
            let shorterArm = min(distance(vertex, points[1]), distance(vertex, points[2]))
            if step.kind == .right_angle {
                let side = min(18, max(9, shorterArm * 0.3))
                let square = [
                    CGPoint(x: vertex.x + armA.dx * side, y: vertex.y + armA.dy * side),
                    CGPoint(x: vertex.x + (armA.dx + armB.dx) * side, y: vertex.y + (armA.dy + armB.dy) * side),
                    CGPoint(x: vertex.x + armB.dx * side, y: vertex.y + armB.dy * side)
                ]
                drawn.add(.stroke(points: square, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                          ink: ink, lineWidth: 3, pen: square, duration: 0.4)
                if let label {
                    let outward = normalized(CGVector(dx: armA.dx + armB.dx, dy: armA.dy + armB.dy))
                    drawn.addLabel(label, centeredAt: CGPoint(x: vertex.x + outward.dx * (side + 26), y: vertex.y + outward.dy * (side + 26)),
                                   fontSize: 20, ink: ink)
                }
            } else {
                let radius = min(40, max(16, shorterArm * 0.35))
                let startAngle = atan2(armA.dy, armA.dx)
                var sweep = atan2(armB.dy, armB.dx) - startAngle
                while sweep > .pi { sweep -= 2 * .pi }
                while sweep < -.pi { sweep += 2 * .pi }
                let arc = (0...24).map { index -> CGPoint in
                    let angle = startAngle + sweep * CGFloat(index) / 24
                    return CGPoint(x: vertex.x + cos(angle) * radius, y: vertex.y + sin(angle) * radius)
                }
                drawn.add(.stroke(points: arc, closed: false, smooth: true, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                          ink: ink, lineWidth: 3, pen: arc, duration: 0.45)
                if let label {
                    let middleAngle = startAngle + sweep / 2
                    drawn.addLabel(label, centeredAt: CGPoint(x: vertex.x + cos(middleAngle) * (radius + 22), y: vertex.y + sin(middleAngle) * (radius + 22)),
                                   fontSize: 20, ink: ink)
                }
            }

        case .point:
            guard let point = points.first else { return nil }
            drawn.add(.dot(center: point, radius: 5.5), ink: ink, pen: [point], duration: 0.25)
            if let label {
                drawn.addText(label, origin: CGPoint(x: point.x + 10, y: point.y + 16), fontSize: 22, ink: ink)
            }

        case .text:
            guard let label else { return nil }
            let origin: CGPoint
            if let firstReference = step.points.first, let frame = space.wholeAnchor(firstReference) {
                origin = CGPoint(x: frame.maxX + 14, y: frame.midY)
            } else if let point = points.first {
                origin = point
            } else {
                return nil
            }
            // On a board, a long line is written smaller rather than running
            // off its edge.
            var fittedFontSize = fontSize
            if let boardRect = space.boardRect {
                let roomToTheRight = boardRect.maxX - 18 - origin.x
                while fittedFontSize > 13, DottieFigure.estimatedTextWidth(label, fontSize: fittedFontSize) > roomToTheRight {
                    fittedFontSize -= 1
                }
            }
            drawn.addText(label, origin: origin, fontSize: fittedFontSize, ink: step.ink ?? .white)

        case .ticks:
            guard points.count >= 2 else { return nil }
            let count = max(1, min(4, Int(step.text ?? "") ?? 1))
            let middle = midpoint(points[0], points[1])
            let along = unit(from: points[0], to: points[1])
            let across = CGVector(dx: -along.dy, dy: along.dx)
            for tickIndex in 0..<count {
                let shift = (CGFloat(tickIndex) - CGFloat(count - 1) / 2) * 6
                let center = CGPoint(x: middle.x + along.dx * shift, y: middle.y + along.dy * shift)
                let tick = [CGPoint(x: center.x - across.dx * 8, y: center.y - across.dy * 8),
                            CGPoint(x: center.x + across.dx * 8, y: center.y + across.dy * 8)]
                drawn.add(.stroke(points: tick, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                          ink: ink, lineWidth: 3, pen: tick, duration: 0.15)
            }

        case .measure:
            guard points.count >= 2 else { return nil }
            let along = unit(from: points[0], to: points[1])
            let across = CGVector(dx: -along.dy, dy: along.dx)
            let lift: CGFloat = 18
            let start = CGPoint(x: points[0].x + across.dx * lift, y: points[0].y + across.dy * lift)
            let end = CGPoint(x: points[1].x + across.dx * lift, y: points[1].y + across.dy * lift)
            for (base, lifted) in [(points[0], start), (points[1], end)] {
                let bar = [CGPoint(x: base.x + across.dx * 6, y: base.y + across.dy * 6),
                           CGPoint(x: lifted.x + across.dx * 8, y: lifted.y + across.dy * 8)]
                drawn.add(.stroke(points: bar, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                          ink: ink, lineWidth: 2, pen: bar, duration: 0.15)
            }
            drawn.add(.stroke(points: [start, end], closed: false, smooth: false, dashed: false, arrowAtStart: true, arrowAtEnd: true),
                      ink: ink, lineWidth: 2.5, pen: [start, end])
            let middle = midpoint(start, end)
            drawn.addLabel(label, centeredAt: CGPoint(x: middle.x + across.dx * 20, y: middle.y + across.dy * 20), fontSize: 20, ink: ink)

        case .brace:
            guard points.count >= 2 else { return nil }
            let start = points[0], end = points[1]
            let along = CGVector(dx: end.x - start.x, dy: end.y - start.y)
            let across = normalized(CGVector(dx: -along.dy, dy: along.dx))
            let depth: CGFloat = 14
            func at(_ t: CGFloat, _ lift: CGFloat) -> CGPoint {
                CGPoint(x: start.x + along.dx * t + across.dx * lift, y: start.y + along.dy * t + across.dy * lift)
            }
            let brace = [at(0, 0), at(0.06, depth * 0.55), at(0.2, depth * 0.62), at(0.44, depth * 0.66), at(0.5, depth * 1.25),
                         at(0.56, depth * 0.66), at(0.8, depth * 0.62), at(0.94, depth * 0.55), at(1, 0)]
            drawn.add(.stroke(points: brace, closed: false, smooth: true, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                      ink: ink, lineWidth: 3, pen: brace)
            let tip = at(0.5, depth * 1.25 + 22)
            drawn.addLabel(label, centeredAt: tip, fontSize: 20, ink: ink)

        case .axes:
            guard points.count >= 3 else { return nil }
            let origin = points[0]
            for axisEnd in [points[1], points[2]] {
                drawn.add(.stroke(points: [origin, axisEnd], closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: true),
                          ink: step.ink ?? .white, lineWidth: 2.5, pen: [origin, axisEnd])
            }
            let names = (label ?? "x,y").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            drawn.addLabel(names.first ?? "x", centeredAt: CGPoint(x: points[1].x + 4, y: points[1].y - 22), fontSize: 20, ink: step.ink ?? .white)
            if names.count > 1 {
                drawn.addLabel(names[1], centeredAt: CGPoint(x: points[2].x + 20, y: points[2].y + 4), fontSize: 20, ink: step.ink ?? .white)
            }

        case .grid:
            guard points.count >= 2 else { return nil }
            let gridArea = CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                                  width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
            guard gridArea.width > 20, gridArea.height > 20 else { return nil }
            // "8x5" is 8 cells across and 5 down; one number is the cells
            // across, with square-ish cells down.
            let cellCounts = (step.text ?? "")
                .lowercased()
                .components(separatedBy: CharacterSet(charactersIn: "x× ,"))
                .compactMap { Int($0) }
            let columnCount = min(max(cellCounts.first ?? 10, 1), 40)
            let defaultRowCount = Int((CGFloat(columnCount) * gridArea.height / gridArea.width).rounded())
            let rowCount = min(max(cellCounts.count > 1 ? cellCounts[1] : defaultRowCount, 1), 40)
            let gridInk = step.ink ?? .white
            // Thin and quick: a grid is the paper, not the point.
            let lineCount = columnCount + rowCount + 2
            let secondsPerLine = max(0.04, min(0.12, 2.0 / Double(lineCount)))
            for columnIndex in 0...columnCount {
                let lineX = gridArea.minX + gridArea.width * CGFloat(columnIndex) / CGFloat(columnCount)
                let gridLine = [CGPoint(x: lineX, y: gridArea.maxY), CGPoint(x: lineX, y: gridArea.minY)]
                drawn.add(.stroke(points: gridLine, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                          ink: gridInk, lineWidth: 1, pen: gridLine, duration: secondsPerLine)
            }
            for rowIndex in 0...rowCount {
                let lineY = gridArea.minY + gridArea.height * CGFloat(rowIndex) / CGFloat(rowCount)
                let gridLine = [CGPoint(x: gridArea.minX, y: lineY), CGPoint(x: gridArea.maxX, y: lineY)]
                drawn.add(.stroke(points: gridLine, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                          ink: gridInk, lineWidth: 1, pen: gridLine, duration: secondsPerLine)
            }

        case .plot:
            guard points.count >= 2, let expressionText = step.text,
                  let function = DottieMathExpression(expressionText) else { return nil }
            let area = CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                              width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
            guard area.width > 20, area.height > 20 else { return nil }
            let range = step.range.count == 4 && step.range[1] > step.range[0] && step.range[3] > step.range[2]
                ? step.range : [-10, 10, -10, 10]
            let (xMin, xMax, yMin, yMax) = (range[0], range[1], range[2], range[3])
            func screenPoint(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: area.minX + CGFloat((x - xMin) / (xMax - xMin)) * area.width,
                        y: area.minY + CGFloat((y - yMin) / (yMax - yMin)) * area.height)
            }
            // Faint axes where zero is in view.
            if xMin < 0, xMax > 0 {
                let axis = [screenPoint(0, yMin), screenPoint(0, yMax)]
                drawn.add(.stroke(points: axis, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: true),
                          ink: .white, lineWidth: 1.5, pen: axis, duration: 0.25)
            }
            if yMin < 0, yMax > 0 {
                let axis = [screenPoint(xMin, 0), screenPoint(xMax, 0)]
                drawn.add(.stroke(points: axis, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: true),
                          ink: .white, lineWidth: 1.5, pen: axis, duration: 0.25)
            }
            // The curve, broken wherever it leaves the view or jumps.
            var segments: [[CGPoint]] = [[]]
            let sampleCount = 240
            let ySpan = yMax - yMin
            for sampleIndex in 0...sampleCount {
                let x = xMin + (xMax - xMin) * Double(sampleIndex) / Double(sampleCount)
                let y = function.evaluate(x: x)
                if y.isFinite, y >= yMin - ySpan * 0.02, y <= yMax + ySpan * 0.02 {
                    segments[segments.count - 1].append(screenPoint(x, min(max(y, yMin), yMax)))
                } else if !(segments.last?.isEmpty ?? true) {
                    segments.append([])
                }
            }
            let curves = segments.filter { $0.count >= 2 }
            guard !curves.isEmpty else { return nil }
            let totalLength = curves.reduce(CGFloat(0)) { $0 + length(of: $1) }
            for curve in curves {
                let share = Double(length(of: curve) / max(totalLength, 1))
                drawn.add(.stroke(points: curve, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                          ink: ink, lineWidth: 3, pen: curve, duration: max(0.25, 1.6 * share))
            }
            if let lastCurve = curves.last, let curveEnd = lastCurve.last {
                let name = "y = " + DottieMathText.prettyPlainText(expressionText)
                let width = DottieFigure.estimatedTextWidth(name, fontSize: 20)
                let x = min(curveEnd.x + 8, area.maxX - width)
                drawn.addText(name, origin: CGPoint(x: x, y: min(curveEnd.y + 18, area.maxY - 10)), fontSize: 20, ink: ink)
            }

        case .cross:
            guard let point = points.first else { return nil }
            let first = [CGPoint(x: point.x - 12, y: point.y + 12), CGPoint(x: point.x + 12, y: point.y - 12)]
            let second = [CGPoint(x: point.x + 12, y: point.y + 12), CGPoint(x: point.x - 12, y: point.y - 12)]
            drawn.add(.stroke(points: first, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                      ink: step.ink ?? .red, lineWidth: 4, pen: first, duration: 0.2)
            drawn.add(.stroke(points: second, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                      ink: step.ink ?? .red, lineWidth: 4, pen: second, duration: 0.2)

        case .chart:
            guard points.count >= 2, let dataText = step.text else { return nil }
            let chartPoints = DottieChartData.parse(dataText)
            guard !chartPoints.isEmpty else { return nil }
            // Room on the left for the scale and below for the labels.
            let outerArea = CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                                   width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
            let scaleLabelFontSize: CGFloat = 15
            let plotArea = CGRect(x: outerArea.minX + 46, y: outerArea.minY + 30,
                                  width: outerArea.width - 56, height: outerArea.height - 40)
            guard plotArea.width > 40, plotArea.height > 40 else { return nil }
            let chartStyle = step.style ?? "line"
            let values = chartPoints.map(\.value)
            let valueScale = DottieChartData.valueScale(
                values: values,
                startsAtZero: chartStyle == "bar",
                givenRange: step.range.count >= 2 && step.range[1] > step.range[0] ? (step.range[0], step.range[1]) : nil
            )
            func screenY(_ value: Double) -> CGFloat {
                plotArea.minY + CGFloat((value - valueScale.minimum) / (valueScale.maximum - valueScale.minimum)) * plotArea.height
            }
            // x is spread evenly for labels, or by the numbers for x, y pairs.
            let numericXValues = chartPoints.compactMap(\.x)
            let usesNumericX = numericXValues.count == chartPoints.count && chartPoints.count > 1
                && (numericXValues.max() ?? 0) > (numericXValues.min() ?? 0)
            func screenX(_ index: Int) -> CGFloat {
                if usesNumericX, let xMinimum = numericXValues.min(), let xMaximum = numericXValues.max(), let x = chartPoints[index].x {
                    return plotArea.minX + 12 + CGFloat((x - xMinimum) / (xMaximum - xMinimum)) * (plotArea.width - 24)
                }
                return plotArea.minX + plotArea.width * (CGFloat(index) + 0.5) / CGFloat(chartPoints.count)
            }
            let axisInk = DottieInk.white
            // Faint scale lines with their numbers.
            for tickValue in valueScale.ticks {
                let lineY = screenY(tickValue)
                let scaleLine = [CGPoint(x: plotArea.minX, y: lineY), CGPoint(x: plotArea.maxX, y: lineY)]
                drawn.add(.stroke(points: scaleLine, closed: false, smooth: false, dashed: true, arrowAtStart: false, arrowAtEnd: false),
                          ink: axisInk, lineWidth: 0.8, pen: scaleLine, duration: 0.08)
                let tickText = DottieChartData.shortNumber(tickValue)
                let tickWidth = DottieFigure.estimatedTextWidth(tickText, fontSize: scaleLabelFontSize)
                drawn.addText(tickText, origin: CGPoint(x: plotArea.minX - tickWidth - 8, y: lineY + 5), fontSize: scaleLabelFontSize, ink: axisInk)
            }
            let axes = [CGPoint(x: plotArea.minX, y: plotArea.maxY), CGPoint(x: plotArea.minX, y: plotArea.minY), CGPoint(x: plotArea.maxX, y: plotArea.minY)]
            drawn.add(.stroke(points: axes, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                      ink: axisInk, lineWidth: 2.5, pen: axes, duration: 0.4)
            // Labels under the axis, every one that fits.
            let xLabels = chartPoints.indices.map { index in
                chartPoints[index].label ?? chartPoints[index].x.map(DottieChartData.shortNumber) ?? ""
            }
            let widestLabel = xLabels.map { DottieFigure.estimatedTextWidth($0, fontSize: scaleLabelFontSize) }.max() ?? 0
            let slotWidth = plotArea.width / CGFloat(chartPoints.count)
            let labelEvery = max(1, Int(ceil((widestLabel + 8) / max(slotWidth, 1))))
            for index in chartPoints.indices where index % labelEvery == 0 && !xLabels[index].isEmpty {
                drawn.addLabel(xLabels[index], centeredAt: CGPoint(x: screenX(index), y: plotArea.minY - 12), fontSize: scaleLabelFontSize, ink: axisInk)
            }
            // The data itself.
            let dataPoints = chartPoints.indices.map { CGPoint(x: screenX($0), y: screenY(chartPoints[$0].value)) }
            switch chartStyle {
            case "bar":
                let barWidth = max(4, min(60, slotWidth * 0.6))
                let baseY = screenY(max(valueScale.minimum, min(0, valueScale.maximum)))
                for dataPoint in dataPoints {
                    let barCorners = [CGPoint(x: dataPoint.x - barWidth / 2, y: baseY), CGPoint(x: dataPoint.x - barWidth / 2, y: dataPoint.y),
                                      CGPoint(x: dataPoint.x + barWidth / 2, y: dataPoint.y), CGPoint(x: dataPoint.x + barWidth / 2, y: baseY)]
                    drawn.add(.fill(points: barCorners), ink: ink, pen: barCorners, duration: max(0.12, 1.4 / Double(dataPoints.count)))
                }
            case "dots":
                for dataPoint in dataPoints {
                    drawn.add(.dot(center: dataPoint, radius: 5), ink: ink, pen: [dataPoint], duration: max(0.06, 1.0 / Double(dataPoints.count)))
                }
            default:
                if dataPoints.count >= 2 {
                    drawn.add(.stroke(points: dataPoints, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                              ink: ink, lineWidth: 3.5, pen: dataPoints, duration: min(2.4, max(0.6, Double(dataPoints.count) * 0.15)))
                }
                for dataPoint in dataPoints where dataPoints.count <= 40 {
                    drawn.add(.dot(center: dataPoint, radius: 4.5), ink: ink, pen: [dataPoint], duration: 0.04)
                }
            }
            // Each value written on its point when there are few enough.
            if dataPoints.count <= 12 && labelEvery == 1 {
                for (index, dataPoint) in dataPoints.enumerated() {
                    drawn.addLabel(DottieChartData.shortNumber(chartPoints[index].value), centeredAt: CGPoint(x: dataPoint.x, y: dataPoint.y + 18),
                                   fontSize: scaleLabelFontSize, ink: ink)
                }
            }
            if let label = step.caption.map(DottieMathText.prettyPlainText) {
                drawn.addLabel(label, centeredAt: CGPoint(x: plotArea.midX, y: outerArea.maxY + 4), fontSize: 20, ink: axisInk)
            }

        case .check:
            guard let point = points.first else { return nil }
            let tick = [CGPoint(x: point.x - 12, y: point.y + 2), CGPoint(x: point.x - 3, y: point.y - 9), CGPoint(x: point.x + 15, y: point.y + 14)]
            drawn.add(.stroke(points: tick, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                      ink: step.ink ?? .green, lineWidth: 4, pen: tick, duration: 0.3)
        }
        return drawn.figures.isEmpty ? nil : drawn
    }

    // MARK: - Geometry helpers

    private static func rectangle(from step: Step, points: [CGPoint], in space: Space) -> CGRect? {
        if step.points.count == 1, let frame = space.wholeAnchor(step.points[0]) {
            return frame.insetBy(dx: -8, dy: -6)
        }
        guard points.count >= 2 else { return nil }
        return CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                      width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
    }

    static func ellipsePoints(in rect: CGRect) -> [CGPoint] {
        (0..<48).map { index in
            let angle = CGFloat(index) / 48 * 2 * .pi + .pi / 2
            return CGPoint(x: rect.midX + cos(angle) * rect.width / 2, y: rect.midY + sin(angle) * rect.height / 2)
        }
    }

    /// Where the line from the rect's center toward `point` leaves the
    /// rect, plus a small gap.
    static func edgePoint(of rect: CGRect, toward point: CGPoint, gap: CGFloat) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let direction = unit(from: center, to: point)
        guard direction.dx != 0 || direction.dy != 0 else { return center }
        let scaleX = direction.dx == 0 ? CGFloat.greatestFiniteMagnitude : (rect.width / 2) / abs(direction.dx)
        let scaleY = direction.dy == 0 ? CGFloat.greatestFiniteMagnitude : (rect.height / 2) / abs(direction.dy)
        let reach = min(scaleX, scaleY) + gap
        return CGPoint(x: center.x + direction.dx * reach, y: center.y + direction.dy * reach)
    }

    static func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(second.x - first.x, second.y - first.y)
    }

    static func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }

    static func unit(from start: CGPoint, to end: CGPoint) -> CGVector {
        normalized(CGVector(dx: end.x - start.x, dy: end.y - start.y))
    }

    static func normalized(_ vector: CGVector) -> CGVector {
        let length = hypot(vector.dx, vector.dy)
        guard length > 0.0001 else { return CGVector(dx: 0, dy: 0) }
        return CGVector(dx: vector.dx / length, dy: vector.dy / length)
    }

    static func offset(_ point: CGPoint, perpendicularTo start: CGPoint, _ end: CGPoint, by amount: CGFloat) -> CGPoint {
        let along = unit(from: start, to: end)
        return CGPoint(x: point.x - along.dy * amount, y: point.y + along.dx * amount)
    }

    /// A sketch stroke cut at every turn sharper than about 50°, each piece
    /// sharing the corner point with the next. A closed stroke with corners
    /// comes back open, ending where it started.
    static func piecesSplitAtSharpCorners(_ strokePoints: [CGPoint], isClosed: Bool) -> [[CGPoint]] {
        guard strokePoints.count >= 3 else { return [strokePoints] }
        let sharpTurnRadians = CGFloat.pi * 50 / 180
        func turnRadians(atIndex pointIndex: Int, in points: [CGPoint]) -> CGFloat {
            let previous = points[(pointIndex - 1 + points.count) % points.count]
            let current = points[pointIndex]
            let next = points[(pointIndex + 1) % points.count]
            let incomingAngle = atan2(current.y - previous.y, current.x - previous.x)
            let outgoingAngle = atan2(next.y - current.y, next.x - current.x)
            var turn = abs(outgoingAngle - incomingAngle)
            if turn > .pi { turn = 2 * .pi - turn }
            return turn
        }
        var points = strokePoints
        if isClosed {
            guard let cornerIndex = points.indices.first(where: { turnRadians(atIndex: $0, in: strokePoints) > sharpTurnRadians }) else {
                return [strokePoints]
            }
            // Start the loop at a corner, then walk it as an open stroke
            // back to that corner.
            points = Array(strokePoints[cornerIndex...]) + Array(strokePoints[..<cornerIndex]) + [strokePoints[cornerIndex]]
        }
        var pieces: [[CGPoint]] = []
        var currentPiece: [CGPoint] = [points[0]]
        for pointIndex in 1..<points.count {
            currentPiece.append(points[pointIndex])
            let isInteriorPoint = pointIndex < points.count - 1
            if isInteriorPoint && turnRadians(atIndex: pointIndex, in: points) > sharpTurnRadians {
                pieces.append(currentPiece)
                currentPiece = [points[pointIndex]]
            }
        }
        if currentPiece.count >= 2 { pieces.append(currentPiece) }
        return pieces
    }

    static func length(of points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }
}

// MARK: - Math text

/// Turns typed math and science into what you'd write by hand: x^2 → x²,
/// 3*4 → 3×4, sqrt(x) → √(x), \theta → θ, >= → ≥, x_1 → x₁, \frac{a}{b} → a/b,
/// H2O → H₂O, SO4^2- → SO₄²⁻, Na+ → Na⁺, <=> → ⇌, 25 degC → 25 °C.
/// Color and bold markings (DottieInkText) are kept.
enum DottieMathText {
    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "k": "ᵏ", "m": "ᵐ", "t": "ᵗ", "T": "ᵀ", "o": "ᵒ"
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "x": "ₓ", "n": "ₙ", "i": "ᵢ",
        "o": "ₒ", "k": "ₖ", "m": "ₘ", "t": "ₜ", "r": "ᵣ", "s": "ₛ", "p": "ₚ", "j": "ⱼ", "h": "ₕ", "l": "ₗ"
    ]
    /// Longer names first wherever one starts another (\leftarrow before
    /// \left, \neq before \ne, <=> before <=).
    private static let words: [(String, String)] = [
        // Arrows (chemistry's ⇌ among them).
        ("\\rightleftharpoons", "⇌"), ("\\leftrightarrow", "↔"), ("\\Leftrightarrow", "⇔"), ("\\iff", "⇔"),
        ("\\Rightarrow", "⇒"), ("\\implies", "⇒"), ("\\Leftarrow", "⇐"), ("\\rightarrow", "→"), ("\\leftarrow", "←"),
        ("\\uparrow", "↑"), ("\\downarrow", "↓"), ("\\to", "→"), ("\\gets", "←"),
        ("\\left", ""), ("\\right", ""), ("\\text", ""), ("\\mathrm", ""), ("\\displaystyle", ""),
        ("\\mathbb{R}", "ℝ"), ("\\mathbb{N}", "ℕ"), ("\\mathbb{Z}", "ℤ"), ("\\mathbb{Q}", "ℚ"), ("\\mathbb{C}", "ℂ"),
        // Greek, capitals where they differ from Latin letters.
        ("\\varepsilon", "ε"), ("\\epsilon", "ε"), ("\\varphi", "φ"), ("\\vartheta", "ϑ"),
        ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\Gamma", "Γ"), ("\\delta", "δ"), ("\\Delta", "Δ"),
        ("\\zeta", "ζ"), ("\\eta", "η"), ("\\theta", "θ"), ("\\Theta", "Θ"), ("\\iota", "ι"), ("\\kappa", "κ"),
        ("\\lambda", "λ"), ("\\Lambda", "Λ"), ("\\mu", "μ"), ("\\nu", "ν"), ("\\xi", "ξ"), ("\\Xi", "Ξ"),
        ("\\pi", "π"), ("\\Pi", "Π"), ("\\rho", "ρ"), ("\\sigma", "σ"), ("\\Sigma", "Σ"), ("\\tau", "τ"),
        ("\\upsilon", "υ"), ("\\phi", "φ"), ("\\Phi", "Φ"), ("\\chi", "χ"), ("\\psi", "ψ"), ("\\Psi", "Ψ"),
        ("\\omega", "ω"), ("\\Omega", "Ω"), ("\\hbar", "ℏ"), ("\\ell", "ℓ"),
        // Calculus, sums and sets.
        ("\\sum", "∑"), ("\\prod", "∏"), ("\\iiint", "∭"), ("\\iint", "∬"), ("\\oint", "∮"), ("\\int", "∫"),
        ("\\partial", "∂"), ("\\nabla", "∇"), ("\\infty", "∞"), ("\\lim", "lim"),
        ("\\notin", "∉"), ("\\in", "∈"), ("\\subseteq", "⊆"), ("\\subset", "⊂"), ("\\supset", "⊃"),
        ("\\cup", "∪"), ("\\cap", "∩"), ("\\emptyset", "∅"), ("\\varnothing", "∅"), ("\\forall", "∀"), ("\\exists", "∃"),
        ("\\neg", "¬"), ("\\land", "∧"), ("\\lor", "∨"),
        // Comparisons and operators.
        ("\\neq", "≠"), ("\\ne", "≠"), ("\\leq", "≤"), ("\\geq", "≥"), ("\\le", "≤"), ("\\ge", "≥"),
        ("\\ll", "≪"), ("\\gg", "≫"), ("\\approx", "≈"), ("\\equiv", "≡"), ("\\cong", "≅"), ("\\simeq", "≃"),
        ("\\sim", "∼"), ("\\propto", "∝"), ("\\times", "×"), ("\\div", "÷"), ("\\pm", "±"), ("\\mp", "∓"),
        ("\\cdots", "⋯"), ("\\ldots", "…"), ("\\dots", "…"), ("\\cdot", "·"),
        // Geometry.
        ("\\angle", "∠"), ("\\perp", "⊥"), ("\\parallel", "∥"), ("\\triangle", "△"), ("\\square", "□"),
        ("\\degree", "°"), ("^\\circ", "°"), ("\\circ", "°"), ("\\therefore", "∴"), ("\\because", "∵"),
        // Roots.
        ("\\sqrt[3]", "∛"), ("\\sqrt[4]", "∜"), ("\\sqrt", "√"), ("cbrt", "∛"), ("sqrt", "√"),
        // Typed the plain way.
        ("<=>", "⇌"), ("<->", "↔"), ("<-", "←"), ("=>", "⇒"), ("->", "→"),
        ("<=", "≤"), (">=", "≥"), ("!=", "≠"), ("=/=", "≠"), ("~=", "≈"), ("+/-", "±"), ("+-", "±"),
        ("*", "×"), ("$", "")
    ]

    /// Patterns that need the letters around them: pi on its own, degrees
    /// and units after a number, a minus sign, simple fractions.
    private static let patternReplacements: [(NSRegularExpression, String)] = ([
        (#"\bpi\b"#, "π"),
        (#"\binfinity\b"#, "∞"),
        (#"(\d)\s?deg\s?C\b"#, "$1 °C"),
        (#"(\d)\s?deg\s?F\b"#, "$1 °F"),
        (#"(\d)\s?(deg|degrees)\b"#, "$1°"),
        (#"(\d)\s?ohms?\b"#, "$1 Ω"),
        (#"(\d)\s?micro(m|g|s|L)\b"#, "$1 µ$2"),
        // A minus sign, not a hyphen: spaced, or before a number or bracket
        // at the start or after = ( and operators.
        (#" - "#, " − "),
        (#"(^|[=(\[,×÷+/≤≥<>]\s?)-(?=[\d(a-zA-Zπθ√])"#, "$1−"),
        (#"(?<![\d./])1/2(?![\d/])"#, "½"), (#"(?<![\d./])1/3(?![\d/])"#, "⅓"), (#"(?<![\d./])2/3(?![\d/])"#, "⅔"),
        (#"(?<![\d./])1/4(?![\d/])"#, "¼"), (#"(?<![\d./])3/4(?![\d/])"#, "¾"), (#"(?<![\d./])1/8(?![\d/])"#, "⅛")
    ] as [(String, String)]).compactMap { pattern, replacement in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) }
    }

    /// Every element's symbol, so H2O, CO2 and Ca(OH)2 get subscripts but
    /// MP3, A1 or Q3 don't.
    private static let elementSymbols: Set<String> = Set("""
    H He Li Be B C N O F Ne Na Mg Al Si P S Cl Ar K Ca Sc Ti V Cr Mn Fe Co Ni Cu Zn Ga Ge As Se Br Kr Rb Sr Y Zr Nb Mo \
    Tc Ru Rh Pd Ag Cd In Sn Sb Te I Xe Cs Ba La Ce Pr Nd Pm Sm Eu Gd Tb Dy Ho Er Tm Yb Lu Hf Ta W Re Os Ir Pt Au Hg Tl \
    Pb Bi Po At Rn Fr Ra Ac Th Pa U Np Pu Am Cm Bk Cf Es Fm Md No Lr Rf Db Sg Bh Hs Mt Ds Rg Cn Nh Fl Mc Lv Ts Og
    """.split(separator: " ").map(String.init))

    /// Pretty math and science, keeping any color or bold markings.
    static func pretty(_ text: String) -> String {
        DottieInkText.transformingText(in: text, using: prettyPlain)
    }

    /// Pretty, with the markings taken out, for what the cursor says.
    static func prettyPlainText(_ text: String) -> String {
        DottieInkText.plainText(pretty(text))
    }

    private static func prettyPlain(_ text: String) -> String {
        var result = text
        result = replaceFractions(in: result)
        for (word, symbol) in words {
            result = result.replacingOccurrences(of: word, with: symbol)
        }
        for (pattern, replacement) in patternReplacements {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        result = chemicalFormulas(in: result)
        result = replaceScripts(in: result, marker: "^", map: superscripts)
        result = replaceScripts(in: result, marker: "_", map: subscripts)
        return result.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
    }

    /// H2O → H₂O, C6H12O6 → C₆H₁₂O₆, Ca(OH)2 → Ca(OH)₂, Na+ → Na⁺, Cl- → Cl⁻,
    /// Fe3+ → Fe³⁺. Only words made wholly of element symbols, numbers and
    /// brackets change, so ordinary words and labels are left alone.
    private static func chemicalFormulas(in text: String) -> String {
        guard let formulaPattern = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])((?:[A-Z][a-z]?|\(|\)|\[|\]|\d)+)([+−-]?)(?![A-Za-z0-9])"#) else { return text }
        let nsText = text as NSString
        var result = ""
        var lastEnd = 0
        for match in formulaPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let body = nsText.substring(with: match.range(at: 1))
            let charge = nsText.substring(with: match.range(at: 2))
            guard let rewritten = rewrittenFormula(body: body, charge: charge) else { continue }
            result += nsText.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            result += rewritten
            lastEnd = match.range.location + match.range.length
        }
        result += nsText.substring(from: lastEnd)
        return result
    }

    private static func rewrittenFormula(body: String, charge: String) -> String? {
        // Split into element symbols, brackets and digit runs.
        var parts: [String] = []
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if character.isUppercase {
                var symbol = String(character)
                let nextIndex = body.index(after: index)
                if nextIndex < body.endIndex, body[nextIndex].isLowercase {
                    symbol.append(body[nextIndex])
                    index = body.index(after: nextIndex)
                } else {
                    index = nextIndex
                }
                parts.append(symbol)
            } else if character.isNumber {
                var digits = ""
                while index < body.endIndex, body[index].isNumber {
                    digits.append(body[index])
                    index = body.index(after: index)
                }
                parts.append(digits)
            } else {
                parts.append(String(character))
                index = body.index(after: index)
            }
        }
        let elementParts = parts.filter { $0.first?.isUppercase == true }
        guard !elementParts.isEmpty, elementParts.allSatisfy(elementSymbols.contains) else { return nil }
        // A number after the first part counts atoms (a leading one, as in
        // 2H2O, is how many molecules).
        let hasCount = parts.dropFirst().contains { $0.first?.isNumber == true }
        let isIon = !charge.isEmpty
        guard hasCount || isIon else { return nil }
        // A lone symbol with a sign ("C-", "I+") reads as text, not an ion,
        // unless it's a common ion.
        if !hasCount, isIon, elementParts.count == 1, !["Na", "K", "Cl", "H", "Li", "Ag", "F", "Br"].contains(elementParts[0]) { return nil }

        var rewritten = ""
        for (partIndex, part) in parts.enumerated() {
            guard part.first?.isNumber == true else {
                rewritten += part
                continue
            }
            let isLastPart = partIndex == parts.count - 1
            if isLastPart && isIon {
                // Fe3+ → Fe³⁺: the number before a charge is the charge's.
                rewritten += String(part.compactMap { superscripts[$0] })
            } else if partIndex == 0 {
                // A leading number is how many: 2H2O.
                rewritten += part
            } else {
                rewritten += String(part.compactMap { subscripts[$0] })
            }
        }
        if isIon { rewritten += charge == "+" ? "⁺" : "⁻" }
        return rewritten
    }

    /// \frac{a}{b} → a/b (with brackets when a part has more than one term).
    private static func replaceFractions(in text: String) -> String {
        var result = text
        while let fracRange = result.range(of: "\\frac{") {
            guard let numerator = bracedGroup(in: result, from: result.index(before: fracRange.upperBound)),
                  result.index(after: numerator.end) < result.endIndex,
                  result[result.index(after: numerator.end)] == "{",
                  let denominator = bracedGroup(in: result, from: result.index(after: numerator.end)) else { break }
            func wrap(_ part: String) -> String {
                part.contains(where: { "+- ".contains($0) }) ? "(\(part))" : part
            }
            result.replaceSubrange(fracRange.lowerBound...denominator.end, with: "\(wrap(numerator.content))/\(wrap(denominator.content))")
        }
        return result
    }

    /// The text inside the braces that open at `openIndex`.
    private static func bracedGroup(in text: String, from openIndex: String.Index) -> (content: String, end: String.Index)? {
        guard text[openIndex] == "{" else { return nil }
        var depth = 0
        var index = openIndex
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return (String(text[text.index(after: openIndex)..<index]), index) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// x^2, x^{10}, x^(n+1): raised (or lowered) when every character has a
    /// small form, otherwise left as typed.
    private static func replaceScripts(in text: String, marker: Character, map: [Character: Character]) -> String {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == marker, text.index(after: index) < text.endIndex else {
                output.append(character)
                index = text.index(after: index)
                continue
            }
            var contentStart = text.index(after: index)
            var contentEnd = contentStart
            let opener = text[contentStart]
            if opener == "{" || opener == "(" {
                // To the matching bracket, so x^(3 - (-3)) takes the whole
                // power, not just up to the first ")".
                let closer: Character = opener == "{" ? "}" : ")"
                contentStart = text.index(after: contentStart)
                contentEnd = contentStart
                var depth = 1
                while contentEnd < text.endIndex {
                    if text[contentEnd] == opener { depth += 1 }
                    if text[contentEnd] == closer {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    contentEnd = text.index(after: contentEnd)
                }
            } else {
                // A run of digits (maybe signed, like ^-1), or one letter.
                if opener == "-" || opener == "+" {
                    contentEnd = text.index(after: contentEnd)
                }
                if contentEnd < text.endIndex && text[contentEnd].isNumber {
                    while contentEnd < text.endIndex && text[contentEnd].isNumber { contentEnd = text.index(after: contentEnd) }
                    // An ion's charge: SO4^2- → SO₄²⁻.
                    if contentEnd < text.endIndex, "+-−".contains(text[contentEnd]) {
                        let afterSign = text.index(after: contentEnd)
                        if afterSign == text.endIndex || !(text[afterSign].isLetter || text[afterSign].isNumber) {
                            contentEnd = afterSign
                        }
                    }
                } else if contentEnd == contentStart {
                    contentEnd = text.index(after: contentEnd)
                }
            }
            // Spaces inside a power don't count: x^(3 + 3) → x³⁺³.
            let content = text[contentStart..<contentEnd].filter { $0 != " " }
            let mapped = content.compactMap { map[$0] }
            if !content.isEmpty, mapped.count == content.count {
                output.append(String(mapped))
                index = (opener == "{" || opener == "(") && contentEnd < text.endIndex ? text.index(after: contentEnd) : contentEnd
            } else {
                output.append(character)
                index = text.index(after: index)
            }
        }
        return output
    }
}

// MARK: - Plotting math

/// A function of x typed the usual way, for plot: 2x^2 - 3x + 1,
/// sin(x)/x, sqrt(x+4), |x|, e^(-x^2), 3(x-1)^2. Evaluated exactly, so the
/// curve Dottie draws is the real one.
struct DottieMathExpression {
    private indirect enum Node {
        case number(Double)
        case variable
        case unary(String, Node)
        case binary(Character, Node, Node)
        case function(String, Node)
    }

    private let root: Node

    init?(_ text: String) {
        var source = text.lowercased()
        if let equalsIndex = source.firstIndex(of: "=") {
            source = String(source[source.index(after: equalsIndex)...])
        }
        source = source
            .replacingOccurrences(of: "²", with: "^2").replacingOccurrences(of: "³", with: "^3")
            .replacingOccurrences(of: "√", with: "sqrt").replacingOccurrences(of: "π", with: "pi")
            .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "·", with: "*")
            .replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-")
        var parser = Parser(tokens: Parser.tokenize(source))
        guard let root = parser.parseExpression(), parser.isAtEnd else { return nil }
        self.root = root
    }

    func evaluate(x: Double) -> Double {
        Self.evaluate(root, x: x)
    }

    private static func evaluate(_ node: Node, x: Double) -> Double {
        switch node {
        case .number(let value): return value
        case .variable: return x
        case .unary(_, let operand): return -evaluate(operand, x: x)
        case .binary(let operation, let left, let right):
            let leftValue = evaluate(left, x: x), rightValue = evaluate(right, x: x)
            switch operation {
            case "+": return leftValue + rightValue
            case "-": return leftValue - rightValue
            case "*": return leftValue * rightValue
            case "/": return leftValue / rightValue
            default: return pow(leftValue, rightValue)
            }
        case .function(let name, let argument):
            let value = evaluate(argument, x: x)
            switch name {
            case "sin": return sin(value)
            case "cos": return cos(value)
            case "tan": return tan(value)
            case "asin", "arcsin": return asin(value)
            case "acos", "arccos": return acos(value)
            case "atan", "arctan": return atan(value)
            case "sqrt": return sqrt(value)
            case "abs": return abs(value)
            case "ln": return log(value)
            case "log": return log10(value)
            case "exp": return exp(value)
            default: return .nan
            }
        }
    }

    private enum Token: Equatable {
        case number(Double)
        case name(String)
        case symbol(Character)
    }

    private struct Parser {
        let tokens: [Token]
        var position = 0
        var isAtEnd: Bool { position >= tokens.count }

        static let functionNames: Set<String> = ["sin", "cos", "tan", "asin", "acos", "atan", "arcsin", "arccos", "arctan", "sqrt", "abs", "ln", "log", "exp"]

        static func tokenize(_ source: String) -> [Token] {
            var tokens: [Token] = []
            var index = source.startIndex
            while index < source.endIndex {
                let character = source[index]
                if character.isWhitespace {
                    index = source.index(after: index)
                } else if character.isNumber || character == "." {
                    var end = index
                    while end < source.endIndex && (source[end].isNumber || source[end] == ".") { end = source.index(after: end) }
                    tokens.append(.number(Double(source[index..<end]) ?? .nan))
                    index = end
                } else if character.isLetter {
                    var end = index
                    while end < source.endIndex && source[end].isLetter { end = source.index(after: end) }
                    // Split runs like "xsin" or "2pix" into known names and single letters.
                    var word = Substring(source[index..<end])
                    while !word.isEmpty {
                        if let known = (functionNames.sorted { $0.count > $1.count } + ["pi"]).first(where: { word.hasPrefix($0) }) {
                            tokens.append(.name(known))
                            word = word.dropFirst(known.count)
                        } else {
                            tokens.append(.name(String(word.first!)))
                            word = word.dropFirst()
                        }
                    }
                    index = end
                } else if character == "|" {
                    tokens.append(.symbol("|"))
                    index = source.index(after: index)
                } else {
                    tokens.append(.symbol(character))
                    index = source.index(after: index)
                }
            }
            return tokens
        }

        private func peek() -> Token? { position < tokens.count ? tokens[position] : nil }

        mutating func parseExpression() -> Node? {
            guard var left = parseTerm() else { return nil }
            while case .symbol(let operation)? = peek(), operation == "+" || operation == "-" {
                position += 1
                guard let right = parseTerm() else { return nil }
                left = .binary(operation, left, right)
            }
            return left
        }

        /// Products, including implied ones: 2x, 3(x+1), x sin(x).
        private mutating func parseTerm() -> Node? {
            guard var left = parseUnary() else { return nil }
            while let token = peek() {
                if case .symbol(let operation) = token, operation == "*" || operation == "/" {
                    position += 1
                    guard let right = parseUnary() else { return nil }
                    left = .binary(operation, left, right)
                } else if startsFactor(token) {
                    guard let right = parsePower() else { return nil }
                    left = .binary("*", left, right)
                } else {
                    break
                }
            }
            return left
        }

        private func startsFactor(_ token: Token) -> Bool {
            switch token {
            case .number, .name: return true
            case .symbol(let character): return character == "("
            }
        }

        private mutating func parseUnary() -> Node? {
            if case .symbol(let sign)? = peek(), sign == "-" || sign == "+" {
                position += 1
                guard let operand = parseUnary() else { return nil }
                return sign == "-" ? .unary("-", operand) : operand
            }
            return parsePower()
        }

        private mutating func parsePower() -> Node? {
            guard let base = parseAtom() else { return nil }
            if case .symbol("^")? = peek() {
                position += 1
                guard let exponent = parseUnary() else { return nil }
                return .binary("^", base, exponent)
            }
            return base
        }

        private mutating func parseAtom() -> Node? {
            guard let token = peek() else { return nil }
            position += 1
            switch token {
            case .number(let value):
                return value.isNaN ? nil : .number(value)
            case .name(let name):
                if name == "x" { return .variable }
                if name == "pi" { return .number(.pi) }
                if name == "e" { return .number(M_E) }
                guard Self.functionNames.contains(name) else { return nil }
                // sin(x), or sin x
                guard let argument = parsePower() else { return nil }
                return .function(name, argument)
            case .symbol("("):
                guard let inner = parseExpression(), case .symbol(")")? = peek() else { return nil }
                position += 1
                return inner
            case .symbol("|"):
                guard let inner = parseExpression(), case .symbol("|")? = peek() else { return nil }
                position += 1
                return .function("abs", inner)
            default:
                return nil
            }
        }
    }
}

// MARK: - Chart data

/// The numbers for a chart step: "Mon: 12; Tue: 9", "1, 3; 2, 5", or rows
/// read from a table the user circled.
enum DottieChartData {
    struct ChartPoint {
        let label: String?
        let x: Double?
        let value: Double
    }

    static func parse(_ dataText: String) -> [ChartPoint] {
        let entries = dataText
            .components(separatedBy: CharacterSet(charactersIn: ";\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return entries.prefix(200).compactMap(parseEntry)
    }

    private static func parseEntry(_ entry: String) -> ChartPoint? {
        // "label: value" or "label = value"
        if let separatorRange = entry.range(of: ":") ?? entry.range(of: "=") {
            let label = entry[..<separatorRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let valueText = entry[separatorRange.upperBound...].replacingOccurrences(of: ",", with: "")
            guard let value = numbers(in: valueText).last else { return nil }
            let labelIsNumber = Double(label) != nil
            return ChartPoint(label: label.isEmpty || labelIsNumber ? nil : label, x: labelIsNumber ? Double(label) : nil, value: value)
        }
        let hasLetters = entry.rangeOfCharacter(from: .letters) != nil
        let entryNumbers = numbers(in: entry)
        // "x, y"
        if !hasLetters, entryNumbers.count == 2 {
            return ChartPoint(label: nil, x: entryNumbers[0], value: entryNumbers[1])
        }
        // "Jan 1,200": the last number is the value, what's before it the label.
        let withoutThousands = entry.replacingOccurrences(of: #"(\d),(\d{3})"#, with: "$1$2", options: .regularExpression)
        guard let lastNumberRange = withoutThousands.range(of: #"-?\d+(\.\d+)?(?!.*\d)"#, options: .regularExpression),
              let value = Double(withoutThousands[lastNumberRange]) else { return nil }
        let label = withoutThousands[..<lastNumberRange.lowerBound]
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "|,$€£%")))
        return ChartPoint(label: label.isEmpty ? nil : label, x: label.isEmpty ? nil : Double(label), value: value)
    }

    private static func numbers(in text: String) -> [Double] {
        guard let expression = try? NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?"#) else { return [] }
        let wholeText = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: wholeText).compactMap { match in
            Range(match.range, in: text).flatMap { Double(text[$0]) }
        }
    }

    struct ValueScale {
        let minimum: Double
        let maximum: Double
        let ticks: [Double]
    }

    /// A value axis with round numbers, about five lines. Bars start at
    /// zero; lines fit the data so a trend is easy to see.
    static func valueScale(values: [Double], startsAtZero: Bool, givenRange: (Double, Double)?) -> ValueScale {
        var low = givenRange?.0 ?? (values.min() ?? 0)
        var high = givenRange?.1 ?? (values.max() ?? 1)
        if givenRange == nil && startsAtZero {
            low = min(low, 0)
            high = max(high, 0)
        }
        if high <= low {
            low -= 1
            high += 1
        }
        let roughStep = (high - low) / 5
        let magnitude = pow(10, floor(log10(roughStep)))
        let niceStep = [1.0, 2.0, 2.5, 5.0, 10.0].map { $0 * magnitude }.first { $0 >= roughStep } ?? roughStep
        let scaleMinimum = givenRange?.0 ?? floor(low / niceStep) * niceStep
        let scaleMaximum = givenRange?.1 ?? ceil(high / niceStep) * niceStep
        var ticks: [Double] = []
        var tick = ceil(scaleMinimum / niceStep) * niceStep
        while tick <= scaleMaximum + niceStep * 0.001 && ticks.count < 12 {
            ticks.append(tick)
            tick += niceStep
        }
        return ValueScale(minimum: scaleMinimum, maximum: scaleMaximum, ticks: ticks)
    }

    /// 12, 2.5, 1.2k, 3M.
    static func shortNumber(_ value: Double) -> String {
        let magnitude = abs(value)
        func trimmed(_ number: Double) -> String {
            number == number.rounded() ? String(Int(number)) : String(format: "%.1f", number)
        }
        if magnitude >= 1_000_000 { return trimmed(value / 1_000_000) + "M" }
        if magnitude >= 10_000 { return trimmed(value / 1_000) + "k" }
        if magnitude > 0 && magnitude < 1 { return String(format: "%.2f", value) }
        return trimmed((value * 10).rounded() / 10)
    }

    /// Reads what's inside an area of the screen on this Mac (sharp
    /// screenshot, Apple's text recognition) as rows top to bottom, cells
    /// split by " | ". Used for tables and numbers the user circled.
    @MainActor
    static func readRows(inGlobalRect circledRect: CGRect) async -> [String] {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(circledRect) }),
              let screenImage = await DottieDisplayCapture.captureImage(displayFrame: screen.frame, maximumDimension: 4096) else { return [] }
        let displayFrame = screen.frame
        let pixelsPerPoint = CGFloat(screenImage.width) / displayFrame.width
        let visibleRect = circledRect.intersection(displayFrame)
        // Image rows run top-down; AppKit's y runs up.
        let cropRect = CGRect(
            x: (visibleRect.minX - displayFrame.minX) * pixelsPerPoint,
            y: (displayFrame.maxY - visibleRect.maxY) * pixelsPerPoint,
            width: visibleRect.width * pixelsPerPoint,
            height: visibleRect.height * pixelsPerPoint
        ).integral
        guard let croppedImage = screenImage.cropping(to: cropRect) else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [String] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: croppedImage, options: [:])
            guard (try? handler.perform([request])) != nil else { return [] }
            let pieces = (request.results ?? []).compactMap { observation -> (text: String, box: CGRect)? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return (text: candidate.string, box: observation.boundingBox)
            }
            // Pieces whose middles sit at about the same height are one row.
            var rows: [[(text: String, box: CGRect)]] = []
            for piece in pieces.sorted(by: { $0.box.midY > $1.box.midY }) {
                if let lastRow = rows.last, let rowPiece = lastRow.first,
                   abs(rowPiece.box.midY - piece.box.midY) < max(rowPiece.box.height, piece.box.height) * 0.6 {
                    rows[rows.count - 1].append(piece)
                } else {
                    rows.append([piece])
                }
            }
            return rows.map { row in
                row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " | ")
            }
        }.value
    }

    /// Turns table rows into chart data: each row with a number becomes a
    /// point, labeled by its first words, valued by its last number. A
    /// header row without numbers is left out.
    static func chartText(fromRows rows: [String]) -> String {
        rows.compactMap { row -> String? in
            let cells = row.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
            let numericCells = cells.filter { cell in
                Double(cell.replacingOccurrences(of: #"[,$€£%\s]"#, with: "", options: .regularExpression)) != nil
            }
            guard let lastNumber = numericCells.last else { return nil }
            let valueText = lastNumber.replacingOccurrences(of: #"[,$€£%\s]"#, with: "", options: .regularExpression)
            let labelCell = cells.first { !numericCells.contains($0) } ?? (numericCells.count >= 2 ? numericCells[0] : nil)
            guard let labelCell else { return valueText }
            return "\(labelCell): \(valueText)"
        }.joined(separator: "; ")
    }
}
