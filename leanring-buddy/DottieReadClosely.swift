//
//  DottieReadClosely.swift
//  leanring-buddy
//
//  read_closely: reads one part of the screen from a full-resolution
//  close-up instead of Live's small frame. Live sees every screen squeezed
//  into one picture, so on a Retina Mac small print and exponents are a few
//  pixels tall and a 3 reads as a 2, a + as a −. This finds the part the
//  user means, cuts it out of a sharp screenshot, and has a vision model
//  copy it exactly, math included.
//

import AppKit
import Foundation

enum DottieReadClosely {
    /// Reads the described part (or the whole active screen) and returns
    /// its exact text, or nil when nothing could be read.
    @MainActor
    static func read(partDescription: String) async -> String? {
        // The notes board shouldn't cover what's being read.
        let notesBoardWasShowing = DottieNotesBoard.shared.isShowing
        if notesBoardWasShowing { DottieNotesBoard.shared.close() }
        defer { if notesBoardWasShowing { DottieNotesBoard.shared.show() } }
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Native Retina pixels: a 3420 px wide screen keeps all of them.
        guard let screenshot = await DottieDisplayCapture.captureActiveDisplay(maximumDimension: 4096) else { return nil }
        var closeUp = screenshot.image

        if !partDescription.isEmpty {
            let foundFrames = await DottieTeaching.locateAnchors(
                [DottieTeaching.Anchor(name: "part", description: partDescription)],
                displayFrame: screenshot.displayFrame,
                userQuestion: partDescription
            )
            if let partFrame = foundFrames["part"],
               let croppedImage = crop(screenshot: screenshot, to: partFrame) {
                closeUp = croppedImage
            }
        }

        guard let closeUpJPEGData = NSBitmapImageRep(cgImage: enlargedIfSmall(closeUp))
            .representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { return nil }

        let prompt = """
        Copy out exactly what this close-up of the user's screen says\(partDescription.isEmpty ? "" : " (they mean: \(partDescription))"), so it can be explained without misreading it.
        Keep question numbers, part letters and marks. Write math in plain text with ^(…) for powers and _(…) for subscripts, keeping every bracket, sign and digit exactly as printed: a^(3x+1), 5/(3a^(1-x))^(-2), 3(3^(4t+2) + 1) = 82 × 9^t.
        Look twice at small superscripts: 3 versus 2, + versus −, 1 versus l or 7. Don't solve or explain anything. Reply with only the copied text.
        """
        let requestBody: [String: Any] = [
            "model": DottieModelPicker.shared.pick(.normal),
            "contents": [[
                "role": "user",
                "parts": [
                    ["inlineData": ["mimeType": "image/jpeg", "data": closeUpJPEGData.base64EncodedString()]],
                    ["text": prompt]
                ]
            ]]
        ]
        guard let copiedText = await DottieChat.send(requestBody, timeout: 45), !copiedText.isEmpty else { return nil }
        return copiedText
    }

    /// Global AppKit points (bottom-left origin) → screenshot pixels
    /// (top-left origin), with room around the part so nothing at its edge
    /// is cut off.
    private static func crop(screenshot: DottieDisplayCapture.Screenshot, to partFrame: CGRect) -> CGImage? {
        let paddedFrame = partFrame.insetBy(dx: -24, dy: -24).intersection(screenshot.displayFrame)
        guard !paddedFrame.isEmpty else { return nil }
        let pixelsPerPoint = CGFloat(screenshot.image.width) / screenshot.displayFrame.width
        let pixelRect = CGRect(
            x: (paddedFrame.minX - screenshot.displayFrame.minX) * pixelsPerPoint,
            y: (screenshot.displayFrame.maxY - paddedFrame.maxY) * pixelsPerPoint,
            width: paddedFrame.width * pixelsPerPoint,
            height: paddedFrame.height * pixelsPerPoint
        ).integral
        return screenshot.image.cropping(to: pixelRect)
    }

    /// A small crop is drawn bigger (up to 2×) so the model's own resizing
    /// doesn't shrink tiny exponents further.
    private static func enlargedIfSmall(_ image: CGImage) -> CGImage {
        let longestSide = CGFloat(max(image.width, image.height))
        let scale = min(2, 1600 / max(longestSide, 1))
        guard scale > 1.1 else { return image }
        let enlargedWidth = Int(CGFloat(image.width) * scale)
        let enlargedHeight = Int(CGFloat(image.height) * scale)
        guard let context = CGContext(
            data: nil, width: enlargedWidth, height: enlargedHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: enlargedWidth, height: enlargedHeight))
        return context.makeImage() ?? image
    }
}

enum DottieReadCloselyTools: DottieToolModule {
    static let functionName = "read_closely"

    static var tools: [DottieTool] {
        [
            DottieTool(
                name: functionName,
                description: "Read one part of the screen from a sharp, full-resolution close-up and get its exact text back. The picture you see is shrunk, so small print, exponents, subscripts, signs and digits in it are easy to misread (3x+1 can look like 2x−1). Call it before explaining, solving or writing out any math, science, exam or homework question, formula, code, or small text you'd otherwise read off the frame. Say a few words first (\"let me read that properly\"). Work from the text it returns, not from the frame. When you go on to write the working, start by writing the question as it reads, so the user can catch a misread.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "what": ["type": "STRING", "description": "The part to read, described so it can be found on screen, like \"question 4 part (i)\" or \"the equation under the graph\". Leave empty for the whole screen."]
                    ]
                ],
                run: { arguments in
                    let partDescription = (arguments["what"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard let copiedText = await DottieReadClosely.read(partDescription: partDescription) else {
                        return "Couldn't get a close-up read just now. Tell the user briefly, and if you go on from the frame, say what you read so they can check it."
                    }
                    return "Exact text from a full-resolution close-up (trust this over the frame):\n\(copiedText)"
                }
            )
        ]
    }

    static var voicePromptSection: String {
        "reading math or small print: before explaining or solving anything with exponents, fractions, formulas, signs or small text on screen, call read_closely on that part and work from what it returns; the frame you see is shrunk and small digits and signs get misread."
    }
}
