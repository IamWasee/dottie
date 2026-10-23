//
//  DottieToolModules.swift
//  leanring-buddy
//
//  Every feature that adds tools through DottieToolRegistry. Add one line
//  per module.
//

import Foundation

@MainActor
enum DottieToolModules {
    static let all: [any DottieToolModule.Type] = [
        DottieScreenGoalTools.self,
        DottieEpisodicMemoryTools.self,
        DottieGameTools.self, DottieVideoGameTools.self, DottieLevelTools.self, DottieKeepWorkingTools.self,
        DottieConnectedTools.self,
        EverydayTools.self,
        DottieSpeedTools.self, DottieAppLessonTools.self, DottieSmartReplayTools.self,
        DottieSkillFolderTools.self,
        DottieSelfKnowledge.self,
        DottieToolInstallTools.self,
    ]
}
