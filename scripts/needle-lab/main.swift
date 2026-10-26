// Needle lab: runs Dottie's real DottieNeedleEngine + DottieNeedleToolsets
// against the real engine on a macOS runner. Not part of the app.
import Foundation

let arguments = CommandLine.arguments
let folder = URL(fileURLWithPath: arguments[1])
let engine = DottieNeedleEngine(
    libraryURL: folder.appendingPathComponent("libneedle3.dylib"),
    needleWeightsURL: folder.appendingPathComponent("needle3.cact"),
    whistleWeightsURL: folder.appendingPathComponent("whistle.cact")
)

func normalized(_ text: String) -> String {
    text.lowercased().replacingOccurrences(of: #"[,;:!?"]|\.(?!\w)"#, with: " ", options: .regularExpression)
        .split(separator: " ").joined(separator: " ")
}

func run() async {
    let loadStart = Date()
    let prepared = await engine.prepare()
    print("prepare: \(prepared) in \(Int(Date().timeIntervalSince(loadStart) * 1000)) ms, reason: \(await engine.lastFailureReason ?? "-")")
    guard prepared else { exit(1) }

    let cases: [(String, String?)] = [
        ("open safari", "open safari"),
        ("could you pop safari open for me", "open safari"),
        ("fire up spotify", "open spotify"),
        ("get me into notes", "open notes"),
        ("bring up my email", "open email|open mail"),
        ("close out slack", "quit slack"),
        ("kill zoom", "quit zoom"),
        ("shut slack down", "quit slack"),
        ("snap chrome to the left side", "put chrome on the left"),
        ("throw this on my other monitor", "put this window on my other screen"),
        ("make safari take up the whole screen", "put safari full screen"),
        ("center the window", "put this window in the center"),
        ("stop the song", "pause"),
        ("skip this one", "next song"),
        ("go back to the last track", "previous song"),
        ("put the music back on", "play"),
        ("turn it down a little", "volume down"),
        ("crank it up", "volume up"),
        ("sound off", "mute"),
        ("set volume to 30 percent", "set the volume to 30"),
        ("make it 50 percent volume", "set the volume to 50"),
        ("quit slack and open notes", "quit slack|open notes"),
        ("what's the capital of france", nil),
        ("explain this error on my screen", nil),
        ("write an email to john saying i'm late", nil),
        ("what time is it", nil),
        ("click the blue button", nil),
        ("how do i open a terminal", nil),
        ("tell me a joke", nil),
        ("open the second link on this page", nil),
        ("play the next video", nil),
        ("search youtube for lofi beats", "search youtube for lofi beats"),
        ("look up the weather in paris on google", "google the weather in paris"),
        ("google how tall is mount everest", "google how tall is mount everest"),
        ("find me cat videos on youtube", "search youtube for cat videos"),
        ("search my files for the tax pdf", nil),
        ("remind me tomorrow at 7 pm to call mom", "add_reminder"),
        ("remind me to buy milk", "add_reminder"),
        ("put lunch with sam on my calendar friday at noon", "add_calendar_event"),
        ("schedule a meeting with the design team next tuesday at 3", "add_calendar_event"),
        ("what's on my calendar today", nil),
    ]
    var totalMilliseconds = 0.0
    var callCount = 0
    var right = 0
    for (text, expected) in cases {
        let request = normalized(text)
        let toolset = DottieNeedleToolset.toolset(forNormalizedRequest: request)
        guard let answer = await engine.toolCalls(for: request, toolsJSON: toolset.toolsJSON, facts: DottieNeedleToolset.systemFacts()) else {
            print("FAIL call: \(text) -> \(await engine.lastFailureReason ?? "?")"); continue
        }
        totalMilliseconds += answer.milliseconds; callCount += 1
        var gotParts: [String] = []
        for call in answer.toolCalls {
            if let words = DottieNeedleToolset.instantCommandWords(for: call) { gotParts.append(words) }
            else if let step = DottieNeedleToolset.organizerStep(for: call, fullRequest: request) { gotParts.append("\(step.functionName) \(step.arguments)") }
            else { gotParts.append("?\(call.name) \(call.arguments)") }
        }
        let got = gotParts.joined(separator: "|")
        let ok: Bool
        if let expected {
            ok = expected.split(separator: "|").count == gotParts.count && (expected.contains("add_") ? got.hasPrefix(expected) : expected.split(separator: "|").map(String.init) == gotParts || expected == got || expected.components(separatedBy: "|").contains(got))
        } else { ok = gotParts.isEmpty }
        if ok { right += 1 }
        let conf = answer.confidence.map { String(format: "%.2f", $0) } ?? "nil"
        print("\(ok ? "OK  " : "MISS") [\(toolset.rawValue)] \(text) => \(got.isEmpty ? "(none)" : got) conf=\(conf) withheld=\(answer.withheldToolCalls.map { "\($0.name)\($0.arguments)" }) \(Int(answer.milliseconds))ms reason=\(answer.reasoning.prefix(80))")
    }
    print("tool calls: \(right)/\(cases.count) right, average \(Int(totalMilliseconds / Double(max(callCount, 1)))) ms")

    // Embeddings: paraphrases vs unrelated.
    let pairs: [(String, String)] = [
        ("open my mail", "check my email"), ("open my mail", "open my email"), ("focus mode", "focus time"),
        ("start my work setup", "set up my work stuff"), ("play my chill playlist", "put on my relaxing music"),
        ("open my mail", "play my chill playlist"), ("focus mode", "open my mail"), ("start my work setup", "turn off the lights"),
        ("open spotify", "open safari"), ("quit slack", "open slack"),
    ]
    for (first, second) in pairs {
        let embedStart = Date()
        guard let firstVector = await engine.embedding(for: first), let secondVector = await engine.embedding(for: second) else { print("embed failed"); break }
        print(String(format: "embed %.3f  %@  ~  %@  (%d ms for two, dim %d)", DottieNeedleEngine.similarity(firstVector, secondVector), first, second, Int(Date().timeIntervalSince(embedStart) * 1000), firstVector.count))
    }

    // find_tool style ranking.
    let toolDescriptions = [
        "save_app_lesson": "Remember a correction the user gave about how one of their apps works.",
        "auto_type": "Type text into the app in front like a human, with real key presses.",
        "game_maps": "List, open or delete the maps Dottie made of video games.",
        "take_screenshot": "Save a screenshot of the screen, a window or an area to the Desktop or clipboard.",
        "add_reminder": "Add a reminder to the Reminders app, optionally at a time.",
        "control_device": "Control a smart home device: lights, plugs, thermostat, TV.",
        "send_file_to_phone": "Send a file from the Mac to the user's phone over Telegram.",
        "install_skills": "Install skills for Dots from a folder.",
    ]
    var describedVectors: [(String, [Float])] = []
    for (name, description) in toolDescriptions { if let vector = await engine.embedding(for: description) { describedVectors.append((name, vector)) } }
    for query in ["capture what's on my display", "dim the bedroom lamp", "type this essay for me", "get this pdf onto my phone", "you clicked the wrong menu in figma, it's under view", "show me the map of minecraft"] {
        guard let queryVector = await engine.embedding(for: query) else { continue }
        let ranked = describedVectors.map { ($0.0, DottieNeedleEngine.similarity(queryVector, $0.1)) }.sorted { $0.1 > $1.1 }
        print("find_tool \(query) -> " + ranked.prefix(3).map { String(format: "%@ %.2f", $0.0, $0.1) }.joined(separator: ", "))
    }

    // Sorting asks (model picker) as extraction into an enum.
    let sortTools = """
    [{"name": "sort_task", "description": "Say how hard a job on the Mac screen is.", "parameters": {"type": "object", "properties": {"kind": {"type": "string", "enum": ["simple", "complex"], "description": "simple: one or two obvious actions in one app. complex: several steps, searching, reading, comparing, forms."}}, "required": ["kind"]}}]
    """
    for task in ["open spotify", "pause the video", "click the subscribe button", "find the cheapest flight to tokyo next month and book it", "fill in this form with my details", "compare these two laptops and tell me which is better"] {
        let answer = await engine.toolCalls(for: task, toolsJSON: sortTools, facts: "")
        print("sort \(task) -> \(answer?.toolCalls.first?.arguments["kind"] ?? "(none)") conf=\(answer?.confidence ?? -1) \(Int(answer?.milliseconds ?? -1))ms")
    }

    // Whistle.
    for clip in arguments.dropFirst(2) {
        guard let samples = readWav(clip) else { print("no wav \(clip)"); continue }
        let transcript = await engine.transcribe(samples: samples, keywords: ["Safari", "Spotify", "Slack", "Notes", "Chrome"])
        print("whistle \(URL(fileURLWithPath: clip).lastPathComponent) (\(String(format: "%.1f", Double(samples.count) / 16000)) s) -> \(transcript?.text ?? "nil: \(await engine.lastFailureReason ?? "")") \(Int(transcript?.milliseconds ?? -1))ms")
    }
    // Needle still works after Whistle loaded?
    let after = await engine.toolCalls(for: "fire up spotify", toolsJSON: DottieNeedleToolset.mac.toolsJSON, facts: DottieNeedleToolset.systemFacts())
    print("after whistle: \(after?.toolCalls ?? []) \(await engine.lastFailureReason ?? "")")
    print(await engine.statusText())
}

func readWav(_ path: String) -> [Float]? {
    guard let data = FileManager.default.contents(atPath: path), data.count > 44 else { return nil }
    // Find the "data" chunk.
    var offset = 12
    while offset + 8 <= data.count {
        let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
        let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
        if id == "data" {
            let body = data[(offset + 8)..<min(offset + 8 + size, data.count)]
            return stride(from: body.startIndex, to: body.endIndex - 1, by: 2).map { index in
                Float(Int16(bitPattern: UInt16(body[index]) | UInt16(body[index + 1]) << 8)) / 32768
            }
        }
        offset += 8 + size + (size & 1)
    }
    return nil
}

let done = DispatchSemaphore(value: 0)
Task { await run(); done.signal() }
done.wait()
