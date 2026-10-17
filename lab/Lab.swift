// Pointing lab: runs each stage of Dottie's pointing on real screen content
// and reports what each stage found, with timings, as JSON.
import AppKit
import ApplicationServices
import Foundation

struct LabCase: Codable {
    let id: String
    let label: String
    let question: String
    let roughX: Double   // global points, top-left origin
    let roughY: Double
    let gt: [Double]?    // x, y, w, h top-left origin
    let stages: String?  // "all" (default) or "nolivision"
}

func box(_ r: CGRect?, _ h: CGFloat) -> [Double]? {
    guard let r else { return nil }
    return [Double(r.minX), Double(h - r.maxY), Double(r.width), Double(r.height)]
}

@main
struct Lab {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        let screen = NSScreen.screens.first!
        let H = screen.frame.maxY
        if args.count > 1, args[1] == "--screen" {
            print("{\"w\": \(screen.frame.width), \"h\": \(screen.frame.height), \"scale\": \(screen.backingScaleFactor), \"ax\": \(AXIsProcessTrusted()), \"screens\": \(NSScreen.screens.count)}")
            return
        }
        if args.count > 2, args[1] == "--shot" {
            // Native screenshot as PNG, via the same capture the app uses.
            guard let image = await DottieDisplayCapture.captureImage(displayFrame: screen.frame, maximumDimension: 8000) else {
                print("capture failed"); exit(1)
            }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[2]))
            print("ok \(image.width)x\(image.height)")
            return
        }
        let data = try! Data(contentsOf: URL(fileURLWithPath: args[1]))
        let cases = try! JSONDecoder().decode([LabCase].self, from: data)
        PointingRefiner.prepareFrontmostApplicationForSearch()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        var out: [[String: Any]] = []
        for c in cases {
            let rough = CGPoint(x: c.roughX, y: Double(H) - c.roughY)
            let words = PointingRefiner.significantWords(in: c.label)
            var t = Date()
            let ax = words.isEmpty ? nil : AccessibilityElementSearch.bestMatch(forLabelWords: words, near: rough)
            let axTime = -t.timeIntervalSinceNow
            t = Date()
            let ocr = await ScreenTextFinder.frameOfText(matching: c.label, near: rough, displayFrame: screen.frame)
            let ocrTime = -t.timeIntervalSinceNow
            let ocrSnap = ocr.map { AccessibilitySnap.refinedFrame($0) }
            var vision: CGRect?
            var visionTime = 0.0
            if c.stages != "novision" {
                t = Date()
                vision = await VisionElementLocator.locate(elementLabel: c.label, userQuestion: c.question, roughPoint: rough, displayFrame: screen.frame, deadline: Date().addingTimeInterval(5))
                visionTime = -t.timeIntervalSinceNow
            }
            let visionSnap = vision.map { AccessibilitySnap.refinedFrame($0) }
            let roughSnap = AccessibilitySnap.controlFrame(at: rough)
            let final: CGRect? = ax ?? ocrSnap ?? visionSnap
            let finalStage = ax != nil ? "ax" : (ocrSnap != nil ? "ocr" : (visionSnap != nil ? "vision" : "rough"))
            var row: [String: Any] = ["id": c.id, "label": c.label, "words": words, "rough": [c.roughX, c.roughY], "finalStage": finalStage,
                                      "axTime": axTime, "ocrTime": ocrTime, "visionTime": visionTime]
            for (k, v) in [("ax", ax), ("ocr", ocr), ("ocrSnap", ocrSnap), ("vision", vision), ("visionSnap", visionSnap), ("roughSnap", roughSnap), ("final", final)] {
                if let b = box(v, H) { row[k] = b }
            }
            if let gt = c.gt { row["gt"] = gt }
            out.append(row)
            FileHandle.standardError.write("case \(c.id) done: \(finalStage)\n".data(using: .utf8)!)
        }
        let json = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try! json.write(to: URL(fileURLWithPath: args[2]))
    }
}
