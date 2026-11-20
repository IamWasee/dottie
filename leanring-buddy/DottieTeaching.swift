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
        /// `sizeScale` grows or shrinks the board from its usual size
        /// (board_size), never past the screen.
        func boardRect(on visibleFrame: CGRect, sizeScale: CGFloat = 1) -> CGRect? {
            let margin: CGFloat = 24
            let largestSide = min(visibleFrame.width, visibleFrame.height) - margin * 2
            func scaled(_ usualSide: CGFloat) -> CGFloat { max(160, min(usualSide * sizeScale, largestSide)) }
            switch self {
            case .screen:
                return nil
            case .board_right, .board_left:
                let side = scaled(min(visibleFrame.width * 0.42, visibleFrame.height * 0.82))
                let x = self == .board_right ? visibleFrame.maxX - side - margin : visibleFrame.minX + margin
                return CGRect(x: x, y: visibleFrame.midY - side / 2, width: side, height: side)
            case .board_bottom:
                let side = scaled(min(visibleFrame.height * 0.45, visibleFrame.width * 0.6))
                return CGRect(x: visibleFrame.midX - side / 2, y: visibleFrame.minY + margin, width: side, height: side)
            case .board_center:
                let side = scaled(min(visibleFrame.height * 0.82, visibleFrame.width * 0.8))
                return CGRect(x: visibleFrame.midX - side / 2, y: visibleFrame.midY - side / 2, width: side, height: side)
            }
        }
    }

    /// board_size: how big the board is. small, medium, large and full
    /// are sizes; bigger and smaller change the board that's up.
    enum BoardSize: String, CaseIterable {
        case small, medium, large, full, bigger, smaller

        /// Scale from the usual board size.
        var scaleFromUsualSize: CGFloat {
            switch self {
            case .small: return 0.65
            case .medium: return 1
            case .large: return 1.35
            case .full: return 10 // capped at the screen
            case .bigger: return 1.3
            case .smaller: return 0.75
            }
        }

        /// The board that's up, resized: about its center, kept on the
        /// screen. bigger and smaller scale it; the sizes scale the usual
        /// board for this screen.
        func resized(_ currentBoard: CGRect, usualBoardSide: CGFloat, on visibleFrame: CGRect) -> CGRect {
            let margin: CGFloat = 24
            let largestSide = min(visibleFrame.width, visibleFrame.height) - margin * 2
            let wantedSide: CGFloat
            switch self {
            case .bigger, .smaller: wantedSide = currentBoard.width * scaleFromUsualSize
            default: wantedSide = usualBoardSide * scaleFromUsualSize
            }
            let side = max(160, min(wantedSide, largestSide))
            var resizedBoard = CGRect(x: currentBoard.midX - side / 2, y: currentBoard.midY - side / 2, width: side, height: side)
            resizedBoard.origin.x = min(max(resizedBoard.minX, visibleFrame.minX + margin), visibleFrame.maxX - margin - side)
            resizedBoard.origin.y = min(max(resizedBoard.minY, visibleFrame.minY + margin), visibleFrame.maxY - margin - side)
            return resizedBoard
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
        private(set) var steps: [Step]
        let keepsDrawing: Bool
        /// Draw onto the drawing that's already up (same board) instead of
        /// starting over, for "now add…" or "continue it" later on.
        let addsToLastDrawing: Bool
        /// Whether the model named a surface, so adding to a board keeps
        /// that board unless it asked for another one.
        let surfaceWasGiven: Bool
        /// board_size, when the model asked for one.
        let boardSize: BoardSize?

        init?(arguments: [String: Any]) {
            func trimmed(_ value: Any?) -> String? {
                let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return text?.isEmpty == false ? text : nil
            }
            let givenSurface = trimmed(arguments["surface"]).flatMap { Surface(rawValue: $0.lowercased()) }
            surfaceWasGiven = givenSurface != nil
            boardSize = trimmed(arguments["board_size"]).flatMap { BoardSize(rawValue: $0.lowercased()) }
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
                    points: DottieTeaching.pairingLoneNumbers(DottieTeaching.splittingPackedPoints(points)),
                    text: trimmed(fields["text"]),
                    ink: trimmed(fields["color"]).flatMap { DottieInk(rawValue: $0.lowercased()) },
                    size: trimmed(fields["size"])?.lowercased(),
                    caption: trimmed(fields["caption"]),
                    say: trimmed(fields["say"]),
                    range: ((fields["range"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.doubleValue },
                    style: trimmed(fields["style"])?.lowercased()
                )
            }
            // Only resizing the board that's up needs no steps.
            guard !steps.isEmpty || (addsToLastDrawing && boardSize != nil) else { return nil }
            // A graph, chart or picture that isn't about something on the
            // screen goes on a board: drawn over whatever the screen shows,
            // its lines and labels got lost in the page behind them.
            let marksAnchors = !anchors.isEmpty
            let marksCircledArea = steps.contains { step in
                step.points.contains { $0.lowercased().hasPrefix("circled") }
            }
            let referencesScreen = marksAnchors || marksCircledArea
            let drawsOwnPicture = steps.contains { [Kind.axes, .plot, .chart, .grid, .sketch].contains($0.kind) }
            surface = givenSurface ?? (drawsOwnPicture && !referencesScreen ? .board_right : .screen)
            // Kept up by default, so the user can ask to add to it later.
            keepsDrawing = (arguments["keep"] as? Bool) ?? true
        }

        /// What's wrong with each step that can't be drawn as given, worked
        /// out before anything is drawn, so the model fixes it instead of
        /// saying it drew something that never showed up.
        var problems: [String] {
            let knownAnchorNames = anchorNames.union(["circled"])
            return steps.enumerated().compactMap { stepIndex, step in
                DottieTeaching.problem(with: step, knownAnchorNames: knownAnchorNames).map { "step \(stepIndex + 1) (\(step.kind.rawValue)): \($0)" }
            }
        }

        var anchorNames: Set<String> { Set(anchors.map { $0.name.lowercased() }) }

        /// The same plan with only the steps that can be drawn. Refusing a
        /// whole drawing for one bad step left Live retrying in a loop
        /// (35 refusals for one supply and demand graph) and the user with
        /// nothing on screen.
        func keepingOnlyDrawableSteps() -> Plan {
            let knownAnchorNames = anchorNames.union(["circled"])
            var drawablePlan = self
            drawablePlan.steps = steps.filter { DottieTeaching.problem(with: $0, knownAnchorNames: knownAnchorNames) == nil }
            return drawablePlan
        }
    }

    /// Every refused drawing with its reasons, newest last (the last 50),
    /// in Application Support/Dottie/Diagnostics, so a drawing Live gets
    /// wrong can be read exactly instead of guessed at. The log hides the
    /// reasons unless details are switched on.
    static func recordRefusedDrawing(problems: [String], arguments: [String: Any], drewOtherSteps: Bool,
                                     into fileURL: URL = refusedDrawingsFileURL) {
        var entries = (try? JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))) as? [[String: Any]] ?? []
        var entry: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "problems": problems, "drewOtherSteps": drewOtherSteps]
        if JSONSerialization.isValidJSONObject(arguments) { entry["arguments"] = arguments }
        entries.append(entry)
        entries = Array(entries.suffix(50))
        guard let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = DottieFileSaver.save(data, to: fileURL)
    }

    static var refusedDrawingsFileURL: URL {
        let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return applicationSupportDirectory
            .appendingPathComponent("Dottie/Diagnostics", isDirectory: true)
            .appendingPathComponent("refused-drawings.json")
    }

    /// The two numbers of a point written any common way: "300,700",
    /// "300, 700", "(300, 700)", "[300 700]", "x=300 y=700". Nil unless
    /// there are exactly two.
    static func pointNumbers(_ reference: String) -> (Double, Double)? {
        guard let numberPattern = try? NSRegularExpression(pattern: "-?\\d+(?:\\.\\d+)?") else { return nil }
        let searchRange = NSRange(reference.startIndex..., in: reference)
        let numbers = numberPattern.matches(in: reference, range: searchRange).compactMap { match in
            Range(match.range, in: reference).flatMap { Double(reference[$0]) }
        }
        guard numbers.count == 2 else { return nil }
        // Words other than x/y labels mean it's a name ("label2 top"), not a point.
        let lettersLeft = reference.lowercased().filter(\.isLetter).filter { $0 != "x" && $0 != "y" }
        guard lettersLeft.isEmpty else { return nil }
        return (numbers[0], numbers[1])
    }

    /// Several points packed into one string, the way Live often sends
    /// them ("200,800,200,600,800,800" or "(200,800) (200,600)"), become
    /// one "x,y" each. A supply and demand graph came out as only its
    /// equilibrium dot because the axes and both lines arrived like this.
    /// Anchor names and single points are left as given.
    static func splittingPackedPoints(_ points: [String]) -> [String] {
        points.flatMap { reference -> [String] in
            let numbers = numbersOfPackedPoints(reference)
            guard numbers.count >= 4, numbers.count.isMultiple(of: 2) else { return [reference] }
            return stride(from: 0, to: numbers.count, by: 2).map { "\(numbers[$0]),\(numbers[$0 + 1])" }
        }
    }

    /// The numbers in a string that holds only numbers and separators
    /// (commas, spaces, brackets, semicolons, x/y labels), as written.
    /// Empty when there are other letters, since then it's a name.
    private static func numbersOfPackedPoints(_ reference: String) -> [String] {
        let lettersLeft = reference.lowercased().filter(\.isLetter).filter { $0 != "x" && $0 != "y" }
        guard lettersLeft.isEmpty,
              let numberPattern = try? NSRegularExpression(pattern: "-?\\d+(?:\\.\\d+)?") else { return [] }
        let searchRange = NSRange(reference.startIndex..., in: reference)
        return numberPattern.matches(in: reference, range: searchRange).compactMap { match in
            Range(match.range, in: reference).map { String(reference[$0]) }
        }
    }

    /// Points sent as lone numbers ["300", "700", "500", "200"] become
    /// pairs ["300,700", "500,200"]; anything else is left as given.
    static func pairingLoneNumbers(_ points: [String]) -> [String] {
        guard points.count >= 2, points.count.isMultiple(of: 2),
              points.allSatisfy({ Double($0) != nil }) else { return points }
        return stride(from: 0, to: points.count, by: 2).map { "\(points[$0]),\(points[$0 + 1])" }
    }

    /// Words on the board in capitals, like Cognito's lettering. Math,
    /// numbers, single letters (x, A) and color markings stay as written,
    /// since capitals would change what they mean.
    static func boardLettering(_ text: String) -> String {
        let mathCharacters = CharacterSet(charactersIn: "0123456789=+−-×÷^/()√πθ²³¹⁰⁴⁵⁶⁷⁸⁹₀₁₂₃₄₅₆₇₈₉≤≥≠≈±∫Δ°{}*_<>|")
        guard text.rangeOfCharacter(from: mathCharacters) == nil else { return text }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.contains(where: { $0.filter(\.isLetter).count >= 2 }) else { return text }
        return text.uppercased()
    }

    /// Why one step can't be drawn, or nil when it can. Mirrors what each
    /// draw function needs.
    static func problem(with step: Step, knownAnchorNames: Set<String>) -> String? {
        func isUsablePoint(_ reference: String) -> Bool {
            let name = reference.lowercased()
            if knownAnchorNames.contains(name) { return true }
            if pointNumbers(reference) != nil { return true }
            guard let dotIndex = name.lastIndex(of: ".") else { return false }
            return knownAnchorNames.contains(String(name[..<dotIndex]))
        }
        if let unusablePoint = step.points.first(where: { !isUsablePoint($0) }) {
            return "the point \"\(unusablePoint)\" is neither \"x,y\" numbers nor the name of an anchor you listed"
        }
        let neededPointCount: Int
        switch step.kind {
        case .line, .curve, .polygon, .arrow, .double_arrow, .ticks, .measure, .brace, .plot, .chart, .grid, .axes: neededPointCount = 2
        case .angle, .right_angle: neededPointCount = 3
        case .circle, .box, .highlight, .underline, .point, .text, .cross, .check, .sketch: neededPointCount = 1
        }
        if step.points.count < neededPointCount {
            return "needs at least \(neededPointCount) points, got \(step.points.count)"
        }
        switch step.kind {
        case .text where step.text == nil:
            return "needs the text to write"
        case .plot:
            guard let functionText = step.text, DottieMathExpression(functionText) != nil else {
                return "text must be a function of x like 2x + 1 or x^2 - 3 (got \"\(step.text ?? "")\"); for a concept graph like supply and demand, use axes and then line or curve steps with text labels"
            }
        case .chart:
            guard let dataText = step.text else { return "needs the data in text, like \"Mon: 12; Tue: 9\"" }
            if !dataText.lowercased().contains("circled"), DottieChartData.parse(dataText).isEmpty {
                return "couldn't read numbers from \"\(dataText)\"; write label: value pairs split by ; like \"Mon: 12; Tue: 9\""
            }
        case .sketch where step.text == nil && step.caption == nil:
            return "needs text saying what to draw"
        default:
            break
        }
        return nil
    }

    /// The space each piece of written text takes up, trimmed a little top
    /// and bottom so lines written close together don't count as touching.
    static func textRects(of figures: [DottieFigure]) -> [CGRect] {
        figures.compactMap { figure in
            guard case .text = figure.shape else { return nil }
            return figure.bounds.insetBy(dx: 0, dy: figure.bounds.height * 0.2)
        }
    }

    /// A text step moved down until it no longer sits on text already
    /// written, so two labels placed close together don't print over each
    /// other. Gives up after a few lines and leaves it where it ended.
    static func nudgedClearOfText(_ drawn: DrawnStep, occupiedTextRects: [CGRect]) -> DrawnStep {
        let ownTextRects = textRects(of: drawn.figures)
        guard !ownTextRects.isEmpty else { return drawn }
        let lineStep = (ownTextRects.map(\.height).max() ?? 30) * 0.8
        var downwardShift: CGFloat = 0
        for _ in 0..<8 {
            let overlaps = ownTextRects.contains { ownRect in
                let shiftedRect = ownRect.offsetBy(dx: 0, dy: -downwardShift)
                return occupiedTextRects.contains { $0.intersects(shiftedRect) }
            }
            guard overlaps else { break }
            downwardShift += lineStep
        }
        guard downwardShift > 0 else { return drawn }
        var shifted = drawn
        shifted.figures = drawn.figures.map { figure in
            guard case .text(let text, let origin, let fontSize) = figure.shape else { return figure }
            return DottieFigure(shape: .text(text, origin: CGPoint(x: origin.x, y: origin.y - downwardShift), fontSize: fontSize),
                                ink: figure.ink, lineWidth: figure.lineWidth, delay: figure.delay, drawDuration: figure.drawDuration)
        }
        shifted.penPath = drawn.penPath.map { CGPoint(x: $0.x, y: $0.y - downwardShift) }
        return shifted
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
            "color": ["type": "STRING", "enum": DottieInk.allCases.map(\.rawValue), "description": "Pen color. Leave it out for the plain pen (grey on the board); use a color only when it means something, and give a word and the part of the drawing it names the same color (the label Demand and its curve both blue). red is for acting on something (a minus sign, crossing out), green for ticks. A color goes back to grey once the next step is drawn, so color the thing you are talking about now."],
            "size": ["type": "STRING", "enum": ["small", "medium", "large"], "description": "Text size; medium unless it's a heading or a small note."],
            "caption": ["type": "STRING", "description": "2-4 words your cursor says as it draws this, like \"right angle\", \"radius = 6\" or \"slope is 3\"."],
            "say": ["type": "STRING", "description": "The sentence you say out loud for this step. It's spoken while this step is drawn."],
            "range": ["type": "ARRAY", "items": ["type": "NUMBER"], "description": "plot: xmin, xmax, ymin, ymax (default -10, 10, -10, 10). chart: ymin, ymax if you want a set value scale (default fits the data)."],
            "style": ["type": "STRING", "enum": ["line", "bar", "dots"], "description": "chart only: line (default, for trends over time), bar (for comparing amounts) or dots (a scatter)."]
        ]
        return [
            "name": functionName,
            "description": "Teach by drawing, like a tutor with a marker. Draw lines, arrows, curves, circles, angles, right-angle marks, lengths, braces, axes, real plots of functions and handwritten math, one step at a time, either over what's on screen (the video, diagram or page itself) or on a dark board that opens beside it. Use it on your own, without being asked, whenever you explain something visual or mathematical: geometry, graphs, equations, a worked problem, a diagram, a chart, a chess move. Show it, don't only say it. Your cursor holds the pen and says each step's caption. Give every step a say line: they're spoken one by one in sync with the drawing, so right after calling, say only two or three words like \"okay, watch\". When the user circled something with their cursor, the anchor circled is that area: write a worked answer or example beside it (text steps at circled.right, or on a board), mark it, or chart its numbers. To mark other things already on screen, list them in anchors with a precise description and use their names in points: Dottie finds their exact spot with a sharp screenshot, so never guess numbers for them. Numbers are for empty space and the board, and only say you marked something if you anchored it. Worked math, step-by-step solutions and notes go on the notes board with write_notes (it scrolls, keeps long lines whole and takes headings, lists and pictures); use a board here for diagrams and short labels, with each text step's math in symbols, never words. Use sketch to draw any picture of a thing (\"draw a horse\", a heart, a volcano, a cell), never try to build a picture out of lines and curves yourself. A how-to with stages (folding an envelope, a craft, a recipe) is several small sketch steps side by side on a board, one per stage ('1. a square sheet, corners marked', '2. side corners folded to the middle'…), each with a short numbered text label under it and an arrow to the next; never one sketch of the whole tutorial. Use plot only for a real function of x (y = 2x + 1); a concept graph (supply and demand, costs, a trend) is axes on a board, then a line or curve step per curve with its name as text at its end, and text labels spaced apart so none overlap. Use chart to graph data or a table (it draws the axes, scale, labels and the line or bars from the numbers, so never work out positions for data yourself; text circled graphs a table the user circled), grid for graph paper or a chart's grid (then lines, arrows or a polygon on it for a trend, like a falling line for a downward trend), measure for lengths, angle with its size, ticks for equal sides. The drawing stays up: when the user asks to add to it, change it or carry on (\"now show a downward trend on it\", \"label that\"), call this again with add_to_last true and only the new steps, using the same positions as before. If the user says stop or clear, call clear_drawings.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "surface": [
                        "type": "STRING",
                        "enum": Surface.allCases.map(\.rawValue),
                        "description": "screen draws over what's on screen, to mark the video or diagram itself. board_right, board_left, board_bottom or board_center opens a dark square board there for your own clean diagram and worked steps (0-1000 across and down the board); pick the side where it covers the least of what matters. Graphs, curves, charts and pictures go on a board unless they mark something on screen (left out, they open board_right). Steps that use anchors still point at the screen."
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
                    "add_to_last": ["type": "BOOLEAN", "description": "true adds these steps to the drawing already up, on the same board, instead of starting a new one. Use it whenever the user asks to add to, change or continue what you drew."],
                    "board_size": ["type": "STRING", "enum": BoardSize.allCases.map(\.rawValue), "description": "How big the board is: small, medium (default), large or full (as big as the screen allows). With add_to_last, any value resizes the board that's up and everything on it, and bigger or smaller change it from its size now; steps can then be empty. Use it whenever the user asks for a bigger, smaller or full-screen board."]
                ],
                "required": ["steps"]
            ]
        ]
    }

    // MARK: - Finding anchors

    /// One sharp screenshot of the display, and GLM finds every anchor on
    /// it at once. Returns each found anchor's frame in global
    /// AppKit coordinates, keyed by lowercased name.
    @MainActor
    static func locateAnchors(_ anchors: [Anchor], displayFrame: CGRect, userQuestion: String) async -> [String: CGRect] {
        guard !anchors.isEmpty,
              let image = await DottieDisplayCapture.captureImage(displayFrame: displayFrame, maximumDimension: 1920),
              let jpegData = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return [:]
        }
        // GLM finds them (celly: drawings stay off Jev).
        return await modelAnchorFrames(anchors, jpegData: jpegData, displayFrame: displayFrame, userQuestion: userQuestion)
    }

    /// A 0-1000 [ymin, xmin, ymax, xmax] box on the display's picture as a
    /// frame in global AppKit coordinates (bottom-left origin).
    static func appKitFrame(normalizedBox box: [Double], displayFrame: CGRect) -> CGRect {
        CGRect(
            x: displayFrame.minX + box[1] / 1000 * displayFrame.width,
            y: displayFrame.maxY - box[2] / 1000 * displayFrame.height,
            width: (box[3] - box[1]) / 1000 * displayFrame.width,
            height: (box[2] - box[0]) / 1000 * displayFrame.height
        )
    }

    @MainActor
    private static func modelAnchorFrames(_ anchors: [Anchor], jpegData: Data, displayFrame: CGRect, userQuestion: String) async -> [String: CGRect] {
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
            frames[name.lowercased()] = appKitFrame(normalizedBox: box, displayFrame: displayFrame)
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
            let match = anchorFrame(reference)
            if match == nil, let (horizontalPosition, verticalPosition) = DottieTeaching.pointNumbers(reference) {
                return numericPoint(horizontalPosition, verticalPosition)
            }
            guard let match else { return nil }
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
            // About 330 points a second, the pace Cognito draws curves at.
            min(max(Double(length(of: pen)) / 330, 0.3), 2.4)
        }
    }

    static func draw(_ step: Step, in space: Space) -> DrawnStep? {
        var drawn = DrawnStep()
        // Light by default; color only where it carries meaning (Cognito).
        let ink = step.ink ?? .white
        let label = step.text.map(DottieMathText.pretty).map(boardLettering)
        let points = step.points.compactMap(space.point)
        let fontSize: CGFloat = step.size == "small" ? 18 : (step.size == "large" ? 38 : 26)

        let wasDrawn: Bool
        switch step.kind {
        case .sketch:
            wasDrawn = drawSketch(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .line, .curve, .polygon:
            wasDrawn = drawLineCurveOrPolygon(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .arrow, .double_arrow:
            wasDrawn = drawArrow(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .circle:
            wasDrawn = drawCircle(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .box, .highlight:
            wasDrawn = drawBoxOrHighlight(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .underline:
            wasDrawn = drawUnderline(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .angle, .right_angle:
            wasDrawn = drawAngle(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .point:
            wasDrawn = drawPoint(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .text:
            wasDrawn = drawText(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .ticks:
            wasDrawn = drawTicks(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .measure:
            wasDrawn = drawMeasure(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .brace:
            wasDrawn = drawBrace(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .axes:
            wasDrawn = drawAxes(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .grid:
            wasDrawn = drawGrid(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .plot:
            wasDrawn = drawPlot(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .cross:
            wasDrawn = drawCross(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .chart:
            wasDrawn = drawChart(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        case .check:
            wasDrawn = drawCheck(step, in: space, points: points, label: label, ink: ink, fontSize: fontSize, into: &drawn)
        }
        guard wasDrawn else { return nil }
        return drawn.figures.isEmpty ? nil : drawn
    }

    /// A free drawing planned as pen strokes. False when the step has too little to draw.
    private static func drawSketch(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        let sketchStrokes = DottieSketchArtist.strokes(fromStepText: step.text)
        guard !sketchStrokes.isEmpty else { return false }
        let sketchRect: CGRect
        if points.count >= 2, let givenRect = rectangle(from: step, points: points, in: space) {
            sketchRect = givenRect
        } else if let center = points.first {
            let side: CGFloat = space.boardRect.map { $0.width * 0.6 } ?? 360
            sketchRect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        } else {
            return false
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
        return true
    }

    /// A line, a smooth curve or a closed shape through the points. False when the step has too little to draw.
    private static func drawLineCurveOrPolygon(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        guard points.count >= 2 else { return false }
        let closed = step.kind == .polygon
        drawn.add(.stroke(points: points, closed: closed, smooth: step.kind == .curve, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                  ink: ink, pen: closed ? points + [points[0]] : points)
        if let label, let lastPoint = points.last {
            drawn.addLabel(label, centeredAt: CGPoint(x: lastPoint.x + 24, y: lastPoint.y + 18), ink: ink)
        }
        return true
    }

    /// An arrow, with a head at both ends for a double arrow. False when the step has too little to draw.
    private static func drawArrow(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        guard points.count >= 2 else { return false }
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
        return true
    }

    /// A ring around a thing, or a circle from a center and a point on it. False when the step has too little to draw.
    private static func drawCircle(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        let ring: [CGPoint]
        if let firstReference = step.points.first, let frame = space.wholeAnchor(firstReference), step.points.count == 1 {
            ring = ellipsePoints(in: frame.insetBy(dx: -10, dy: -8))
        } else if points.count >= 2 {
            let radius = distance(points[0], points[1])
            ring = ellipsePoints(in: CGRect(x: points[0].x - radius, y: points[0].y - radius, width: radius * 2, height: radius * 2))
        } else if let center = points.first {
            ring = ellipsePoints(in: CGRect(x: center.x - 28, y: center.y - 28, width: 56, height: 56))
        } else {
            return false
        }
        drawn.add(.stroke(points: ring, closed: true, smooth: true, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                  ink: ink, pen: ring, duration: 0.7)
        if let label, let topPoint = ring.max(by: { $0.y < $1.y }) {
            drawn.addLabel(label, centeredAt: CGPoint(x: topPoint.x, y: topPoint.y + 20), ink: ink)
        }
        return true
    }

    /// A box around an area, or the area filled in as a highlight. False when the step has too little to draw.
    private static func drawBoxOrHighlight(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        guard let rect = rectangle(from: step, points: points, in: space) else { return false }
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
        return true
    }

    /// A line under a thing or between two points. False when the step has too little to draw.
    private static func drawUnderline(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        let start: CGPoint, end: CGPoint
        if let firstReference = step.points.first, let frame = space.wholeAnchor(firstReference), step.points.count == 1 {
            start = CGPoint(x: frame.minX - 2, y: frame.minY - 5)
            end = CGPoint(x: frame.maxX + 2, y: frame.minY - 6)
        } else if points.count >= 2 {
            start = points[0]
            end = points[1]
        } else {
            return false
        }
        drawn.add(.stroke(points: [start, end], closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                  ink: ink, pen: [start, end])
        return true
    }

    /// An arc or a right-angle mark at a corner. False when the step has too little to draw.
    private static func drawAngle(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        guard points.count >= 3 else { return false }
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
        return true
    }

    /// A dot, with its label beside it. False when the step has too little to draw.
    private static func drawPoint(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        guard let point = points.first else { return false }
        drawn.add(.dot(center: point, radius: 5.5), ink: ink, pen: [point], duration: 0.25)
        if let label {
            drawn.addText(label, origin: CGPoint(x: point.x + 10, y: point.y + 16), fontSize: 22, ink: ink)
        }
        return true
    }

    /// Handwritten text or math. False when the step has too little to draw.
    private static func drawText(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        guard let label else { return false }
        let origin: CGPoint
        if let firstReference = step.points.first, let frame = space.wholeAnchor(firstReference) {
            origin = CGPoint(x: frame.maxX + 14, y: frame.midY)
        } else if let point = points.first {
            origin = point
        } else {
            return false
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
        return true
    }

    /// Small marks that show sides are equal. False when the step has too little to draw.
    private static func drawTicks(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        guard points.count >= 2 else { return false }
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
        return true
    }

    /// A length shown between two points. False when the step has too little to draw.
    private static func drawMeasure(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        guard points.count >= 2 else { return false }
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
        return true
    }

    /// A brace along a span, with its label. False when the step has too little to draw.
    private static func drawBrace(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        guard points.count >= 2 else { return false }
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
        return true
    }

    /// The x and y axes. False when the step has too little to draw.
    private static func drawAxes(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        guard points.count >= 2 else { return false }
        let origin = points[0]
        // Two points are the origin and the far corner of the graph.
        let axisEnds = points.count >= 3
            ? [points[1], points[2]]
            : [CGPoint(x: points[1].x, y: origin.y), CGPoint(x: origin.x, y: points[1].y)]
        for axisEnd in axisEnds {
            drawn.add(.stroke(points: [origin, axisEnd], closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: true),
                      ink: step.ink ?? .grey, lineWidth: 2.5, pen: [origin, axisEnd])
        }
        let names = (label ?? "x,y").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        drawn.addLabel(names.first ?? "x", centeredAt: CGPoint(x: axisEnds[0].x + 4, y: axisEnds[0].y - 22), fontSize: 20, ink: step.ink ?? .grey)
        if names.count > 1 {
            drawn.addLabel(names[1], centeredAt: CGPoint(x: axisEnds[1].x + 20, y: axisEnds[1].y + 4), fontSize: 20, ink: step.ink ?? .grey)
        }
        return true
    }

    /// A grid with numbered lines. False when the step has too little to draw.
    private static func drawGrid(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        guard points.count >= 2 else { return false }
        let gridArea = CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                              width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
        guard gridArea.width > 20, gridArea.height > 20 else { return false }
        // "8x5" is 8 cells across and 5 down; one number is the cells
        // across, with square-ish cells down.
        let cellCounts = (step.text ?? "")
            .lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "x× ,"))
            .compactMap { Int($0) }
        let columnCount = min(max(cellCounts.first ?? 10, 1), 40)
        let defaultRowCount = Int((CGFloat(columnCount) * gridArea.height / gridArea.width).rounded())
        let rowCount = min(max(cellCounts.count > 1 ? cellCounts[1] : defaultRowCount, 1), 40)
        let gridInk = step.ink ?? .grey
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
        return true
    }

    /// The real curve of a function of x. False when the step has too little to draw.
    private static func drawPlot(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        guard points.count >= 2, let expressionText = step.text,
              let function = DottieMathExpression(expressionText) else { return false }
        let area = CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                          width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
        guard area.width > 20, area.height > 20 else { return false }
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
                      ink: .grey, lineWidth: 1.5, pen: axis, duration: 0.25)
        }
        if yMin < 0, yMax > 0 {
            let axis = [screenPoint(xMin, 0), screenPoint(xMax, 0)]
            drawn.add(.stroke(points: axis, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: true),
                      ink: .grey, lineWidth: 1.5, pen: axis, duration: 0.25)
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
        guard !curves.isEmpty else { return false }
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
        return true
    }

    /// An X through something wrong. False when the step has too little to draw.
    private static func drawCross(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        guard let point = points.first else { return false }
        let first = [CGPoint(x: point.x - 12, y: point.y + 12), CGPoint(x: point.x + 12, y: point.y - 12)]
        let second = [CGPoint(x: point.x + 12, y: point.y + 12), CGPoint(x: point.x - 12, y: point.y - 12)]
        drawn.add(.stroke(points: first, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                  ink: step.ink ?? .red, lineWidth: 4, pen: first, duration: 0.2)
        drawn.add(.stroke(points: second, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                  ink: step.ink ?? .red, lineWidth: 4, pen: second, duration: 0.2)
        return true
    }

    /// A bar or line chart from data. False when the step has too little to draw.
    private static func drawChart(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        guard points.count >= 2, let dataText = step.text else { return false }
        let chartPoints = DottieChartData.parse(dataText)
        guard !chartPoints.isEmpty else { return false }
        // Room on the left for the scale and below for the labels.
        let outerArea = CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                               width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
        let scaleLabelFontSize: CGFloat = 15
        let plotArea = CGRect(x: outerArea.minX + 46, y: outerArea.minY + 30,
                              width: outerArea.width - 56, height: outerArea.height - 40)
        guard plotArea.width > 40, plotArea.height > 40 else { return false }
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
        return true
    }

    /// A check mark. False when the step has too little to draw.
    private static func drawCheck(_ step: Step, in space: Space, points: [CGPoint], label: String?, ink: DottieInk, fontSize: CGFloat, into drawn: inout DrawnStep) -> Bool {
        guard let point = points.first else { return false }
        let tick = [CGPoint(x: point.x - 12, y: point.y + 2), CGPoint(x: point.x - 3, y: point.y - 9), CGPoint(x: point.x + 15, y: point.y + 14)]
        drawn.add(.stroke(points: tick, closed: false, smooth: false, dashed: false, arrowAtStart: false, arrowAtEnd: false),
                  ink: step.ink ?? .green, lineWidth: 4, pen: tick, duration: 0.3)
        return true
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
