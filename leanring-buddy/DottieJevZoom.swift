//
//  DottieJevZoom.swift
//  leanring-buddy
//
//  Zoom and refine for Jev's boxes. Jev sees the whole screen squeezed to
//  1568 pixels, so a small icon is a handful of pixels and its box can be
//  off by the icon's own width. When the box is small, Dottie cuts a
//  close-up around it from a full-resolution capture, asks Jev again on the
//  close-up, and maps the sharper box back. A close-up answer far from the
//  first box (Jev found a different thing) is thrown away. Pure, so it can
//  be unit tested.
//

import CoreGraphics
import Foundation

enum DottieJevZoom {
    /// Boxes narrower or shorter than this (fractions of the screen) get a close-up.
    static let smallBoxWidthFraction = 0.06
    static let smallBoxHeightFraction = 0.05
    /// The close-up is this many times the box, and at least this many pixels a side.
    static let closeUpBoxMultiple = 5.0
    static let minimumCloseUpSide = 480

    /// Whether a box is small enough that a close-up makes the click sharper.
    static func needsCloseUp(_ box: DottieJevBox) -> Bool {
        (box.right - box.left) < smallBoxWidthFraction || (box.bottom - box.top) < smallBoxHeightFraction
    }

    /// The close-up to cut out of a full-resolution picture, in its pixels
    /// (top-left origin), centered on the box and kept inside the picture,
    /// or nil when the picture is too small for Jev to read a close-up.
    static func closeUpRect(around box: DottieJevBox, imageWidth: Int, imageHeight: Int) -> CGRect? {
        guard min(imageWidth, imageHeight) >= DottieJevProtocol.minimumImageSide else { return nil }
        let boxWidthPixels = (box.right - box.left) * Double(imageWidth)
        let boxHeightPixels = (box.bottom - box.top) * Double(imageHeight)
        let side = Double(max(minimumCloseUpSide, Int(max(boxWidthPixels, boxHeightPixels) * closeUpBoxMultiple)))
        let closeUpWidth = min(side, Double(imageWidth))
        let closeUpHeight = min(side, Double(imageHeight))
        let centerX = (box.left + box.right) / 2 * Double(imageWidth)
        let centerY = (box.top + box.bottom) / 2 * Double(imageHeight)
        let left = min(max(centerX - closeUpWidth / 2, 0), Double(imageWidth) - closeUpWidth)
        let top = min(max(centerY - closeUpHeight / 2, 0), Double(imageHeight) - closeUpHeight)
        return CGRect(x: left.rounded(), y: top.rounded(), width: closeUpWidth.rounded(), height: closeUpHeight.rounded())
    }

    /// A box Jev drew on the close-up, as a box on the whole picture.
    static func wholePictureBox(fromCloseUpBox closeUpBox: DottieJevBox, closeUpRect: CGRect, imageWidth: Int, imageHeight: Int) -> DottieJevBox {
        let width = Double(imageWidth)
        let height = Double(imageHeight)
        return DottieJevBox(
            top: (Double(closeUpRect.minY) + closeUpBox.top * Double(closeUpRect.height)) / height,
            bottom: (Double(closeUpRect.minY) + closeUpBox.bottom * Double(closeUpRect.height)) / height,
            left: (Double(closeUpRect.minX) + closeUpBox.left * Double(closeUpRect.width)) / width,
            right: (Double(closeUpRect.minX) + closeUpBox.right * Double(closeUpRect.width)) / width,
            confidence: closeUpBox.confidence
        )
    }

    /// How far (a fraction of the screen) the close-up's box may move at least.
    static let minimumSameTargetMargin = 0.02

    /// Whether the close-up's box is still the same thing: its middle sits
    /// inside the first box grown by its own size (at least 2% of the
    /// screen) on every side.
    static func isSameTarget(refinedBox: DottieJevBox, firstBox: DottieJevBox) -> Bool {
        let firstWidth = max(firstBox.right - firstBox.left, minimumSameTargetMargin)
        let firstHeight = max(firstBox.bottom - firstBox.top, minimumSameTargetMargin)
        let refinedCenterX = (refinedBox.left + refinedBox.right) / 2
        let refinedCenterY = (refinedBox.top + refinedBox.bottom) / 2
        return refinedCenterX >= firstBox.left - firstWidth && refinedCenterX <= firstBox.right + firstWidth
            && refinedCenterY >= firstBox.top - firstHeight && refinedCenterY <= firstBox.bottom + firstHeight
    }
}
