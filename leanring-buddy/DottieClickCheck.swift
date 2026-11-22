//
//  DottieClickCheck.swift
//  leanring-buddy
//
//  Click checks: how far each screen-job click landed from where the model
//  pointed. Clicks were missing their target and nobody could tell why
//  (scaling, a swapped box, Jev, the Accessibility snap or a stale
//  screenshot). Each click now logs both points and the distance between
//  them, and keeps the screenshot with a red dot where the model's box
//  said and a green dot where Dottie really clicked, in
//  Application Support/Dottie/ClickChecks. Only the last 30 are kept, by
//  writing over the oldest slot, so nothing is ever deleted. The math is
//  pure, so it can be unit tested.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum DottieClickCheck {
    /// How many click pictures are kept before the oldest is written over.
    static let slotCount = 30

    /// What moved the click away from the model's own box center.
    enum FinalPointSource: String {
        case modelBox = "model box"
        case accessibilitySnap = "snapped to the control"
        case jev = "Jev's box"
    }

    /// Where a global AppKit point sits on the screenshot, in the image's
    /// own pixels from its top-left corner.
    static func imagePixel(forGlobalPoint globalPoint: CGPoint, displayFrame: CGRect, imageWidth: Int, imageHeight: Int) -> CGPoint {
        guard displayFrame.width > 0, displayFrame.height > 0 else { return .zero }
        let fractionAcross = (globalPoint.x - displayFrame.minX) / displayFrame.width
        let fractionDown = (displayFrame.maxY - globalPoint.y) / displayFrame.height
        return CGPoint(x: fractionAcross * CGFloat(imageWidth), y: fractionDown * CGFloat(imageHeight))
    }

    /// How far the final click is from the model's point, in screen points
    /// (right and down are positive, the way people read a screen).
    static func offset(fromModelPoint modelPoint: CGPoint, toFinalPoint finalPoint: CGPoint) -> (right: Double, down: Double, distance: Double) {
        let right = Double(finalPoint.x - modelPoint.x)
        let down = Double(modelPoint.y - finalPoint.y)
        return (right: right, down: down, distance: (right * right + down * down).squareRoot())
    }

    /// The log line for one click, numbers rounded to whole points.
    static func logText(stepNumber: Int, label: String, modelPoint: CGPoint, finalPoint: CGPoint, source: FinalPointSource, slot: Int) -> String {
        let moved = offset(fromModelPoint: modelPoint, toFinalPoint: finalPoint)
        return "🎯 click check step \(stepNumber) \"\(label.prefix(60))\": model (\(Int(modelPoint.x.rounded())), \(Int(modelPoint.y.rounded()))) → clicked (\(Int(finalPoint.x.rounded())), \(Int(finalPoint.y.rounded()))) by \(source.rawValue), moved \(Int(moved.right.rounded())) right \(Int(moved.down.rounded())) down (\(Int(moved.distance.rounded())) pt) · picture click-check-\(fileSlotText(slot)).jpg"
    }

    /// The slot after `lastSlot`, going round after `slotCount`.
    static func nextSlot(after lastSlot: Int?) -> Int {
        guard let lastSlot, lastSlot >= 0 else { return 0 }
        return (lastSlot + 1) % slotCount
    }

    static func fileName(forSlot slot: Int) -> String {
        "click-check-\(fileSlotText(slot)).jpg"
    }

    private static func fileSlotText(_ slot: Int) -> String {
        slot < 10 ? "0\(slot)" : "\(slot)"
    }

    // MARK: - Saving

    private static let lastSlotDefaultsKey = "dottieClickCheckLastSlot"

    /// Logs the click and saves its picture in the background, so the click
    /// itself never waits.
    static func record(stepNumber: Int, label: String, screenshot: CGImage, displayFrame: CGRect, modelPoint: CGPoint, finalPoint: CGPoint, source: FinalPointSource) {
        let defaults = UserDefaults.standard
        let lastSlot = defaults.object(forKey: lastSlotDefaultsKey) as? Int
        let slot = nextSlot(after: lastSlot)
        defaults.set(slot, forKey: lastSlotDefaultsKey)
        DottieLog.notice("\(public: logText(stepNumber: stepNumber, label: label, modelPoint: modelPoint, finalPoint: finalPoint, source: source, slot: slot))")

        let modelPixel = imagePixel(forGlobalPoint: modelPoint, displayFrame: displayFrame, imageWidth: screenshot.width, imageHeight: screenshot.height)
        let finalPixel = imagePixel(forGlobalPoint: finalPoint, displayFrame: displayFrame, imageWidth: screenshot.width, imageHeight: screenshot.height)
        Task.detached(priority: .utility) {
            savePicture(screenshot: screenshot, modelPixel: modelPixel, finalPixel: finalPixel, slot: slot)
        }
    }

    private static func savePicture(screenshot: CGImage, modelPixel: CGPoint, finalPixel: CGPoint, slot: Int) {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Dottie/ClickChecks", isDirectory: true) else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            DottieLog.warning("Couldn't make the click checks folder: \(error.localizedDescription)")
            return
        }
        let width = screenshot.width
        let height = screenshot.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(screenshot, in: CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext's origin is bottom-left; the pixels above are top-left.
        func drawDot(at pixel: CGPoint, red: CGFloat, green: CGFloat) {
            let center = CGPoint(x: pixel.x, y: CGFloat(height) - pixel.y)
            let radius = max(5, CGFloat(max(width, height)) / 250)
            context.setFillColor(red: red, green: green, blue: 0, alpha: 0.85)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.setLineWidth(max(1.5, radius / 4))
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        drawDot(at: modelPixel, red: 1, green: 0)
        drawDot(at: finalPixel, red: 0, green: 0.8)
        guard let markedImage = context.makeImage() else { return }
        let fileURL = folder.appendingPathComponent(fileName(forSlot: slot))
        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, markedImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        if !CGImageDestinationFinalize(destination) {
            DottieLog.warning("Couldn't save a click check picture")
        }
    }
}
