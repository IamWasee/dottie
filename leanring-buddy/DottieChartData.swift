//
//  DottieChartData.swift
//  leanring-buddy
//
//  The numbers for a chart Dottie draws while teaching: "Mon: 12; Tue: 9",
//  "1, 3; 2, 5", or rows read from a table the user circled.
//

import AppKit
import Foundation
import Vision

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
