//
//  DottieNeedleEngine.swift
//  leanring-buddy
//
//  Cactus Needle 3 (Apache-2.0, github.com/cactus-compute/needle): a tiny
//  on-device model (29 MB) that turns a sentence into tool calls with a
//  confidence score, pulls typed fields out of text, and gives a vector
//  for a sentence. Whistle (16.9 MB), its speech-to-text sibling, runs on
//  the same engine. Neither can chat or see, so they never replace
//  Gemini; they let Dottie do more on the Mac before Gemini is needed.
//
//  scripts/embed-needle.sh puts the engine (libneedle3.dylib, arm64 and
//  x86_64) in Contents/Frameworks and the weights in
//  Contents/Resources/Needle at build time. The library is opened with
//  dlopen when first used, so a build without it (offline when it was
//  made) still runs and every caller quietly carries on without Needle.
//
//  The engine is one global model with one toolset at a time, so this is
//  an actor: calls run one after another. Each call takes milliseconds.
//

import Darwin
import Foundation

actor DottieNeedleEngine {
    static let shared = DottieNeedleEngine(
        libraryURL: DottieNeedleEngine.bundledFileURL(named: "libneedle3.dylib", inFrameworks: true),
        needleWeightsURL: DottieNeedleEngine.bundledFileURL(named: "needle3.cact", inFrameworks: false),
        whistleWeightsURL: DottieNeedleEngine.bundledFileURL(named: "whistle.cact", inFrameworks: false)
    )

    /// One tool call Needle chose. Arguments are flattened to text
    /// (numbers and booleans as their JSON spelling), which is all the
    /// callers need and keeps the type Sendable.
    struct ToolCall: Sendable, Equatable {
        let name: String
        let arguments: [String: String]
    }

    struct Answer: Sendable {
        let toolCalls: [ToolCall]
        /// Calls the engine held back because it wasn't sure enough.
        let withheldToolCalls: [ToolCall]
        /// 0…1, calibrated. Nil when the weights have no confidence head.
        let confidence: Double?
        let reasoning: String
        let milliseconds: Double
    }

    struct Transcript: Sendable {
        let text: String
        let language: String
        let milliseconds: Double
    }

    // The C API (needle.h). Every call returns a negative number on failure.
    private typealias LoadFunction = @convention(c) (UnsafePointer<CChar>?, UInt64) -> Int32
    private typealias InitFunction = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    private typealias CompleteFunction = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<Float>?, Int32, Int32, UnsafeMutablePointer<CChar>?, Int32
    ) -> Int32
    private typealias EmbedFunction = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<Float>?, Int32, UnsafeMutablePointer<Float>?, Int32
    ) -> Int32
    private typealias ResetFunction = @convention(c) () -> Void
    private typealias TranscribeFunction = @convention(c) (
        UnsafePointer<Float>?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<CChar>?, Int32
    ) -> Int32
    private typealias LastErrorFunction = @convention(c) () -> UnsafePointer<CChar>?

    private struct EngineFunctions {
        let load: LoadFunction
        let initialize: InitFunction
        let complete: CompleteFunction
        let embed: EmbedFunction
        let reset: ResetFunction
        let transcribe: TranscribeFunction?
        let lastError: LastErrorFunction?
    }

    private let libraryURL: URL?
    private let needleWeightsURL: URL?
    private let whistleWeightsURL: URL?

    private var engineFunctions: EngineFunctions?
    private var hasTriedLoading = false
    private var isWhistleLoaded = false
    private var hasTriedLoadingWhistle = false
    /// The weights stay in memory for as long as the engine may read them.
    private var loadedWeightsData: [Data] = []
    /// The toolset needle_init was last given, so a repeat skips it.
    private var currentToolsetKey: String?
    private var outputBuffer = [CChar](repeating: 0, count: 1 << 16)

    private(set) var lastFailureReason: String?
    private(set) var lastCallMilliseconds: Double?

    init(libraryURL: URL?, needleWeightsURL: URL?, whistleWeightsURL: URL?) {
        self.libraryURL = libraryURL
        self.needleWeightsURL = needleWeightsURL
        self.whistleWeightsURL = whistleWeightsURL
    }

    /// Settings → Instant commands → "Use Needle". On by default.
    nonisolated static let isEnabledDefaultsKey = "dottieNeedleEnabled"

    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: isEnabledDefaultsKey) as? Bool ?? true
    }

    /// Whether this build carries the engine and weights at all.
    nonisolated var isBundled: Bool {
        libraryURL != nil && needleWeightsURL != nil
    }

    nonisolated var isWhistleBundled: Bool {
        libraryURL != nil && whistleWeightsURL != nil
    }

    /// Contents/Frameworks for the library, Contents/Resources/Needle for
    /// weights; Application Support/Dottie/Models/Needle as a fallback, so a
    /// build made offline can still be given the files by hand.
    nonisolated static func bundledFileURL(named fileName: String, inFrameworks: Bool) -> URL? {
        var candidateURLs: [URL] = []
        if inFrameworks, let frameworksURL = Bundle.main.privateFrameworksURL {
            candidateURLs.append(frameworksURL.appendingPathComponent(fileName))
        }
        if let resourcesURL = Bundle.main.resourceURL {
            candidateURLs.append(resourcesURL.appendingPathComponent("Needle", isDirectory: true).appendingPathComponent(fileName))
        }
        if let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidateURLs.append(applicationSupportURL.appendingPathComponent("Dottie/Models/Needle", isDirectory: true).appendingPathComponent(fileName))
        }
        return candidateURLs.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Loading

    /// Opens the engine and loads Needle's weights the first time.
    /// Returns false (and remembers why) when it can't.
    func prepare() -> Bool {
        if engineFunctions != nil { return true }
        guard !hasTriedLoading else { return false }
        hasTriedLoading = true

        guard let libraryURL, let needleWeightsURL else {
            lastFailureReason = "This build doesn't include Needle."
            return false
        }
        // The engine sends anonymous usage counts unless told not to.
        setenv("NEEDLE_TELEMETRY", "0", 1)
        setenv("DO_NOT_TRACK", "1", 1)

        guard let libraryHandle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            lastFailureReason = "Couldn't open the Needle engine: " + (dlerror().map { String(cString: $0) } ?? "unknown error")
            return false
        }
        func symbol<FunctionType>(_ symbolName: String, as functionType: FunctionType.Type) -> FunctionType? {
            guard let symbolAddress = dlsym(libraryHandle, symbolName) else { return nil }
            return unsafeBitCast(symbolAddress, to: functionType)
        }
        guard let loadFunction = symbol("needle_load", as: LoadFunction.self),
              let initFunction = symbol("needle_init", as: InitFunction.self),
              let completeFunction = symbol("needle_complete", as: CompleteFunction.self),
              let embedFunction = symbol("needle_embed", as: EmbedFunction.self),
              let resetFunction = symbol("needle_reset", as: ResetFunction.self) else {
            lastFailureReason = "The Needle engine is missing a function this version of Dottie needs."
            return false
        }
        let functions = EngineFunctions(
            load: loadFunction,
            initialize: initFunction,
            complete: completeFunction,
            embed: embedFunction,
            reset: resetFunction,
            transcribe: symbol("needle_transcribe", as: TranscribeFunction.self),
            lastError: symbol("needle_last_error", as: LastErrorFunction.self)
        )

        guard loadWeights(at: needleWeightsURL, using: functions) else { return false }
        engineFunctions = functions
        lastFailureReason = nil
        return true
    }

    private func loadWeights(at weightsURL: URL, using functions: EngineFunctions) -> Bool {
        guard let weightsData = try? Data(contentsOf: weightsURL, options: .alwaysMapped) else {
            lastFailureReason = "Couldn't read \(weightsURL.lastPathComponent)."
            return false
        }
        let loadResult = weightsData.withUnsafeBytes { weightsBytes in
            functions.load(weightsBytes.baseAddress?.assumingMemoryBound(to: CChar.self), UInt64(weightsBytes.count))
        }
        guard loadResult >= 0 else {
            lastFailureReason = "Needle couldn't load \(weightsURL.lastPathComponent): " + lastEngineError(functions)
            return false
        }
        loadedWeightsData.append(weightsData)
        return true
    }

    private func lastEngineError(_ functions: EngineFunctions?) -> String {
        guard let lastErrorPointer = functions?.lastError?() else { return "unknown error" }
        return String(cString: lastErrorPointer)
    }

    // MARK: Tool calls

    /// One stateless turn: which of the tools (JSON schema array) the text
    /// asks for. `facts` are Needle's system facts ("date: …; locale: …").
    /// Nil when Needle isn't available or the call failed.
    func toolCalls(for text: String, toolsJSON: String, facts: String, maximumNewTokens: Int = 256) -> Answer? {
        guard Self.isEnabled, prepare(), let functions = engineFunctions else { return nil }
        let startTime = Date()

        let toolsetKey = facts + "\u{1}" + toolsJSON
        if toolsetKey != currentToolsetKey {
            let initResult = facts.withCString { factsPointer in
                toolsJSON.withCString { toolsPointer in
                    functions.initialize(factsPointer, toolsPointer, nil)
                }
            }
            guard initResult >= 0 else {
                currentToolsetKey = nil
                lastFailureReason = "Needle couldn't take these tools: " + lastEngineError(functions)
                return nil
            }
            currentToolsetKey = toolsetKey
        } else {
            // Every ask stands alone; an old turn would only confuse it.
            functions.reset()
        }

        let outputCapacity = Int32(outputBuffer.count)
        let completeResult = text.withCString { textPointer in
            outputBuffer.withUnsafeMutableBufferPointer { outputPointer in
                functions.complete(textPointer, nil, 0, Int32(maximumNewTokens), outputPointer.baseAddress, outputCapacity)
            }
        }
        let outputText = outputBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard completeResult >= 0 else {
            lastFailureReason = "Needle failed: " + (outputText.isEmpty ? lastEngineError(functions) : outputText)
            return nil
        }
        guard let outputData = outputText.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
            lastFailureReason = "Needle's answer wasn't readable."
            return nil
        }

        let milliseconds = Date().timeIntervalSince(startTime) * 1000
        lastCallMilliseconds = milliseconds
        return Answer(
            toolCalls: Self.toolCalls(from: envelope["function_calls"]),
            withheldToolCalls: Self.toolCalls(from: envelope["suppressed_calls"]),
            confidence: (envelope["confidence"] as? NSNumber)?.doubleValue,
            reasoning: envelope["reasoning"] as? String ?? "",
            milliseconds: milliseconds
        )
    }

    private static func toolCalls(from rawCalls: Any?) -> [ToolCall] {
        guard let rawCallList = rawCalls as? [[String: Any]] else { return [] }
        return rawCallList.compactMap { rawCall in
            guard let callName = rawCall["name"] as? String else { return nil }
            var flattenedArguments: [String: String] = [:]
            for (argumentName, argumentValue) in rawCall["arguments"] as? [String: Any] ?? [:] {
                flattenedArguments[argumentName] = flattenedText(argumentValue)
            }
            return ToolCall(name: callName, arguments: flattenedArguments)
        }
    }

    private static func flattenedText(_ value: Any) -> String {
        if let stringValue = value as? String { return stringValue }
        if let numberValue = value as? NSNumber {
            // NSNumber hides booleans; CFBoolean is how to tell them apart.
            if CFGetTypeID(numberValue) == CFBooleanGetTypeID() { return numberValue.boolValue ? "true" : "false" }
            return numberValue.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let valueData = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(decoding: valueData, as: UTF8.self)
        }
        return "\(value)"
    }

    // MARK: Embeddings

    /// A unit-length vector for the text, for matching by meaning. Nil when
    /// Needle isn't available.
    func embedding(for text: String) -> [Float]? {
        guard Self.isEnabled, prepare(), let functions = engineFunctions else { return nil }
        let dimension = text.withCString { textPointer in
            functions.embed(textPointer, nil, 0, nil, 0)
        }
        guard dimension > 0 else { return nil }
        var vector = [Float](repeating: 0, count: Int(dimension))
        let writtenCount = text.withCString { textPointer in
            vector.withUnsafeMutableBufferPointer { vectorPointer in
                functions.embed(textPointer, nil, 0, vectorPointer.baseAddress, dimension)
            }
        }
        guard writtenCount == dimension else { return nil }
        let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard length > 0 else { return nil }
        return vector.map { $0 / length }
    }

    nonisolated static func similarity(_ firstVector: [Float], _ secondVector: [Float]) -> Float {
        guard firstVector.count == secondVector.count else { return 0 }
        var dotProduct: Float = 0
        for index in firstVector.indices {
            dotProduct += firstVector[index] * secondVector[index]
        }
        return dotProduct
    }

    // MARK: Speech (Whistle)

    /// Speech to text for 16 kHz mono samples in -1…1. `keywords` are names
    /// to favor (app names). Nil when Whistle isn't available.
    func transcribe(samples: [Float], keywords: [String], language: String? = "en") -> Transcript? {
        guard Self.isEnabled, prepare(), let functions = engineFunctions, let transcribeFunction = functions.transcribe else { return nil }
        if !isWhistleLoaded {
            guard !hasTriedLoadingWhistle, let whistleWeightsURL else { return nil }
            hasTriedLoadingWhistle = true
            guard loadWeights(at: whistleWeightsURL, using: functions) else { return nil }
            isWhistleLoaded = true
            // Whatever Needle had set up is gone once Whistle is loaded.
            currentToolsetKey = nil
        }
        guard !samples.isEmpty else { return nil }
        let startTime = Date()
        // About 4 KB of text per second of audio is the engine's own sizing.
        let neededCapacity = max(outputBuffer.count, samples.count / 16_000 * 4096 + 4096)
        if neededCapacity > outputBuffer.count {
            outputBuffer = [CChar](repeating: 0, count: neededCapacity)
        }
        let outputCapacity = Int32(outputBuffer.count)
        let keywordsText = keywords.joined(separator: "\n")
        let transcribeResult = samples.withUnsafeBufferPointer { samplesPointer in
            keywordsText.withCString { keywordsPointer in
                withOptionalCString(language) { languagePointer in
                    outputBuffer.withUnsafeMutableBufferPointer { outputPointer in
                        transcribeFunction(
                            samplesPointer.baseAddress, Int32(samples.count), languagePointer,
                            keywordsText.isEmpty ? nil : keywordsPointer, 0, outputPointer.baseAddress, outputCapacity
                        )
                    }
                }
            }
        }
        guard transcribeResult >= 0 else {
            lastFailureReason = "Whistle failed: " + lastEngineError(functions)
            return nil
        }
        let outputText = outputBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        guard let outputData = outputText.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] else { return nil }
        return Transcript(
            text: (envelope["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            language: envelope["language"] as? String ?? "",
            milliseconds: Date().timeIntervalSince(startTime) * 1000
        )
    }

    private func withOptionalCString<Result>(_ text: String?, _ body: (UnsafePointer<CChar>?) -> Result) -> Result {
        guard let text else { return body(nil) }
        return text.withCString { body($0) }
    }

    // MARK: Status

    /// One line for Settings and the self-check.
    func statusText() -> String {
        guard Self.isEnabled else { return "Off." }
        guard isBundled else { return "Not included in this build." }
        if engineFunctions != nil {
            if let lastCallMilliseconds {
                return "Ready (last answer in \(Int(lastCallMilliseconds.rounded())) ms)."
            }
            return "Ready."
        }
        if hasTriedLoading { return lastFailureReason ?? "Couldn't start." }
        return "Starts the first time it's needed."
    }
}
