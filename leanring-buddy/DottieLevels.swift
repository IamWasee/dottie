//
//  DottieLevels.swift
//  leanring-buddy
//
//  Dottie levels up. Finished screen jobs, helper tasks, guides, games won
//  and days in a row earn XP; each level has a fun name and can unlock a
//  special cursor shape or a notch effect. A level-up shows a card with
//  confetti in the notch. Home → Profile shows it all.
//
//  Saved in UserDefaults ("dottieLevelsState"). Everything happens on the
//  Mac; nothing here calls Gemini.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class DottieLevels: ObservableObject {
    static let shared = DottieLevels()

    enum Event: String, Codable {
        case screenJob, helperTask, guide, gameWon, gamePoints, streakDay

        var baseXP: Int {
            switch self {
            case .screenJob: return 15
            case .helperTask: return 10
            case .guide: return 20
            case .gameWon: return 30
            case .gamePoints: return 3
            case .streakDay: return 10
            }
        }

        var label: String {
            switch self {
            case .screenJob: return "screen job"
            case .helperTask: return "helper task"
            case .guide: return "guide"
            case .gameWon: return "game won"
            case .gamePoints: return "game points"
            case .streakDay: return "day streak"
            }
        }
    }

    /// Something a level unlocks.
    struct Unlockable: Identifiable, Hashable {
        enum Kind: Hashable {
            /// A cursor shape, drawn from this asset-catalog image.
            case shape(artworkName: String)
            case notchEffect(DottieNotchEffect)
        }

        let name: String
        let level: Int
        let kind: Kind

        var id: String { name }

        /// The asset-catalog image shown for it in Home → Profile.
        var artworkName: String {
            switch kind {
            case .shape(let artworkName): return artworkName
            case .notchEffect(let effect): return effect.artworkName
            }
        }

        var kindLabel: String {
            switch kind {
            case .shape: return "cursor shape"
            case .notchEffect: return "notch effect"
            }
        }
    }

    struct Celebration: Equatable {
        let id = UUID()
        let level: Int
        let title: String
        let line: String
        let unlocked: [String]
        let date = Date()
    }

    private struct SavedState: Codable {
        var totalXP = 0
        var streakDays = 0
        var bestStreakDays = 0
        var lastActiveDay: String?
        var counts: [String: Int] = [:]
        var notchEffect: String?
    }

    @Published private(set) var totalXP = 0
    @Published private(set) var streakDays = 0
    @Published private(set) var bestStreakDays = 0
    @Published private(set) var counts: [String: Int] = [:]
    @Published private(set) var celebration: Celebration?
    @Published private(set) var notchEffect: DottieNotchEffect = .off

    private static let defaultsKey = "dottieLevelsState"
    private var lastActiveDay: String?
    /// Helper turns already counted, so the same finish isn't counted twice
    /// when it's reported from two places.
    private var recentHelperFinishes: [UUID: Date] = [:]
    private var helperFinishedObserver: NSObjectProtocol?

    private init() {
        load()
        // The helpers post this when one finishes a task.
        helperFinishedObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("dottie.helperFinished"), object: nil, queue: .main
        ) { notification in
            let agentID = (notification.userInfo?["agentID"] as? UUID)
                ?? (notification.userInfo?["agentID"] as? String).flatMap(UUID.init(uuidString:))
            let succeeded = (notification.userInfo?["succeeded"] as? Bool) ?? true
            MainActor.assumeIsolated {
                DottieLevels.shared.noteHelperFinished(agentID: agentID, succeeded: succeeded)
            }
        }
    }

    // MARK: - Levels

    static let unlockables: [Unlockable] = [
        Unlockable(name: "sparkle dot", level: 2, kind: .shape(artworkName: "UnlockSparkleDot")),
        Unlockable(name: "disco ball", level: 3, kind: .shape(artworkName: "UnlockDiscoBall")),
        Unlockable(name: "sparkles", level: 3, kind: .notchEffect(.sparkles)),
        Unlockable(name: "comet", level: 4, kind: .shape(artworkName: "UnlockComet")),
        Unlockable(name: "rainbow glow", level: 5, kind: .notchEffect(.rainbow)),
        Unlockable(name: "galaxy", level: 6, kind: .shape(artworkName: "UnlockGalaxy")),
        Unlockable(name: "trophy", level: 7, kind: .shape(artworkName: "UnlockTrophy")),
        Unlockable(name: "dragon king", level: 8, kind: .shape(artworkName: "UnlockDragonKing")),
        Unlockable(name: "shooting star", level: 9, kind: .shape(artworkName: "UnlockShootingStar")),
        Unlockable(name: "aurora", level: 9, kind: .notchEffect(.aurora)),
        Unlockable(name: "ringed planet", level: 10, kind: .shape(artworkName: "UnlockRingedPlanet"))
    ]

    private static let levelNames = [
        "Fresh Pixel", "Curious Dot", "Busy Bee", "Cursor Cadet", "Shortcut Sorcerer",
        "Tab Tamer", "Pixel Wizard", "Notch Ninja", "Desktop Dragon", "Legendary Dot"
    ]

    private static let levelUpLines = [
        "I'd do a little dance, but I'm a dot.",
        "Look at us go. I'm basically famous now.",
        "Glow-up complete. Try not to be jealous.",
        "Ding! That's the sound of me getting cooler.",
        "Okay, I'm officially a big deal now.",
        "New level. Same tiny dot. Way more swagger.",
        "I'm framing this one."
    ]

    /// Total XP needed to reach a level (level 1 starts at 0).
    static func xpNeeded(forLevel level: Int) -> Int {
        let steps = max(level - 1, 0)
        return 60 * steps * (steps + 1) / 2
    }

    static func level(forXP xp: Int) -> Int {
        var level = 1
        while xpNeeded(forLevel: level + 1) <= xp { level += 1 }
        return level
    }

    static func name(forLevel level: Int) -> String {
        level <= levelNames.count ? levelNames[max(level, 1) - 1] : "Cosmic Dot"
    }

    var level: Int { Self.level(forXP: totalXP) }
    var levelName: String { Self.name(forLevel: level) }

    /// 0…1 through the current level.
    var progressToNextLevel: Double {
        let start = Self.xpNeeded(forLevel: level)
        let end = Self.xpNeeded(forLevel: level + 1)
        return end > start ? Double(totalXP - start) / Double(end - start) : 1
    }

    var xpToNextLevel: Int { Self.xpNeeded(forLevel: level + 1) - totalXP }

    func isUnlocked(_ unlockable: Unlockable) -> Bool { level >= unlockable.level }

    /// The special shape with this name, if it's one of the unlockables.
    static func unlockableShape(named name: String) -> Unlockable? {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return unlockables.first { unlockable in
            if case .shape = unlockable.kind { return unlockable.name == lowered }
            return false
        }
    }

    // MARK: - Earning XP

    /// Adds XP for something Dottie did. `points` scales gamePoints.
    func award(_ event: Event, points: Int = 1) {
        noteActivityToday()
        let earned = event.baseXP * max(points, 1)
        counts[event.rawValue, default: 0] += event == .gamePoints ? max(points, 1) : 1
        addXP(earned)
    }

    /// A helper finished a task. Reported by CompanionManager and by the
    /// helpers' notification; each finish counts once.
    func noteHelperFinished(agentID: UUID?, succeeded: Bool) {
        guard succeeded else { return }
        let now = Date()
        recentHelperFinishes = recentHelperFinishes.filter { now.timeIntervalSince($0.value) < 10 }
        if let agentID {
            if recentHelperFinishes[agentID] != nil { return }
            recentHelperFinishes[agentID] = now
        }
        award(.helperTask)
    }

    private func addXP(_ earned: Int) {
        let levelBefore = level
        totalXP += earned
        save()
        let levelAfter = level
        guard levelAfter > levelBefore else { return }
        let unlocked = Self.unlockables.filter { $0.level > levelBefore && $0.level <= levelAfter }
        celebration = Celebration(
            level: levelAfter,
            title: "Level \(levelAfter) · \(Self.name(forLevel: levelAfter))",
            line: Self.levelUpLines.randomElement() ?? "Level up!",
            unlocked: unlocked.map(\.name)
        )
    }

    /// Days in a row: the first thing Dottie does on a new day keeps (or
    /// starts) the streak.
    private func noteActivityToday() {
        let today = Self.dayString(Date())
        guard lastActiveDay != today else { return }
        let yesterday = Self.dayString(Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        streakDays = lastActiveDay == yesterday ? streakDays + 1 : 1
        bestStreakDays = max(bestStreakDays, streakDays)
        lastActiveDay = today
        counts[Event.streakDay.rawValue, default: 0] += 1
        totalXP += Event.streakDay.baseXP * min(streakDays, 7)
        save()
    }

    private static func dayString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    // MARK: - Wearing unlocks

    func setNotchEffect(_ effect: DottieNotchEffect) {
        if let unlockable = Self.unlockables.first(where: { $0.kind == .notchEffect(effect) }), !isUnlocked(unlockable) { return }
        notchEffect = effect
        save()
    }

    /// Puts on an unlocked shape or notch effect by name. Returns a line
    /// for Dottie to say.
    func wear(_ name: String, cursorPet: DottieCursorPet) -> String {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["none", "off", "no effect", "plain"].contains(lowered) {
            setNotchEffect(.off)
            return "notch effect off."
        }
        guard let unlockable = Self.unlockables.first(where: { $0.name == lowered })
                ?? Self.unlockables.first(where: { lowered.contains($0.name) || $0.name.contains(lowered) }) else {
            return "there's no unlockable called \(name). unlockables: " + Self.unlockables.map(\.name).joined(separator: ", ")
        }
        guard isUnlocked(unlockable) else {
            return "\(unlockable.name) unlocks at level \(unlockable.level); you're level \(level). tease them that they'll have to earn it."
        }
        switch unlockable.kind {
        case .shape(let artworkName):
            cursorPet.setCostume(DottieCursorPet.Costume(name: unlockable.name, emoji: nil, symbol: nil, roams: false, artwork: artworkName))
            return "you're wearing \(unlockable.name) now. show it off in a few words."
        case .notchEffect(let effect):
            setNotchEffect(effect)
            return "the notch has the \(unlockable.name) effect now. say so in a few words."
        }
    }

    /// For the voice tool: level, XP, streak and what's unlocked.
    var statusForVoice: String {
        let unlocked = Self.unlockables.filter(isUnlocked).map(\.name)
        let nextUnlock = Self.unlockables.first { !isUnlocked($0) }
        var lines = [
            "level \(level) (\(levelName)), \(totalXP) xp, \(xpToNextLevel) xp to level \(level + 1).",
            "streak: \(streakDays) day\(streakDays == 1 ? "" : "s") in a row (best \(bestStreakDays)).",
            "unlocked: " + (unlocked.isEmpty ? "nothing yet." : unlocked.joined(separator: ", ") + ".")
        ]
        if let nextUnlock {
            lines.append("next unlock: \(nextUnlock.name) (\(nextUnlock.kindLabel)) at level \(nextUnlock.level).")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        totalXP = saved.totalXP
        streakDays = saved.streakDays
        bestStreakDays = saved.bestStreakDays
        lastActiveDay = saved.lastActiveDay
        counts = saved.counts
        notchEffect = saved.notchEffect.flatMap(DottieNotchEffect.init(rawValue:)) ?? .off
    }

    private func save() {
        let state = SavedState(
            totalXP: totalXP,
            streakDays: streakDays,
            bestStreakDays: bestStreakDays,
            lastActiveDay: lastActiveDay,
            counts: counts,
            notchEffect: notchEffect.rawValue
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - The voice tool

@MainActor
enum DottieLevelTools: DottieToolModule {
    static var tools: [DottieTool] {
        [
            DottieTool(
                name: "dottie_level",
                description: "Your level, XP, day streak and unlocks (you earn XP for finished jobs, helper tasks, guides, games and streaks). action status tells them; action wear puts on an unlocked cursor shape or notch effect by name. Brag a little when asked.",
                parameters: [
                    "type": "OBJECT",
                    "properties": [
                        "action": ["type": "STRING", "enum": ["status", "wear"]],
                        "name": ["type": "STRING", "description": "For wear: the unlockable's name, like 'disco ball' or 'rainbow glow', or 'none' for no notch effect."]
                    ],
                    "required": ["action"]
                ],
                audiences: [.voice]
            ) { arguments in
                let levels = DottieLevels.shared
                switch arguments.dottieString("action") ?? "status" {
                case "wear":
                    guard let name = arguments.dottieString("name"), let cursorPet = DottieFunPack.shared.companion?.cursorPet else {
                        return "say which unlockable to wear."
                    }
                    return levels.wear(name, cursorPet: cursorPet)
                default:
                    return levels.statusForVoice
                }
            }
        ]
    }
}

// MARK: - Notch effects

enum DottieNotchEffect: String, CaseIterable, Codable {
    case off, sparkles, rainbow, aurora

    /// The asset-catalog image for the effect's button in Home → Profile.
    var artworkName: String {
        switch self {
        case .off: return "NotchEffectNone"
        case .sparkles: return "NotchEffectSparkles"
        case .rainbow: return "NotchEffectRainbow"
        case .aurora: return "NotchEffectAurora"
        }
    }

    var displayName: String {
        switch self {
        case .off: return "None"
        case .sparkles: return "Sparkles"
        case .rainbow: return "Rainbow glow"
        case .aurora: return "Aurora"
        }
    }
}

/// A glowing edge around the open notch, in the effect the user picked.
struct DottieNotchEffectBorder<OutlineShape: Shape>: View {
    let outline: OutlineShape
    let isExpanded: Bool
    @ObservedObject private var levels = DottieLevels.shared

    var body: some View {
        if isExpanded && levels.notchEffect != .off {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                effectStroke(time: time)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func effectStroke(time: TimeInterval) -> some View {
        switch levels.notchEffect {
        case .off:
            EmptyView()
        case .rainbow:
            outline
                .stroke(
                    AngularGradient(
                        colors: [.red, .orange, .yellow, .green, .blue, .purple, .red],
                        center: .center,
                        angle: .degrees(time.truncatingRemainder(dividingBy: 6) * 60)
                    ),
                    lineWidth: 1.5
                )
                .opacity(0.85)
        case .aurora:
            outline
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.3, green: 0.95, blue: 0.7),
                            Color(red: 0.45, green: 0.4, blue: 1.0),
                            Color(red: 0.95, green: 0.4, blue: 0.9)
                        ],
                        startPoint: UnitPoint(x: 0.5 + 0.5 * sin(time * 0.7), y: 0),
                        endPoint: UnitPoint(x: 0.5 - 0.5 * sin(time * 0.7), y: 1)
                    ),
                    lineWidth: 1.5
                )
                .opacity(0.8)
        case .sparkles:
            GeometryReader { proxy in
                ZStack {
                    outline.stroke(Color.white.opacity(0.12), lineWidth: 1)
                    ForEach(0..<10, id: \.self) { index in
                        let seed = Double(index) * 1.618
                        let twinkle = 0.5 + 0.5 * sin(time * 2.2 + seed * 3)
                        Image(systemName: "sparkle")
                            .font(.system(size: 7 + CGFloat(index % 3) * 2))
                            .foregroundColor(Color(red: 1, green: 0.85, blue: 0.45))
                            .opacity(twinkle)
                            .position(
                                x: proxy.size.width * CGFloat((seed * 0.37).truncatingRemainder(dividingBy: 1)),
                                y: proxy.size.height * CGFloat(0.35 + (seed * 0.53).truncatingRemainder(dividingBy: 0.6))
                            )
                    }
                }
            }
        }
    }
}

// MARK: - Confetti

/// Confetti over the notch for a few seconds after a level-up.
struct DottieLevelUpConfetti: View {
    @ObservedObject private var levels = DottieLevels.shared
    @State private var visibleCelebrationID: UUID?

    private static let duration: TimeInterval = 3.5
    private static let colors: [Color] = [
        Color(red: 1, green: 0.84, blue: 0.38), Color(red: 0.95, green: 0.45, blue: 0.55),
        Color(red: 0.55, green: 0.3, blue: 0.85), Color(red: 0.36, green: 0.66, blue: 1.0),
        Color(red: 0.4, green: 0.88, blue: 0.5)
    ]

    var body: some View {
        ZStack {
            if let celebration = levels.celebration, visibleCelebrationID == celebration.id {
                TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(celebration.date)
                    GeometryReader { proxy in
                        ZStack {
                            ForEach(0..<36, id: \.self) { index in
                                confettiPiece(index: index, elapsed: elapsed, size: proxy.size)
                            }
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: levels.celebration) { _, newCelebration in
            guard let newCelebration else { return }
            visibleCelebrationID = newCelebration.id
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.duration * 1_000_000_000))
                if visibleCelebrationID == newCelebration.id { visibleCelebrationID = nil }
            }
        }
    }

    private func confettiPiece(index: Int, elapsed: TimeInterval, size: CGSize) -> some View {
        let seed = Double(index) * 0.6180339
        let startX = size.width * CGFloat((seed * 7.3).truncatingRemainder(dividingBy: 1))
        let speed = 40 + 60 * (seed * 3.1).truncatingRemainder(dividingBy: 1)
        let sway = 10 * sin(elapsed * 4 + seed * 9)
        let y = CGFloat(elapsed * speed) - 10
        let fade = max(0, 1 - elapsed / Self.duration)
        return RoundedRectangle(cornerRadius: 1)
            .fill(Self.colors[index % Self.colors.count])
            .frame(width: 4, height: 7)
            .rotationEffect(.degrees(elapsed * 280 + seed * 360))
            .position(x: startX + CGFloat(sway), y: y)
            .opacity(fade)
    }
}
