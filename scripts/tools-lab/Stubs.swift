//
//  Stubs.swift
//  tools-lab
//
//  The few app pieces the lab leaves out: the voice tool list holds only
//  the connected-apps module, and tools installed on request are skipped.
//

import Foundation

@MainActor
enum DottieToolModules {
    static let all: [any DottieToolModule.Type] = [
        DottieConnectedTools.self
    ]
}

enum DottieToolInstaller {
    static let helperToolLines = ""
    static let helperInstallPolicy = "(install policy left out in the lab)"
}
