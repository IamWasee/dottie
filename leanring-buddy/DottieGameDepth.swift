//
//  DottieGameDepth.swift
//  leanring-buddy
//
//  How far away things are in one game frame, on the Mac. Uses Apple's
//  Core ML build of Depth Anything V2 Small (Apache-2.0, about 50 MB),
//  downloaded from Hugging Face the first time a game is played and
//  compiled once into Application Support/Dottie/Models/. It's small
//  enough to keep Dottie inside her memory budget on an 8 GB Mac.
//
//  The model gives relative depth (near is high, far is low) for one
//  picture at a time, so DottieGameWorldMap turns it into distances with
//  its own scale. When the model can't be downloaded, the map still keeps
//  keyframes and places, just without 3D points.
//

import Accelerate
import CoreML
import CoreVideo
import Foundation
import Vision

/// Relative depth sampled on a small grid, row 0 at the top of the frame.
/// Values are 0…1, higher is nearer.
struct DottieDepthMap {
    let columnCount: Int
    let rowCount: Int
    let nearness: [Float]

    func nearness(column: Int, row: Int) -> Float {
        nearness[row * columnCount + column]
    }
}

@MainActor
final class DottieGameDepth {
    static let shared = DottieGameDepth()

    nonisolated private static let modelRepository = "apple/coreml-depth-anything-v2-small"
    nonisolated private static let compiledModelName = "DepthAnythingV2Small.mlmodelc"
    nonisolated static let sampleColumnCount = 64
    nonisolated static let sampleRowCount = 40

    private var estimator: DottieDepthEstimator?
    private var loadingTask: Task<DottieDepthEstimator?, Never>?
    private var isEstimating = false
    /// After a failed download, wait before trying again.
    private var nextLoadAttemptAt: Date?

    nonisolated private static var modelsFolderURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dottie/Models", isDirectory: true)
    }

    /// How the depth model is doing, for the map's report.
    var statusText: String {
        if estimator != nil { return "loaded and working" }
        if loadingTask != nil { return "loading (downloading on the first run, about 50 MB)" }
        if nextLoadAttemptAt != nil { return "couldn't be downloaded or loaded; trying again every 10 minutes, so the map has spots but no 3D shapes" }
        return "not started"
    }

    /// Starts loading (and on the first run, downloading) the model in the
    /// background, so it's ready by the time mapping needs it.
    func prepare() {
        _ = startLoadingIfNeeded()
    }

    /// The depth of one frame, or nil when the model isn't ready yet or a
    /// frame is already being worked on (mapping skips that frame).
    func depthMap(of frame: CGImage) async -> DottieDepthMap? {
        guard !isEstimating else { return nil }
        // Never wait for a download in the middle of play: frames before
        // the model is ready just get no 3D points.
        guard let readyEstimator = estimator else {
            prepare()
            return nil
        }
        isEstimating = true
        defer { isEstimating = false }
        let sampledDepth = await Task.detached(priority: .utility) {
            readyEstimator.estimate(frame: frame)
        }.value
        guard let sampledDepth else { return nil }
        return DottieDepthMap(columnCount: sampledDepth.columnCount, rowCount: sampledDepth.rowCount, nearness: sampledDepth.nearness)
    }

    private func startLoadingIfNeeded() -> Task<DottieDepthEstimator?, Never>? {
        if let estimator {
            return Task { () -> DottieDepthEstimator? in estimator }
        }
        if let loadingTask {
            return loadingTask
        }
        if let nextLoadAttemptAt, nextLoadAttemptAt > Date() {
            return nil
        }
        let newLoadingTask = Task { @MainActor [weak self] () -> DottieDepthEstimator? in
            let loadedEstimator = await Self.loadEstimator()
            guard let self else { return loadedEstimator }
            self.loadingTask = nil
            if let loadedEstimator {
                self.estimator = loadedEstimator
            } else {
                self.nextLoadAttemptAt = Date().addingTimeInterval(600)
            }
            return loadedEstimator
        }
        loadingTask = newLoadingTask
        return newLoadingTask
    }

    // MARK: - Loading

    nonisolated private static func loadEstimator() async -> DottieDepthEstimator? {
        let compiledModelURL = modelsFolderURL.appendingPathComponent(compiledModelName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: compiledModelURL.path) {
            guard await downloadAndCompileModel(to: compiledModelURL) else { return nil }
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let model = try MLModel(contentsOf: compiledModelURL, configuration: configuration)
            let visionModel = try VNCoreMLModel(for: model)
            return DottieDepthEstimator(visionModel: visionModel)
        } catch {
            print("⚠️ Game depth: couldn't load the depth model: \(error)")
            // A broken compile is removed so the next try starts clean.
            try? FileManager.default.removeItem(at: compiledModelURL)
            return nil
        }
    }

    /// Fetches the model package file by file (Hugging Face lists them),
    /// compiles it, and keeps only the compiled model.
    nonisolated private static func downloadAndCompileModel(to compiledModelURL: URL) async -> Bool {
        guard let listingURL = URL(string: "https://huggingface.co/api/models/\(modelRepository)") else { return false }
        do {
            let (listingData, _) = try await URLSession.shared.data(from: listingURL)
            guard let listing = try JSONSerialization.jsonObject(with: listingData) as? [String: Any],
                  let siblings = listing["siblings"] as? [[String: Any]] else { return false }
            let filePaths = siblings.compactMap { $0["rfilename"] as? String }
            let packageNames = Set(filePaths.compactMap { filePath -> String? in
                let firstComponent = filePath.split(separator: "/").first.map(String.init) ?? ""
                return firstComponent.hasSuffix(".mlpackage") ? firstComponent : nil
            })
            // Half precision is half the size and just as good for this.
            guard let packageName = packageNames.sorted().first(where: { $0.contains("F16") && !$0.contains("P6") })
                    ?? packageNames.sorted().first else { return false }

            let downloadFolderURL = modelsFolderURL.appendingPathComponent("download", isDirectory: true)
            try? FileManager.default.removeItem(at: downloadFolderURL)
            for filePath in filePaths where filePath.hasPrefix(packageName + "/") {
                guard let fileURL = URL(string: "https://huggingface.co/\(modelRepository)/resolve/main/\(filePath)") else { continue }
                let (temporaryFileURL, response) = try await URLSession.shared.download(from: fileURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
                let destinationURL = downloadFolderURL.appendingPathComponent(filePath)
                try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destinationURL)
                try FileManager.default.moveItem(at: temporaryFileURL, to: destinationURL)
            }

            let packageURL = downloadFolderURL.appendingPathComponent(packageName, isDirectory: true)
            let temporaryCompiledURL = try await MLModel.compileModel(at: packageURL)
            try FileManager.default.createDirectory(at: modelsFolderURL, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: compiledModelURL)
            try FileManager.default.moveItem(at: temporaryCompiledURL, to: compiledModelURL)
            try? FileManager.default.removeItem(at: downloadFolderURL)
            return true
        } catch {
            print("⚠️ Game depth: couldn't download the depth model: \(error)")
            return false
        }
    }
}

/// Runs the depth model on one frame. Only touched by one frame at a time
/// (DottieGameDepth.isEstimating), off the main thread.
final class DottieDepthEstimator: @unchecked Sendable {
    nonisolated(unsafe) private let visionModel: VNCoreMLModel

    nonisolated init(visionModel: VNCoreMLModel) {
        self.visionModel = visionModel
    }

    /// The depth sampled on DottieGameDepth's small grid, 0…1, near high.
    nonisolated func estimate(frame: CGImage) -> (columnCount: Int, rowCount: Int, nearness: [Float])? {
        let depthRequest = VNCoreMLRequest(model: visionModel)
        depthRequest.imageCropAndScaleOption = .scaleFill
        let requestHandler = VNImageRequestHandler(cgImage: frame, options: [:])
        do {
            try requestHandler.perform([depthRequest])
        } catch {
            return nil
        }
        let rawValues: (values: [Float], width: Int, height: Int)?
        if let pixelBufferObservation = depthRequest.results?.first as? VNPixelBufferObservation {
            rawValues = Self.floatValues(of: pixelBufferObservation.pixelBuffer)
        } else if let featureObservation = depthRequest.results?.first as? VNCoreMLFeatureValueObservation,
                  let multiArray = featureObservation.featureValue.multiArrayValue {
            rawValues = Self.floatValues(of: multiArray)
        } else {
            rawValues = nil
        }
        guard let rawValues, rawValues.width > 1, rawValues.height > 1 else { return nil }
        return Self.sampledAndNormalized(rawValues.values, width: rawValues.width, height: rawValues.height)
    }

    /// Picks a small grid of values and scales them to 0…1.
    nonisolated private static func sampledAndNormalized(_ values: [Float], width: Int, height: Int) -> (columnCount: Int, rowCount: Int, nearness: [Float])? {
        let columnCount = DottieGameDepth.sampleColumnCount
        let rowCount = DottieGameDepth.sampleRowCount
        var sampledValues = [Float](repeating: 0, count: columnCount * rowCount)
        for row in 0..<rowCount {
            let sourceRow = min(height - 1, Int((Double(row) + 0.5) / Double(rowCount) * Double(height)))
            for column in 0..<columnCount {
                let sourceColumn = min(width - 1, Int((Double(column) + 0.5) / Double(columnCount) * Double(width)))
                sampledValues[row * columnCount + column] = values[sourceRow * width + sourceColumn]
            }
        }
        guard let minimumValue = sampledValues.min(), let maximumValue = sampledValues.max(),
              maximumValue - minimumValue > 0.0001, minimumValue.isFinite, maximumValue.isFinite else { return nil }
        let valueRange = maximumValue - minimumValue
        let normalizedValues = sampledValues.map { ($0 - minimumValue) / valueRange }
        return (columnCount, rowCount, normalizedValues)
    }

    nonisolated private static func floatValues(of pixelBuffer: CVPixelBuffer) -> (values: [Float], width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var values = [Float](repeating: 0, count: width * height)
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DisparityFloat32:
            for row in 0..<height {
                let rowPointer = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: Float.self)
                for column in 0..<width {
                    values[row * width + column] = rowPointer[column]
                }
            }
        case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16:
            // Half floats are converted with Accelerate, which works on
            // Intel Macs too (Swift's Float16 doesn't exist there).
            values.withUnsafeMutableBufferPointer { valueBuffer in
                guard let valueBaseAddress = valueBuffer.baseAddress else { return }
                var sourceBuffer = vImage_Buffer(data: baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
                var destinationBuffer = vImage_Buffer(data: valueBaseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
                vImageConvert_Planar16FtoPlanarF(&sourceBuffer, &destinationBuffer, vImage_Flags(kvImageNoFlags))
            }
        case kCVPixelFormatType_OneComponent8:
            for row in 0..<height {
                let rowPointer = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for column in 0..<width {
                    values[row * width + column] = Float(rowPointer[column]) / 255
                }
            }
        default:
            return nil
        }
        return (values, width, height)
    }

    nonisolated private static func floatValues(of multiArray: MLMultiArray) -> (values: [Float], width: Int, height: Int)? {
        let shape = multiArray.shape.map(\.intValue)
        guard shape.count >= 2 else { return nil }
        let height = shape[shape.count - 2]
        let width = shape[shape.count - 1]
        guard width > 0, height > 0, multiArray.count >= width * height else { return nil }
        // The last width × height values are the depth plane.
        let firstIndex = multiArray.count - width * height
        var values = [Float](repeating: 0, count: width * height)
        for valueIndex in 0..<(width * height) {
            values[valueIndex] = multiArray[firstIndex + valueIndex].floatValue
        }
        return (values, width, height)
    }
}
