//
//  ScreenJobPointerTests.swift
//  leanring-buddyTests
//
//  Jev hovering and the pointer during a screen job: which "point the mouse
//  at" moves are offered, what they say and how they're struck off, hover
//  steps kept in named tasks and done again, the glide from a hover menu to
//  its item, putting the pointer back when the job ends (not when the user
//  moved it), and a hover-then-click journey through a site's top menu.
//

import CoreGraphics
import Foundation
import Testing
@testable import Dottie

@MainActor
struct ScreenJobPointerTests {
    private typealias Plan = DottieJevDriverPlan
    private typealias PointerPlan = DottieScreenJobPointerPlan

    private let siteTopMenu = [
        Plan.ScreenText(text: "Products", centerX: 200, centerY: 60),
        Plan.ScreenText(text: "Pricing", centerX: 320, centerY: 60),
        Plan.ScreenText(text: "A long sentence in the page header", centerX: 600, centerY: 90),
        Plan.ScreenText(text: "Welcome to our store", centerX: 500, centerY: 500)
    ]

    // MARK: Which hover moves are offered

    @Test func shortTextsAlongTheTopGetHoverMoves() {
        let moves = Plan.hoverMoves(screenTexts: siteTopMenu, screenControls: [], taskText: "open the store's pricing page")
        #expect(moves.contains(.hover(label: "Products", centerX: 200, centerY: 60)))
        #expect(moves.contains(.hover(label: "Pricing", centerX: 320, centerY: 60)))
        // A long header sentence isn't a menu, and the page's middle isn't the top.
        #expect(!moves.contains(.hover(label: "A long sentence in the page header", centerX: 600, centerY: 90)))
        #expect(!moves.contains(.hover(label: "Welcome to our store", centerX: 500, centerY: 500)))
    }

    @Test func textsTheRequestTalksAboutGetHoverMovesAnywhere() {
        let screenTexts = [Plan.ScreenText(text: "Account settings", centerX: 800, centerY: 700)]
        let moves = Plan.hoverMoves(screenTexts: screenTexts, screenControls: [], taskText: "open account settings")
        #expect(moves == [.hover(label: "Account settings", centerX: 800, centerY: 700)])
    }

    @Test func menuButtonsGetHoverMoves() {
        let menuButton = Plan.ScreenControl(label: "More options", kind: "menu", centerX: 900, centerY: 400)
        let plainButton = Plan.ScreenControl(label: "Save", kind: "button", centerX: 100, centerY: 400)
        let moves = Plan.hoverMoves(screenTexts: [], screenControls: [menuButton, plainButton], taskText: "x")
        #expect(moves == [.hover(label: "More options", centerX: 900, centerY: 400)])
    }

    @Test func askingToHoverOffersTheScreensTextsUpToTheCap() {
        #expect(Plan.asksToHover("hover over the profile picture"))
        #expect(Plan.asksToHover("open the dropdown under Tools"))
        #expect(Plan.asksToHover("pick Export from the file menu"))
        #expect(!Plan.asksToHover("open youtube and search cats"))
        let manyTexts = (0..<60).map { Plan.ScreenText(text: "Item \($0) here", centerX: 100, centerY: 300 + Double($0)) }
        let hoverRequestMoves = Plan.hoverMoves(screenTexts: manyTexts, screenControls: [], taskText: "hover over each item")
        #expect(hoverRequestMoves.count == Plan.maximumHoverTargets)
        let otherRequestMoves = Plan.hoverMoves(screenTexts: manyTexts, screenControls: [], taskText: "open the settings")
        #expect(otherRequestMoves.isEmpty)
    }

    @Test func topMenuHoversStayFew() {
        let topRow = (0..<30).map { Plan.ScreenText(text: "Tab \($0)", centerX: Double($0) * 30, centerY: 40) }
        let moves = Plan.hoverMoves(screenTexts: topRow, screenControls: [], taskText: "open the settings")
        #expect(moves.count == Plan.maximumTopMenuHoverTargets)
    }

    @Test func hoverMovesAreInJevsOptionsAndStruckOffOnTheirOwn() {
        let options = Plan.options(screenTexts: siteTopMenu, textPieces: [], siteAddresses: [], appNames: [],
                                   alreadyTriedSignatures: [Plan.Move.click(label: "Products", centerX: 0, centerY: 0).signature],
                                   taskText: "open pricing")
        let moves = options.map(\.move)
        // Clicking Products was tried; pointing at it is a different move.
        #expect(!moves.contains(.click(label: "Products", centerX: 200, centerY: 60)))
        #expect(moves.contains(.hover(label: "Products", centerX: 200, centerY: 60)))
        #expect(Set(options.map(\.key)).count == options.count)
        #expect(options.count <= Plan.maximumOptions)
        let triedHover: Set<String> = [Plan.Move.hover(label: "products", centerX: 1, centerY: 1).signature]
        let afterHover = Plan.options(screenTexts: siteTopMenu, textPieces: [], siteAddresses: [], appNames: [],
                                      alreadyTriedSignatures: triedHover, taskText: "open pricing").map(\.move)
        #expect(!afterHover.contains(.hover(label: "Products", centerX: 200, centerY: 60)))
        #expect(afterHover.contains(.click(label: "Products", centerX: 200, centerY: 60)))
    }

    @Test func aHoverMoveReadsAndBehavesLikePointing() {
        let move = Plan.Move.hover(label: "Products", centerX: 200, centerY: 60)
        #expect(move.description.contains("without clicking"))
        #expect(move.summary == "pointed the mouse at Products")
        #expect(move.signature == "hover:products")
        #expect(!move.opensSomethingNew)
        #expect(move.aimedPoint?.centerX == 200)
        #expect(move.aimedPoint?.centerY == 60)
        // Pointing presses nothing, so it needs no extra-sure pick.
        #expect(!Plan.movesNeedingClearPick(move))
    }

    // MARK: Hover steps in named tasks

    @Test func aHoverIsKeptAsAStepAndDoneAgainWhereTheMenuIsNow() {
        let step = DottieAppTaskPlan.step(from: .hover(label: "Products", centerX: 200, centerY: 60), pageTitle: "Store", requestText: "open pricing")
        #expect(step?.kind == .hover)
        #expect(DottieAppTaskPlan.stepLine(step!) == "point the mouse at \"Products\"")
        let screenTexts = [Plan.ScreenText(text: "Products", centerX: 210, centerY: 64)]
        let replayStep = DottieAppTaskPlan.replayStep(step!, recordedForRequest: "open pricing", newRequest: "open pricing",
                                                      screenTexts: screenTexts, screenControls: [], frontSiteHost: nil, frontAppName: nil)
        #expect(replayStep == .move(.hover(label: "Products", centerX: 210, centerY: 64)))
        #expect(DottieAppTaskPathReplay.jevMoveIsTheStep(.hover(label: "Products", centerX: 210, centerY: 64), step: step!, requestText: "open pricing"))
        #expect(!DottieAppTaskPathReplay.jevMoveIsTheStep(.click(label: "Products", centerX: 210, centerY: 64), step: step!, requestText: "open pricing"))
    }

    @Test func pointingAtARiskyButtonIsNotRisky() {
        let step = DottieAppTaskPlan.step(from: .hover(label: "Delete", centerX: 300, centerY: 300), pageTitle: "Sheet", requestText: "show the row tools")!
        let screenTexts = [Plan.ScreenText(text: "Delete", centerX: 300, centerY: 300)]
        #expect(DottieAppTaskPlan.replayStep(step, recordedForRequest: "show the row tools", newRequest: "show the row tools",
                                             screenTexts: screenTexts, screenControls: [], frontSiteHost: nil, frontAppName: nil)
                == .move(.hover(label: "Delete", centerX: 300, centerY: 300)))
    }

    @Test func aHoverNotOnScreenSaysSo() {
        let step = DottieAppTaskPlan.step(from: .hover(label: "Products", centerX: 200, centerY: 60), pageTitle: "Store", requestText: "x")!
        #expect(DottieAppTaskPlan.replayStep(step, recordedForRequest: "x", newRequest: "x", screenTexts: [], screenControls: [],
                                             frontSiteHost: nil, frontAppName: nil) == .notOnScreen)
    }

    // MARK: The glide and putting the pointer back

    @Test func aGlideEndsExactlyOnTheItemAndTakesMoreStepsForLongerTrips() {
        let start = CGPoint(x: 100, y: 100)
        let end = CGPoint(x: 400, y: 260)
        let path = PointerPlan.glidePath(from: start, to: end)
        #expect(path.last == end)
        #expect(path.count == PointerPlan.glideStepCount(from: start, to: end))
        // Every point lies between the two ends, so the pointer never leaves the way.
        #expect(path.allSatisfy { $0.x >= start.x && $0.x <= end.x && $0.y >= start.y && $0.y <= end.y })
        #expect(PointerPlan.glideStepCount(from: start, to: CGPoint(x: 101, y: 100)) == 4)
        #expect(PointerPlan.glideStepCount(from: start, to: CGPoint(x: 3000, y: 2000)) == 16)
        #expect(PointerPlan.glidePath(from: start, to: start) == Array(repeating: start, count: 4))
    }

    @Test func thePointerGoesBackOnlyWhenTheJobLeftItWhereItIs() {
        let home = CGPoint(x: 50, y: 50)
        let jobSpot = CGPoint(x: 700, y: 400)
        // The job moved it and it's still there: back home.
        #expect(PointerPlan.shouldPutPointerBack(currentPoint: jobSpot, lastPointPlacedByJob: jobSpot, homePoint: home))
        #expect(PointerPlan.shouldPutPointerBack(currentPoint: CGPoint(x: 703, y: 402), lastPointPlacedByJob: jobSpot, homePoint: home))
        // The user took the mouse meanwhile: left where they put it.
        #expect(!PointerPlan.shouldPutPointerBack(currentPoint: CGPoint(x: 900, y: 100), lastPointPlacedByJob: jobSpot, homePoint: home))
        // The job never moved it, or it's already home.
        #expect(!PointerPlan.shouldPutPointerBack(currentPoint: home, lastPointPlacedByJob: nil, homePoint: home))
        #expect(!PointerPlan.shouldPutPointerBack(currentPoint: home, lastPointPlacedByJob: home, homePoint: home))
    }

    @Test func outsideAJobNothingIsHeldAndAnOldJobCantEndANewOne() {
        let firstJob = DottieScreenJobPointer.beginJob()
        #expect(DottieScreenJobPointer.keepsPointerWhereItActs)
        DottieScreenJobPointer.notePlaced(CGPoint(x: -10_000, y: -10_000), isHover: true)
        #expect(DottieScreenJobPointer.restsOnHoverSpot)
        let secondJob = DottieScreenJobPointer.beginJob()
        #expect(!DottieScreenJobPointer.restsOnHoverSpot)
        // The first job finishing late leaves the second job's pointer alone.
        DottieScreenJobPointer.endJob(firstJob)
        #expect(DottieScreenJobPointer.keepsPointerWhereItActs)
        DottieScreenJobPointer.endJob(secondJob)
        #expect(!DottieScreenJobPointer.keepsPointerWhereItActs)
        // Outside a job, nothing is noted.
        DottieScreenJobPointer.notePlaced(CGPoint(x: 1, y: 1), isHover: true)
        #expect(!DottieScreenJobPointer.restsOnHoverSpot)
    }

    // MARK: Journey

    /// "Open the store's pricing page" on a site whose Pricing link only
    /// shows in the Products menu: Jev points at Products, the menu opens,
    /// Jev clicks Pricing (the pointer glides there), and the task is kept
    /// with the hover so the next time does both from memory.
    @Test func hoverMenuJourneyFromFirstJobToReplay() {
        let request = "open the store's pricing page"
        let firstScreen = [Plan.ScreenText(text: "Products", centerX: 200, centerY: 60), Plan.ScreenText(text: "Welcome", centerX: 500, centerY: 500)]
        let firstMoves = Plan.options(screenTexts: firstScreen, textPieces: [], siteAddresses: [], appNames: [], alreadyTriedSignatures: [], taskText: request).map(\.move)
        let hover = Plan.Move.hover(label: "Products", centerX: 200, centerY: 60)
        #expect(firstMoves.contains(hover))

        let menuOpenScreen = firstScreen + [Plan.ScreenText(text: "Pricing", centerX: 220, centerY: 120)]
        let secondMoves = Plan.options(screenTexts: menuOpenScreen, textPieces: [], siteAddresses: [], appNames: [], alreadyTriedSignatures: [], taskText: request).map(\.move)
        let clickPricing = Plan.Move.click(label: "Pricing", centerX: 220, centerY: 120)
        #expect(secondMoves.contains(clickPricing))

        // The pointer glides from the hover spot onto the menu item.
        let glide = PointerPlan.glidePath(from: CGPoint(x: 200, y: 60), to: CGPoint(x: 220, y: 120))
        #expect(glide.last == CGPoint(x: 220, y: 120))

        var recording = DottieAppTaskRecording()
        for move in [hover, clickPricing] {
            if let step = DottieAppTaskPlan.step(from: move, pageTitle: "Store", requestText: request) {
                recording.note(step, placeKey: "store.example", placeName: "store.example", bundleIdentifier: "com.apple.Safari")
            }
        }
        let task = DottieAppTaskPlan.taskAfterSuccess(nil, request: request, recording: recording, pathProblem: nil, now: Date())
        #expect(task?.steps.map(\.kind) == [.hover, .click])
        let replayFirst = DottieAppTaskPlan.replayStep(task!.steps[0], recordedForRequest: request, newRequest: request,
                                                       screenTexts: firstScreen, screenControls: [], frontSiteHost: "store.example", frontAppName: "Safari")
        #expect(replayFirst == .move(hover))
        let replaySecond = DottieAppTaskPlan.replayStep(task!.steps[1], recordedForRequest: request, newRequest: request,
                                                        screenTexts: menuOpenScreen, screenControls: [], frontSiteHost: "store.example", frontAppName: "Safari")
        #expect(replaySecond == .move(clickPricing))
    }
}
