//
//  DottieCursorPet.swift
//  leanring-buddy
//
//  Dottie's cursor can shapeshift: "turn into a cat" swaps the arrow for a
//  cat (any emoji works, and any SF Symbol, so the library is every emoji and
//  thousands of symbols with nothing to download). With roaming on, the shape
//  stops following the mouse and lives on the screen like a pet: it walks
//  along the tops of windows, jumps from window to window and down to the
//  Dock, rides a window that's being dragged, and now and then hangs from the
//  frontmost app's search bar.
//
//  The pet pauses while the user talks to Dottie or she points at something
//  (the shape comes to the mouse like the normal cursor), and drops back down
//  from wherever it is when that's over.
//
//  Positions are global AppKit points (origin bottom left, y up).
//

import AppKit
import ApplicationServices
import Combine
import Foundation

@MainActor
final class DottieCursorPet: ObservableObject {
    struct Costume: Codable, Equatable {
        var name: String
        var emoji: String?
        var symbol: String?
        var roams: Bool
        /// An asset-catalog image (the shapes unlocked by levelling up),
        /// drawn instead of an emoji or symbol.
        var artwork: String? = nil
    }

    /// The shape the cursor has, or nil for the normal arrow.
    @Published private(set) var costume: Costume?

    /// Where the pet's middle is drawn (global AppKit point).
    @Published private(set) var center: CGPoint = .zero
    @Published private(set) var facingRight = false
    /// Tilt in degrees: the swing while hanging, a lean in the air.
    @Published private(set) var rotationDegrees: Double = 0
    /// Little hop of each step while walking, in points.
    @Published private(set) var bobHeight: CGFloat = 0
    @Published private(set) var isHanging = false

    /// True while the pet is out roaming and not paused; the cursor overlay
    /// draws it at `center` instead of following the mouse.
    @Published private(set) var isRoamingNow = false

    /// Set by CompanionManager: true while the pet should come to the mouse
    /// (the user is talking, Dottie is pointing or doing a screen job).
    var shouldPause: () -> Bool = { false }

    static let size: CGFloat = 30

    private static let defaultsKey = "dottieCursorCostume"

    private struct Platform {
        var minX: CGFloat
        var maxX: CGFloat
        var y: CGFloat
        var windowNumber: Int?
    }

    private enum Activity {
        case sitting(until: Date)
        case walking(toX: CGFloat)
        case jumping(from: CGPoint, to: CGPoint, peakY: CGFloat, startedAt: Date, duration: Double, then: AfterJump)
        case hanging(until: Date)
    }

    private enum AfterJump {
        case sit
        case hang
    }

    /// Where the feet are (or, hanging, where the paws hold on).
    private var feet: CGPoint = .zero
    private var activity: Activity = .sitting(until: .distantPast)
    private var platform: Platform?
    private var walkPhase: Double = 0
    private var frameTimer: Timer?
    private var lastFrameAt = Date()
    private var lastPlatformCheckAt = Date.distantPast
    private var wasPaused = true

    init() {
        if let savedData = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let savedCostume = try? JSONDecoder().decode(Costume.self, from: savedData) {
            costume = savedCostume
        }
    }

    /// Starts the pet if the saved shape roams (called once at launch).
    func start() {
        updateFrameTimer()
    }

    // MARK: - Changing shape

    func setCostume(_ newCostume: Costume?) {
        costume = newCostume
        if let newCostume, let data = try? JSONEncoder().encode(newCostume) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
        wasPaused = true   // drop in fresh from the mouse
        updateFrameTimer()
    }

    func setRoaming(_ roams: Bool) {
        guard var currentCostume = costume else { return }
        currentCostume.roams = roams
        setCostume(currentCostume)
    }

    /// Shapes with a name, for "turn into a cat" and the picker in Settings.
    /// Anything else can be any emoji or SF Symbol.
    struct Shape: Hashable {
        let name: String
        let emoji: String
    }

    static let library: [Shape] = libraryPairs.map { Shape(name: $0.0, emoji: $0.1) }

    private static let libraryPairs: [(String, String)] = [
        ("cat", "🐈"), ("black cat", "🐈‍⬛"), ("kitten", "🐱"), ("dog", "🐕"), ("puppy", "🐶"), ("fox", "🦊"),
        ("rabbit", "🐇"), ("bunny", "🐰"), ("mouse", "🐁"), ("hamster", "🐹"), ("hedgehog", "🦔"), ("squirrel", "🐿️"),
        ("bear", "🐻"), ("panda", "🐼"), ("koala", "🐨"), ("monkey", "🐒"), ("tiger", "🐅"), ("lion", "🦁"),
        ("horse", "🐎"), ("unicorn", "🦄"), ("cow", "🐄"), ("pig", "🐖"), ("sheep", "🐑"), ("goat", "🐐"),
        ("chicken", "🐓"), ("chick", "🐥"), ("duck", "🦆"), ("penguin", "🐧"), ("bird", "🐦"), ("parrot", "🦜"),
        ("owl", "🦉"), ("eagle", "🦅"), ("flamingo", "🦩"), ("frog", "🐸"), ("turtle", "🐢"), ("snake", "🐍"),
        ("lizard", "🦎"), ("dinosaur", "🦖"), ("t-rex", "🦖"), ("dragon", "🐉"), ("fish", "🐟"), ("shark", "🦈"),
        ("whale", "🐋"), ("dolphin", "🐬"), ("octopus", "🐙"), ("crab", "🦀"), ("snail", "🐌"), ("butterfly", "🦋"),
        ("bee", "🐝"), ("ladybug", "🐞"), ("ant", "🐜"), ("spider", "🕷️"), ("sloth", "🦥"), ("otter", "🦦"),
        ("ghost", "👻"), ("alien", "👽"), ("robot", "🤖"), ("skull", "💀"), ("clown", "🤡"), ("poop", "💩"),
        ("rocket", "🚀"), ("ufo", "🛸"), ("plane", "✈️"), ("car", "🚗"), ("race car", "🏎️"), ("bike", "🚲"),
        ("star", "⭐️"), ("heart", "❤️"), ("fire", "🔥"), ("rainbow", "🌈"), ("sun", "☀️"), ("moon", "🌙"),
        ("cloud", "☁️"), ("snowman", "⛄️"), ("pumpkin", "🎃"), ("christmas tree", "🎄"), ("balloon", "🎈"), ("gift", "🎁"),
        ("pizza", "🍕"), ("burger", "🍔"), ("donut", "🍩"), ("cookie", "🍪"), ("ice cream", "🍦"), ("avocado", "🥑"),
        ("banana", "🍌"), ("apple", "🍎"), ("coffee", "☕️"), ("crown", "👑"), ("diamond", "💎"), ("sword", "🗡️"),
        ("magic wand", "🪄"), ("crystal ball", "🔮"), ("ninja", "🥷"), ("wizard", "🧙"), ("fairy", "🧚"), ("mermaid", "🧜‍♀️"),
        ("zombie", "🧟"), ("vampire", "🧛"), ("soccer ball", "⚽️"), ("basketball", "🏀"), ("game controller", "🎮"), ("guitar", "🎸")
    ]

    /// Living things walk; objects float and hop.
    static func defaultRoaming(forName name: String) -> Bool {
        let walkerNames: Set<String> = [
            "cat", "black cat", "kitten", "dog", "puppy", "fox", "rabbit", "bunny", "mouse", "hamster", "hedgehog",
            "squirrel", "bear", "panda", "koala", "monkey", "tiger", "lion", "horse", "unicorn", "cow", "pig", "sheep",
            "goat", "chicken", "chick", "duck", "penguin", "frog", "turtle", "snake", "lizard", "dinosaur", "t-rex",
            "snail", "ant", "spider", "sloth", "otter", "robot", "ninja", "zombie"
        ]
        return walkerNames.contains(name.lowercased())
    }

    // MARK: - The voice tool

    static let functionName = "change_cursor"

    nonisolated static var functionDeclaration: [String: Any] {
        [
            "name": functionName,
            "description": "Change how your cursor looks: turn into a cat, a ghost, a rocket, anything with an emoji or an SF Symbol, or back to the normal arrow. With roam on, the shape walks around the screen on its own like a pet (along windows, jumping between them, hanging from the search bar) instead of following the mouse. Use it when the user asks you to turn into something, change your look, or walk around; animals roam unless the user says otherwise.",
            "parameters": [
                "type": "OBJECT",
                "properties": [
                    "shape": ["type": "STRING", "description": "What to turn into, like 'cat' or 'ghost'; 'normal' for the usual arrow."],
                    "emoji": ["type": "STRING", "description": "The one emoji that looks like it, like 🐈. Leave out for a normal arrow."],
                    "symbol": ["type": "STRING", "description": "Instead of an emoji: an SF Symbol name, like 'pawprint.fill'."],
                    "roam": ["type": "BOOLEAN", "description": "true: walk around the screen on its own. false: follow the mouse."]
                ],
                "required": ["shape"]
            ]
        ]
    }

    func perform(arguments: [String: Any]) -> String {
        let shapeName = ((arguments["shape"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalNames: Set<String> = ["", "normal", "arrow", "default", "cursor", "yourself", "back", "dottie"]
        if normalNames.contains(shapeName) {
            setCostume(nil)
            return "back to the normal arrow."
        }
        // Special shapes unlock as Dottie levels up (DottieLevels).
        if let specialShape = DottieLevels.unlockableShape(named: shapeName), case .shape(let specialArtworkName) = specialShape.kind {
            let levels = DottieLevels.shared
            guard levels.isUnlocked(specialShape) else {
                return "\(shapeName) is a special shape that unlocks at level \(specialShape.level); you're level \(levels.level). tease them that you have to earn it together."
            }
            let roams = (arguments["roam"] as? Bool) ?? false
            setCostume(Costume(name: shapeName, emoji: nil, symbol: nil, roams: roams, artwork: specialArtworkName))
            return "you're the \(shapeName) now, a special shape you unlocked. show off a little."
        }
        var emoji = (arguments["emoji"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var symbol = (arguments["symbol"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidateSymbol = symbol, NSImage(systemSymbolName: candidateSymbol, accessibilityDescription: nil) == nil {
            symbol = nil
        }
        if let knownEmoji = Self.library.first(where: { $0.name == shapeName })?.emoji {
            emoji = knownEmoji
        } else if emoji?.isEmpty != false, let looseMatch = Self.library.first(where: { shapeName.contains($0.name) }) {
            emoji = looseMatch.emoji
        }
        if let chosenEmoji = emoji, chosenEmoji.isEmpty || chosenEmoji.unicodeScalars.allSatisfy({ !$0.properties.isEmoji }) {
            emoji = nil
        }
        guard emoji != nil || symbol != nil else {
            return "couldn't find a shape for \(shapeName). give an emoji (or an SF Symbol name) for it."
        }
        let roams = (arguments["roam"] as? Bool) ?? Self.defaultRoaming(forName: shapeName)
        setCostume(Costume(name: shapeName, emoji: symbol == nil ? emoji : nil, symbol: symbol, roams: roams))
        return roams
            ? "you're a \(shapeName) now, wandering around the screen. say so in a playful way."
            : "you're a \(shapeName) now, following the mouse."
    }

    // MARK: - The frame loop

    private func updateFrameTimer() {
        let roams = costume?.roams == true
        if roams && frameTimer == nil {
            lastFrameAt = Date()
            frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step() }
            }
        } else if !roams {
            frameTimer?.invalidate()
            frameTimer = nil
            isRoamingNow = false
            isHanging = false
            rotationDegrees = 0
            bobHeight = 0
        }
    }

    private func step() {
        let now = Date()
        let elapsed = min(now.timeIntervalSince(lastFrameAt), 0.1)
        lastFrameAt = now

        if shouldPause() {
            if isRoamingNow { isRoamingNow = false }
            wasPaused = true
            return
        }
        if wasPaused {
            wasPaused = false
            // Come back from the mouse: drop down onto whatever is below.
            let mouseLocation = NSEvent.mouseLocation
            feet = CGPoint(x: mouseLocation.x + 35, y: mouseLocation.y - 25)
            isHanging = false
            dropToPlatformBelow()
            isRoamingNow = true
        }

        if now.timeIntervalSince(lastPlatformCheckAt) > 0.4 {
            lastPlatformCheckAt = now
            keepStandingOnPlatform()
        }

        switch activity {
        case .sitting(let until):
            bobHeight = 0
            rotationDegrees = 0
            if now >= until { chooseNextActivity() }

        case .walking(let targetX):
            let walkSpeed: CGFloat = 80
            let remaining = targetX - feet.x
            let stride = walkSpeed * CGFloat(elapsed)
            if abs(remaining) <= stride {
                feet.x = targetX
                bobHeight = 0
                activity = .sitting(until: now.addingTimeInterval(Double.random(in: 1.2...4)))
            } else {
                feet.x += remaining > 0 ? stride : -stride
                facingRight = remaining > 0
                walkPhase += elapsed * 9
                bobHeight = CGFloat(abs(sin(walkPhase))) * 3
                rotationDegrees = sin(walkPhase) * 4
            }

        case .jumping(let from, let to, let peakY, let startedAt, let duration, let then):
            let progress = min(now.timeIntervalSince(startedAt) / duration, 1)
            let t = CGFloat(progress)
            feet.x = from.x + (to.x - from.x) * t
            // A parabola through from, the peak and to.
            let baseY = from.y + (to.y - from.y) * t
            let lift = peakY - (from.y + to.y) / 2
            feet.y = baseY + 4 * lift * t * (1 - t)
            bobHeight = 0
            rotationDegrees = (to.x > from.x ? -1 : 1) * 12 * sin(Double(t) * .pi)
            if progress >= 1 {
                feet = to
                rotationDegrees = 0
                switch then {
                case .sit:
                    activity = .sitting(until: now.addingTimeInterval(Double.random(in: 1.5...5)))
                case .hang:
                    isHanging = true
                    activity = .hanging(until: now.addingTimeInterval(Double.random(in: 4...9)))
                }
            }

        case .hanging(let until):
            walkPhase += elapsed * 2.2
            rotationDegrees = sin(walkPhase) * 14
            if now >= until {
                isHanging = false
                platform = nil
                dropToPlatformBelow()
            }
        }

        let newCenter = isHanging
            ? CGPoint(x: feet.x, y: feet.y - Self.size / 2)
            : CGPoint(x: feet.x, y: feet.y + Self.size / 2)
        if newCenter != center { center = newCenter }
    }

    // MARK: - Deciding what to do

    private func chooseNextActivity() {
        let platforms = Self.currentPlatforms()
        let roll = Double.random(in: 0..<1)

        if roll < 0.1, let searchBar = Self.frontmostSearchBarFrame() {
            // Go hang from the search bar's bottom edge, near its right end.
            let holdPoint = CGPoint(x: searchBar.maxX - min(30, searchBar.width / 4), y: searchBar.minY)
            jump(to: holdPoint, then: .hang)
            platform = nil
            return
        }
        if roll < 0.45, let currentPlatform = platform, currentPlatform.maxX - currentPlatform.minX > 80 {
            let margin: CGFloat = 16
            var targetX = CGFloat.random(in: (currentPlatform.minX + margin)...(currentPlatform.maxX - margin))
            if abs(targetX - feet.x) < 40 { targetX = feet.x < (currentPlatform.minX + currentPlatform.maxX) / 2 ? currentPlatform.maxX - margin : currentPlatform.minX + margin }
            activity = .walking(toX: targetX)
            return
        }
        if roll < 0.8 {
            // Jump to another window that's not too far away.
            let candidates = platforms.filter { candidate in
                guard abs(candidate.y - feet.y) > 6 || candidate.windowNumber != platform?.windowNumber else { return false }
                let nearestX = min(max(feet.x, candidate.minX + 16), candidate.maxX - 16)
                return hypot(nearestX - feet.x, candidate.y - feet.y) < 700
            }
            if let destination = candidates.randomElement() {
                let landingX = min(max(feet.x + CGFloat.random(in: -150...150), destination.minX + 16), destination.maxX - 16)
                platform = destination
                jump(to: CGPoint(x: landingX, y: destination.y), then: .sit)
                return
            }
        }
        activity = .sitting(until: Date().addingTimeInterval(Double.random(in: 1.5...4)))
    }

    private func jump(to destination: CGPoint, then: AfterJump) {
        let distance = hypot(destination.x - feet.x, destination.y - feet.y)
        let duration = min(max(0.45 + Double(distance) / 1600, 0.45), 1.0)
        let peakY = max(feet.y, destination.y) + max(30, min(140, distance * 0.25))
        facingRight = destination.x > feet.x
        activity = .jumping(from: feet, to: destination, peakY: peakY, startedAt: Date(), duration: duration, then: then)
    }

    /// Hop down onto the highest thing below the pet.
    private func dropToPlatformBelow() {
        let landing = platformBelow(feet, in: Self.currentPlatforms())
        platform = landing
        let landingX = min(max(feet.x, landing.minX + 16), landing.maxX - 16)
        let distance = hypot(landingX - feet.x, landing.y - feet.y)
        let duration = min(max(0.3 + Double(distance) / 2200, 0.3), 0.8)
        activity = .jumping(from: feet, to: CGPoint(x: landingX, y: landing.y), peakY: max(feet.y, landing.y) + 12,
                            startedAt: Date(), duration: duration, then: .sit)
    }

    /// Windows move, close and get dragged: ride along, or fall when the
    /// window under the pet is gone.
    private func keepStandingOnPlatform() {
        switch activity {
        case .jumping, .hanging:
            return
        case .sitting, .walking:
            break
        }
        let platforms = Self.currentPlatforms()
        if let sameWindow = platforms.first(where: { candidate in
            candidate.windowNumber != nil && candidate.windowNumber == platform?.windowNumber
                && feet.x >= candidate.minX - 4 && feet.x <= candidate.maxX + 4
        }) {
            feet.y = sameWindow.y
            platform = sameWindow
        } else if let underFeet = platforms.first(where: { abs($0.y - feet.y) < 3 && feet.x >= $0.minX - 4 && feet.x <= $0.maxX + 4 }) {
            platform = underFeet
        } else {
            dropToPlatformBelow()
        }
    }

    private func platformBelow(_ point: CGPoint, in platforms: [Platform]) -> Platform {
        let below = platforms
            .filter { point.x >= $0.minX && point.x <= $0.maxX && $0.y <= point.y + 2 }
            .max { $0.y < $1.y }
        if let below { return below }
        let screen = NSScreen.screens.first { $0.frame.minX <= point.x && point.x <= $0.frame.maxX } ?? NSScreen.main ?? NSScreen.screens[0]
        return Platform(minX: screen.visibleFrame.minX, maxX: screen.visibleFrame.maxX, y: screen.visibleFrame.minY, windowNumber: nil)
    }

    // MARK: - What's on screen

    /// The visible top edges of normal windows, plus each screen's floor
    /// (just above the Dock).
    private static func currentPlatforms() -> [Platform] {
        var platforms: [Platform] = NSScreen.screens.map { screen in
            Platform(minX: screen.visibleFrame.minX, maxX: screen.visibleFrame.maxX, y: screen.visibleFrame.minY, windowNumber: nil)
        }
        guard let primaryScreen = NSScreen.screens.first,
              let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return platforms
        }
        let primaryHeight = primaryScreen.frame.height
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        // Front to back; each window's top edge is hidden where a window in
        // front of it covers it.
        var frontWindowFrames: [CGRect] = []
        for windowInfo in windowInfoList {
            guard (windowInfo[kCGWindowLayer as String] as? Int) == 0,
                  (windowInfo[kCGWindowOwnerPID as String] as? Int32) != ownProcessID,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let quartzBounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  quartzBounds.width > 160, quartzBounds.height > 100 else { continue }
            if let alpha = windowInfo[kCGWindowAlpha as String] as? Double, alpha < 0.1 { continue }
            let frame = CGRect(x: quartzBounds.minX, y: primaryHeight - quartzBounds.maxY, width: quartzBounds.width, height: quartzBounds.height)
            defer { frontWindowFrames.append(frame) }
            let topY = frame.maxY
            // Windows filling the screen have their top under the menu bar.
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }),
                  topY < screen.visibleFrame.maxY - Self.size else { continue }
            var visibleSpans: [(CGFloat, CGFloat)] = [(frame.minX, frame.maxX)]
            for frontFrame in frontWindowFrames where frontFrame.minY < topY + Self.size && frontFrame.maxY > topY {
                visibleSpans = visibleSpans.flatMap { span -> [(CGFloat, CGFloat)] in
                    guard frontFrame.maxX > span.0, frontFrame.minX < span.1 else { return [span] }
                    var pieces: [(CGFloat, CGFloat)] = []
                    if frontFrame.minX > span.0 { pieces.append((span.0, frontFrame.minX)) }
                    if frontFrame.maxX < span.1 { pieces.append((frontFrame.maxX, span.1)) }
                    return pieces
                }
            }
            let windowNumber = windowInfo[kCGWindowNumber as String] as? Int
            for span in visibleSpans where span.1 - span.0 >= 60 {
                platforms.append(Platform(minX: span.0, maxX: span.1, y: topY, windowNumber: windowNumber))
            }
        }
        return platforms
    }

    /// The frontmost app's search field or address bar, in AppKit points.
    private static func frontmostSearchBarFrame() -> CGRect? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let primaryScreen = NSScreen.screens.first else { return nil }
        let applicationElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.2)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindowValue, CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else { return nil }

        var queue: [(element: AXUIElement, depth: Int)] = [(focusedWindowValue as! AXUIElement, 0)]
        var visitedCount = 0
        while !queue.isEmpty && visitedCount < 500 {
            let (element, depth) = queue.removeFirst()
            visitedCount += 1
            let role = stringAttribute(kAXRoleAttribute, of: element)
            let subrole = stringAttribute(kAXSubroleAttribute, of: element)
            let description = (stringAttribute(kAXDescriptionAttribute, of: element) ?? "").lowercased()
            let isSearchBar = subrole == "AXSearchField"
                || (role == "AXTextField" && (description.contains("search") || description.contains("address")))
                || (role == "AXComboBox" && description.contains("search"))
            if isSearchBar, let frame = frameOf(element), frame.width > 80 {
                return CGRect(x: frame.minX, y: primaryScreen.frame.height - frame.maxY, width: frame.width, height: frame.height)
            }
            guard depth < 9 else { continue }
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                for child in children.prefix(60) {
                    queue.append((element: child, depth: depth + 1))
                }
            }
        }
        return nil
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// The element's frame in Quartz points (origin top left).
    private static func frameOf(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
