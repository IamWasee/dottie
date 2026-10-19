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
        DottieEpisodicMemoryTools.self,
        DottieGameTools.self, DottieLevelTools.self, DottieKeepWorkingTools.self,
        DottieConnectedTools.self,
        EverydayTools.self,
        DottieSpeedTools.self,
        DottieSelfKnowledge.self,
        DottieToolInstallTools.self,
    ]
}
