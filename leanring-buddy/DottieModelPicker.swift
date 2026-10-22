//
//  DottieModelPicker.swift
//  leanring-buddy
//
//  Picks the quickest Gemini model that's good enough for each request,
//  and steers around models that are busy or slow right now.
//
//  Every request to the Worker's /chat names a model. The Worker already
//  falls back to other models when the named one is busy, but each miss
//  costs a round trip inside the Worker (and the free tier's per-model
//  limits). So the app remembers, per model, how long the last answers
//  took and whether it was busy (429/503, a timeout, or another model
//  answering in its place), and skips that model for a couple of minutes.
//
//  Three sizes:
//    tiny    quick lookups: a box on a screenshot, a one-line reply
//    normal  the usual screen-job step, guide or teaching request
//    hard    careful reading and reasoning (send_to_higher_model)
//

import Foundation

final class DottieModelPicker: @unchecked Sendable {
    static let shared = DottieModelPicker()

    enum Tier: String {
        case tiny, normal, hard
    }

    /// Best first. "higher" is the Worker's alias for its bigger model, so
    /// a Worker pointed at a stronger model keeps using it.
    static func candidates(for tier: Tier) -> [String] {
        switch tier {
        case .tiny: return ["gemini-3.5-flash-lite", "gemini-3.5-flash"]
        case .normal: return ["gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.7-flash"]
        case .hard: return ["higher", "gemini-3.7-flash", "gemini-3.6-flash"]
        }
    }

    /// How long a model is skipped after it was busy or slow.
    private static let coolDownSeconds: TimeInterval = 120

    private struct Health {
        var averageSeconds: Double?
        var skipUntil: Date?
        var lastProblem: String?
        var answeredCount = 0
        var busyCount = 0
    }

    private let lock = NSLock()
    private var healthByModel: [String: Health] = [:]

    // MARK: - Picking

    /// The first model of the tier that isn't cooling down; when they all
    /// are, the one that's back soonest.
    func pick(_ tier: Tier, avoiding avoidedModels: Set<String> = []) -> String {
        let candidates = Self.candidates(for: tier).filter { !avoidedModels.contains($0) }
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        if let ready = candidates.first(where: { (healthByModel[$0]?.skipUntil ?? .distantPast) <= now }) {
            return ready
        }
        return candidates.min { (healthByModel[$0]?.skipUntil ?? .distantPast) < (healthByModel[$1]?.skipUntil ?? .distantPast) }
            ?? Self.candidates(for: tier)[0]
    }

    /// Busy or slow lately, so skipped for now.
    func isCoolingDown(_ model: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (healthByModel[model]?.skipUntil ?? .distantPast) > Date()
    }

    /// A model is "slow" for its size when one answer takes longer than this.
    private static func slowSeconds(for model: String) -> Double {
        if model.contains("lite") { return 8 }
        if candidates(for: .hard).first == model { return 35 }
        return 18
    }

    // MARK: - Learning

    /// Notes how a request went. `answeredBy` is the modelVersion Gemini
    /// reported, which shows when the Worker had to use another model.
    func record(model: String, seconds: Double, statusCode: Int, answeredBy: String? = nil) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        var health = healthByModel[model] ?? Health()
        if [429, 500, 502, 503, 504].contains(statusCode) {
            health.busyCount += 1
            health.skipUntil = now.addingTimeInterval(Self.coolDownSeconds)
            health.lastProblem = statusCode == 429 ? "over its limit" : "busy"
        } else if statusCode == 200 {
            health.answeredCount += 1
            health.averageSeconds = health.averageSeconds.map { $0 * 0.6 + seconds * 0.4 } ?? seconds
            let wasReplaced = answeredBy.map { !$0.isEmpty && !$0.hasPrefix(model) && model != "higher" } ?? false
            if wasReplaced, let answeredBy {
                // The Worker fell back: the named model was busy, the one
                // that answered is fine.
                health.busyCount += 1
                health.skipUntil = now.addingTimeInterval(Self.coolDownSeconds)
                health.lastProblem = "busy (another model answered)"
                let answeringName = Self.candidates(for: .normal).first { answeredBy.hasPrefix($0) }
                    ?? Self.candidates(for: .tiny).first { answeredBy.hasPrefix($0) }
                if let answeringName, answeringName != model {
                    healthByModel[answeringName, default: Health()].skipUntil = nil
                }
            } else if seconds > Self.slowSeconds(for: model) {
                health.skipUntil = now.addingTimeInterval(Self.coolDownSeconds)
                health.lastProblem = "slow (\(Int(seconds))s)"
            } else {
                health.skipUntil = nil
                health.lastProblem = nil
            }
        }
        healthByModel[model] = health
    }

    /// Sends a /chat request and learns from how it went.
    /// `totalSeconds` caps the whole request. A request's own
    /// timeoutInterval only counts time with nothing arriving, so a slowly
    /// streamed answer could otherwise take minutes.
    func data(for request: URLRequest, model: String, totalSeconds: Double? = nil) async throws -> (Data, URLResponse) {
        let startedAt = Date()
        let deadlineSeconds = totalSeconds ?? (request.timeoutInterval + 10)
        do {
            let (responseData, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { requestGroup in
                requestGroup.addTask {
                    try await URLSession.shared.data(for: request)
                }
                requestGroup.addTask {
                    try await Task.sleep(nanoseconds: UInt64(deadlineSeconds * 1_000_000_000))
                    throw URLError(.timedOut)
                }
                defer { requestGroup.cancelAll() }
                guard let firstFinished = try await requestGroup.next() else { throw URLError(.unknown) }
                return firstFinished
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            record(
                model: model,
                seconds: Date().timeIntervalSince(startedAt),
                statusCode: statusCode,
                answeredBy: statusCode == 200 ? Self.answeringModel(in: responseData) : nil
            )
            return (responseData, response)
        } catch {
            if (error as? URLError)?.code == .timedOut {
                record(model: model, seconds: Date().timeIntervalSince(startedAt), statusCode: 504)
            }
            throw error
        }
    }

    /// The "modelVersion" Gemini puts in its answer, if any.
    static func answeringModel(in responseData: Data) -> String? {
        answeringModel(inText: String(decoding: responseData.prefix(4096), as: UTF8.self))
            ?? answeringModel(inText: String(decoding: responseData.suffix(4096), as: UTF8.self))
    }

    static func answeringModel(inText text: String) -> String? {
        guard let keyRange = text.range(of: "\"modelVersion\"") else { return nil }
        let rest = text[keyRange.upperBound...]
        guard let openingQuote = rest.firstIndex(of: "\"") else { return nil }
        let valueStart = rest.index(after: openingQuote)
        guard let closingQuote = rest[valueStart...].firstIndex(of: "\"") else { return nil }
        let value = String(rest[valueStart..<closingQuote])
        return value.isEmpty ? nil : value
    }

    // MARK: - Status

    /// One line per model that has answered or failed, for the self-check.
    func summary() -> String {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        guard !healthByModel.isEmpty else { return "No answers yet this session." }
        return healthByModel.keys.sorted().map { model in
            let health = healthByModel[model]!
            var line = model
            if let averageSeconds = health.averageSeconds {
                line += String(format: ": about %.1fs", averageSeconds)
            }
            if let skipUntil = health.skipUntil, skipUntil > now {
                line += ", skipped for \(Int(skipUntil.timeIntervalSince(now)))s (\(health.lastProblem ?? "busy"))"
            }
            return line
        }.joined(separator: "\n")
    }

    // MARK: - How hard is a request?

    /// Simple screen jobs ("open spotify", "pause the video") can use the
    /// quickest model. Apple's on-device model decides when the Mac has it;
    /// otherwise a short single-step request counts as simple.
    static func isSimpleScreenJob(_ taskText: String) async -> Bool {
        // The words often say on their own ("scroll down" is simple, "sign
        // in with this account" isn't), with no wait for the model.
        switch DottieTaskGoals.size(of: taskText) {
        case .short: return true
        case .long: return false
        case .unsure: break
        }
        if let answer = await DottieOnDeviceModel.classify(
            taskText,
            labels: ["simple", "complex"],
            instructions: """
            You sort requests for a Mac assistant that clicks and types on screen. \
            "simple" means one or two obvious actions in one app (open an app or site, press play, \
            click one named button). "complex" means several steps, searching, reading, comparing, \
            forms, or anything that needs care. Answer with one word: simple or complex.
            """
        ) {
            return answer == "simple"
        }
        let words = taskText.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let sequencingWords: Set<String> = ["and", "then", "after", "also", "find", "search", "reply", "tell", "check", "compare", "fill", "write", "send"]
        return words.count <= 7 && words.allSatisfy { !sequencingWords.contains($0) } && !taskText.contains(",")
    }

    /// For a question handed to a stronger model: hard unless the on-device
    /// model is sure it's a quick one.
    static func tier(forQuestion question: String) async -> Tier {
        guard let answer = await DottieOnDeviceModel.classify(
            question,
            labels: ["quick", "careful"],
            instructions: """
            You sort questions about what's on a user's screen. "quick" means a short factual \
            answer anyone could read off the screen at a glance. "careful" means reading small \
            text, code, documents, numbers, steps, or real reasoning. Answer with one word: quick or careful.
            """
        ) else { return .hard }
        return answer == "quick" ? .normal : .hard
    }
}
