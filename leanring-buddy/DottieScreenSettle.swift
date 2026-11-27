//
//  DottieScreenSettle.swift
//  leanring-buddy
//
//  When a screen job's next look can happen, and when a move Jev picked
//  is too old to make. Wasee's tests (27 Nov) found Jev too fast for the
//  pages: it pressed space and C before a YouTube video had loaded, and on
//  Wikipedia a click picked on one page landed after the page had changed.
//  A page counts as settled once the browser says it finished loading (when
//  it says) and two looks in a row show the same screen; a click is dropped
//  when the spot it aims at changed between Jev's screenshot and the click.
//  Foundation only, so it can be unit tested.
//

import CoreGraphics
import Foundation

enum DottieScreenSettle {
    /// What the browser in front says about its page, read through
    /// Accessibility (AXLoaded / AXLoadingProgress on the web area).
    enum PageLoad: Equatable {
        case loaded
        case loading
        /// No browser in front, or it didn't say.
        case unknown
    }

    /// Looks in a row that must match before the screen counts as settled
    /// when nothing says the page loaded. One match let a blank page that
    /// hadn't started drawing pass.
    static let matchingLooksNeeded = 2
    /// When the browser says its page loaded, one matching look is enough:
    /// the second look cost every move about half a second (Wasee, 28 Nov:
    /// "it got way too slow").
    static let matchingLooksNeededOnALoadedPage = 1
    /// How long after a move the first look waits, and between looks.
    static let firstLookDelaySeconds = 0.25
    static let secondsBetweenLooks = 0.2
    /// Extra time given while the browser still says it's loading.
    static let extraSecondsWhilePageLoads = 6.0
    /// A click aimed at a spot that changed is dropped at most this many
    /// times in a row, so a screen that never stops moving still gets clicks.
    static let maximumStaleMovesDroppedInARow = 2
    /// The square around a click's target compared before clicking, as a
    /// share of the screen's width.
    static let targetRegionShareOfWidth = 0.08
    /// Side of the small grey picture each target region is shrunk to.
    static let targetRegionSide = 16
    /// Mean grey difference (0-255) above which the target region changed.
    /// Whole-screen checks use 4; a small region needs a clearer change so
    /// a blinking caret or a hover tint doesn't drop a good click.
    static let targetRegionChangeThreshold = 12.0

    static func pageLoad(loadedAttribute: Bool?, loadingProgress: Double?) -> PageLoad {
        if let loadingProgress, loadingProgress < 0.999 { return .loading }
        if let loadedAttribute { return loadedAttribute ? .loaded : .loading }
        if loadingProgress != nil { return .loaded }
        return .unknown
    }

    static func isSettled(matchingLooksInARow: Int, pageLoad: PageLoad) -> Bool {
        switch pageLoad {
        case .loading: return false
        case .loaded: return matchingLooksInARow >= matchingLooksNeededOnALoadedPage
        case .unknown: return matchingLooksInARow >= matchingLooksNeeded
        }
    }

    /// A screen that never stops moving (a playing video) used to make
    /// every move wait the whole time; ordinary moves now wait 1.5 s at most.
    static func maximumWaitSeconds(opensSomethingNew: Bool, pageLoad: PageLoad) -> Double {
        let baseSeconds = opensSomethingNew ? 5.0 : 1.5
        return pageLoad == .loading ? baseSeconds + extraSecondsWhilePageLoads : baseSeconds
    }

    /// The square around a target (0-1 of the screen), in the pixels of an
    /// image that size, kept inside the image.
    static func targetRegion(centerX: Double, centerY: Double, imageWidth: Int, imageHeight: Int) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return .zero }
        let side = max(8.0, (Double(imageWidth) * targetRegionShareOfWidth).rounded())
        let clampedSide = min(side, Double(min(imageWidth, imageHeight)))
        let originX = min(max(0, centerX * Double(imageWidth) - clampedSide / 2), Double(imageWidth) - clampedSide)
        let originY = min(max(0, centerY * Double(imageHeight) - clampedSide / 2), Double(imageHeight) - clampedSide)
        return CGRect(x: originX, y: originY, width: clampedSide, height: clampedSide)
    }

    /// Whether the region around a click's target looks different now from
    /// the screenshot Jev picked the click on. Pictures of different sizes,
    /// or none, count as unchanged: the click goes ahead as before.
    static func targetRegionChanged(pickedOn: [UInt8], now: [UInt8]) -> Bool {
        guard !pickedOn.isEmpty, pickedOn.count == now.count else { return false }
        var totalDifference = 0
        for index in pickedOn.indices {
            totalDifference += abs(Int(pickedOn[index]) - Int(now[index]))
        }
        return Double(totalDifference) / Double(pickedOn.count) > targetRegionChangeThreshold
    }

    static func shouldDropStaleMove(targetRegionChanged: Bool, staleMovesDroppedInARow: Int) -> Bool {
        targetRegionChanged && staleMovesDroppedInARow < maximumStaleMovesDroppedInARow
    }
}
